#import "MyCameraCentral.h"
#include <assert.h>
#include <stdatomic.h>
#include <unistd.h>

static atomic_uint destroyedInfos, destroyedCentrals;

@interface TrackedInfo : MyCameraInfo
@end
@implementation TrackedInfo
- (void)dealloc { atomic_fetch_add(&destroyedInfos, 1); [super dealloc]; }
@end

@interface RemovalDriver : MyCameraDriver {
@public
    dispatch_semaphore_t usbEntered, usbMayReturn, shutdownEntered, shutdownMayReturn;
    atomic_uint stops, shutdowns;
}
@end
@implementation RemovalDriver
- (id)initWithCentral:(id)owner {
    self = [super initWithCentral:owner];
    if (self) {
        usbEntered = dispatch_semaphore_create(0);
        usbMayReturn = dispatch_semaphore_create(0);
        shutdownEntered = dispatch_semaphore_create(0);
        shutdownMayReturn = dispatch_semaphore_create(0);
    }
    return self;
}
- (void)stopUsingUSB {
    assert(![NSThread isMainThread]);
    atomic_fetch_add(&stops, 1);
    dispatch_semaphore_signal(usbEntered);
    dispatch_semaphore_wait(usbMayReturn, DISPATCH_TIME_FOREVER);
}
- (void)shutdown {
    assert(![NSThread isMainThread]);
    atomic_fetch_add(&shutdowns, 1);
    dispatch_semaphore_signal(shutdownEntered);
    dispatch_semaphore_wait(shutdownMayReturn, DISPATCH_TIME_FOREVER);
}
- (void)dealloc {
    dispatch_release(usbEntered); dispatch_release(usbMayReturn);
    dispatch_release(shutdownEntered); dispatch_release(shutdownMayReturn);
    [super dealloc];
}
@end

@interface RemovalCentral : MyCameraCentral
- (unsigned long)addDriver:(MyCameraDriver *)driver;
- (unsigned)retirementCount;
@end
@implementation RemovalCentral
- (unsigned long)addDriver:(MyCameraDriver *)driver {
    TrackedInfo *info = [TrackedInfo new];
    [info setDriver:[driver retain]];
    [info setCentral:self];
    [info setLocationID:123];
    [driver setCameraInfo:info];
    [cameras addObject:info];
    return [info cid];
}
- (unsigned)retirementCount { @synchronized(self) { return (unsigned)[retiringCameras count]; } }
- (void)dealloc { atomic_fetch_add(&destroyedCentrals, 1); [super dealloc]; }
@end

static void awaitSignal(dispatch_semaphore_t semaphore) {
    assert(dispatch_semaphore_wait(semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
}

int main(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ _exit(99); });
    @autoreleasepool {
        RemovalCentral *central = [RemovalCentral new];
        RemovalDriver *driver = [[RemovalDriver alloc] initWithCentral:central];
        unsigned long cid = [central addDriver:driver];
        [central deviceRemoved:cid];
        [central deviceRemoved:cid];
        awaitSignal(driver->usbEntered);
        assert([central numCameras] == 0 && [central idOfCameraWithLocationID:123] == 0);
        assert([central retirementCount] == 1 && atomic_load(&driver->stops) == 1);
        [driver cameraHasShutDown:driver];
        assert([central retirementCount] == 1);
        [central release];
        assert(atomic_load(&destroyedInfos) == 0 && atomic_load(&destroyedCentrals) == 0);
        dispatch_semaphore_signal(driver->usbMayReturn);
        awaitSignal(driver->shutdownEntered);
        assert(atomic_load(&driver->shutdowns) == 1);
        assert(atomic_load(&destroyedInfos) == 0 && atomic_load(&destroyedCentrals) == 0);
        dispatch_semaphore_signal(driver->shutdownMayReturn);
        for (unsigned i = 0; i < 2000 && atomic_load(&destroyedCentrals) == 0; ++i) usleep(1000);
        assert(atomic_load(&destroyedInfos) == 1 && atomic_load(&destroyedCentrals) == 1);
        [driver release];
        puts("device removal: registry detaches immediately and retains teardown state until worker and completion finish");
    }
    return 0;
}
