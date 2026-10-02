#import "MyKiaraFamilyDriver.h"
#include <assert.h>

typedef struct { IOUSBInterfaceInterface *vtable; id owner; } TestUSB;

@interface LEDDriver : MyKiaraFamilyDriver {
@public
    TestUSB connection;
    NSMutableArray *events;
    dispatch_semaphore_t acquiring, drain, finished, closed;
    unsigned failOn, failOff, setupCalls;
    BOOL failSetup;
    CameraError acquisitionError, result;
}
- (void)record:(NSString *)event;
@end

static IOReturn controlRequest(void *reference, UInt8 pipe, IOUSBDevRequest *request) {
    LEDDriver *driver=((TestUSB *)reference)->owner;
    if (request->wValue!=SEL_LED) return kIOReturnSuccess;
    assert(pipe==0 && request->bmRequestType==0x40);
    assert(request->bRequest==GRP_SET_STATUS && request->wIndex==INTF_CONTROL);
    assert(request->wLength==2 && request->pData);
    UInt8 *bytes=request->pData;
    assert((bytes[0]==0 || bytes[0]==0xff) && bytes[1]==0);
    BOOL enabled=bytes[0]!=0;
    unsigned *failures=enabled ? &driver->failOn : &driver->failOff;
    BOOL failed=*failures>0;
    if (failed) --*failures;
    [driver record:enabled ? (failed ? @"on failed" : @"on") :
                             (failed ? @"off failed" : @"off")];
    return failed ? kIOReturnError : kIOReturnSuccess;
}

static IOReturn closeInterface(void *reference) {
    LEDDriver *driver=((TestUSB *)reference)->owner;
    [driver record:@"close"];
    return kIOReturnSuccess;
}

static ULONG releaseInterface(void *reference) {
    LEDDriver *driver=((TestUSB *)reference)->owner;
    [driver record:@"release"];
    return 0;
}

static IOUSBInterfaceInterface usb={
    .ControlRequest=controlRequest,
    .USBInterfaceClose=closeInterface,
    .Release=releaseInterface,
};

@implementation LEDDriver
- (id)initWithCentral:(id)owner {
    self=[super initWithCentral:owner];
    if (self) {
        connection=(TestUSB){&usb, self};
        events=[NSMutableArray new];
        acquiring=dispatch_semaphore_create(0);
        drain=dispatch_semaphore_create(0);
        finished=dispatch_semaphore_create(0);
        closed=dispatch_semaphore_create(0);
        [self setDelegate:self];
    }
    return self;
}
- (void)record:(NSString *)event { @synchronized(events) { [events addObject:event]; } }
- (CameraError)usbConnectToCam:(UInt32)location configIdx:(short)index {
    controlIntf=(IOUSBInterfaceInterface **)&connection;
    return CameraErrorOK;
}
- (void)setResolution:(CameraResolution)value fps:(short)rate { resolution=value; fps=rate; }
- (void)setWhiteBalanceMode:(WhiteBalanceMode)value {}
- (BOOL)setupGrabContext {
    ++setupCalls;
    assert([self isLedOn]);
    [self record:@"setup"];
    memset(&grabContext, 0, sizeof(grabContext));
    return !failSetup;
}
- (BOOL)cleanupGrabContext {
    assert(!grabbingThreadRunning);
    [self record:@"cleanup"];
    return YES;
}
- (void)grabbingThread:(id)data {
    @autoreleasepool {
        assert([self isLedOn]);
        [self record:@"acquire"];
        dispatch_semaphore_signal(acquiring);
        assert(dispatch_semaphore_wait(drain, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))==0);
        grabContext.err=acquisitionError;
        [self record:@"drained"];
        shouldBeGrabbing=NO;
        grabbingThreadRunning=NO;
    }
}
- (void)grabFinished:(id)sender withError:(CameraError)error {
    result=error;
    dispatch_semaphore_signal(finished);
}
- (void)cameraHasShutDown:(id)sender { dispatch_semaphore_signal(closed); }
- (void)dealloc {
    [self setDelegate:nil];
    [self usbCloseConnection];
    [events release];
    dispatch_release(acquiring); dispatch_release(drain);
    dispatch_release(finished); dispatch_release(closed);
    [super dealloc];
}
@end

static void waitFor(dispatch_semaphore_t event) {
    assert(dispatch_semaphore_wait(event, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))==0);
}

static void expect(LEDDriver *driver, NSArray *expected) {
    @synchronized(driver->events) {
        if (![driver->events isEqualToArray:expected]) {
            NSLog(@"Expected %@, got %@", expected, driver->events);
            abort();
        }
    }
}

int main(void) {
    @autoreleasepool {
        LEDDriver *driver=[[LEDDriver alloc] initWithCentral:nil];
        [driver usbCloseConnection];
        expect(driver, @[]);
        assert([driver startupWithUsbLocationId:0]==CameraErrorOK);
        expect(driver, @[@"off"]);
        [driver setLed:YES];
        assert([driver isLedOn]);
        driver->failOff=1;
        [driver setLed:NO];
        assert([driver isLedOn]);
        [driver setLed:NO];
        assert(![driver isLedOn]);
        [driver shutdown]; waitFor(driver->closed);
        expect(driver, @[@"off", @"on", @"off failed", @"off", @"off", @"close", @"release"]);
        [driver release];

        for (unsigned failure=0; failure<3; ++failure) {
            driver=[[LEDDriver alloc] initWithCentral:nil];
            assert([driver startupWithUsbLocationId:0]==CameraErrorOK);
            driver->acquisitionError=failure==1 ? CameraErrorNoCam : CameraErrorOK;
            driver->failOff=failure==2 ? 1 : 0;
            assert([driver startGrabbing]);
            waitFor(driver->acquiring);
            [driver shutdown];
            assert([driver isLedOn]);
            expect(driver, @[@"off", @"on", @"setup", @"acquire"]);
            dispatch_semaphore_signal(driver->drain);
            waitFor(driver->closed);
            CameraError expected=failure==1 ? CameraErrorNoCam :
                                 failure==2 ? CameraErrorUSBProblem : CameraErrorOK;
            assert(driver->result==expected && ![driver isLedOn]);
            expect(driver, @[@"off", @"on", @"setup", @"acquire", @"drained", @"cleanup",
                             failure==2 ? @"off failed" : @"off", @"off", @"close", @"release"]);
            [driver release];
        }

        for (unsigned failure=0; failure<2; ++failure) {
            driver=[[LEDDriver alloc] initWithCentral:nil];
            assert([driver startupWithUsbLocationId:0]==CameraErrorOK);
            driver->failOn=failure==0 ? 1 : 0;
            driver->failSetup=failure==1;
            assert([driver startGrabbing]);
            waitFor(driver->finished);
            assert(![driver isGrabbing]);
            [driver shutdown]; waitFor(driver->closed);
            assert(driver->result==(failure==0 ? CameraErrorUSBProblem : CameraErrorNoMem));
            assert(driver->setupCalls==failure && ![driver isLedOn]);
            expect(driver, failure==0 ?
                   @[@"off", @"on failed", @"off", @"off", @"close", @"release"] :
                   @[@"off", @"on", @"setup", @"cleanup", @"off", @"off", @"close", @"release"]);
            [driver release];
        }

        driver=[[LEDDriver alloc] initWithCentral:nil];
        driver->failOff=1;
        assert([driver startupWithUsbLocationId:0]==CameraErrorUSBProblem);
        [driver shutdown]; waitFor(driver->closed);
        expect(driver, @[@"off failed", @"off", @"close", @"release"]);
        [driver release];
        puts("activity light: byte order, initial off, capture drain, failure cleanup, and USB close passed");
    }
    return 0;
}
