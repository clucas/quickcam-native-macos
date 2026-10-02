#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <mach/mach_time.h>
#import "MyCameraCentral.h"
#import "MiscTools.h"
#include "QuickCamCapture.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static MyCameraCentral *cameraCentral;
static NSCountedSet *activeCameraLocations;
static _Thread_local char lastError[256];

static int fail(const char *message) {
    snprintf(lastError, sizeof(lastError), "%s", message);
    return -1;
}

static uint64_t hostNanoseconds(void) {
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    return (uint64_t)(((__uint128_t)mach_absolute_time() * base.numer) / base.denom);
}

@interface QCCaptureSession : NSObject {
@public
    MyCameraDriver *driver;
    uint8_t *pixels;
    qc_frame_callback callback;
    void *context;
    NSLock *lock;
    BOOL stopping;
    BOOL running;
    BOOL shutdownReturned;
    BOOL shutdownCompleted;
    BOOL stopReady;
    unsigned activeCallbacks;
    CameraError captureError;
    uint64_t minimumFrameInterval;
    uint64_t previousFrameTime;
    dispatch_semaphore_t stopped;
}
- (void)signalStopIfReadyLocked;
@end

@implementation QCCaptureSession
- (id)init {
    self = [super init];
    if (self) {
        lock = [[NSLock alloc] init];
        stopped = dispatch_semaphore_create(0);
    }
    return self;
}
- (void)signalStopIfReadyLocked {
    if (stopping && shutdownReturned && shutdownCompleted && !activeCallbacks && !stopReady) {
        stopReady = YES;
        dispatch_semaphore_signal(stopped);
    }
}
- (void)imageReady:(MyCameraDriver *)camera {
    [lock lock];
    if (stopping) {
        [lock unlock];
        return;
    }
    ++activeCallbacks;
    [lock unlock];
    @try {
        uint64_t now = hostNanoseconds();
        if (!previousFrameTime || now - previousFrameTime >= minimumFrameInterval) {
            previousFrameTime = now;
            callback(context, [camera imageBuffer], [camera width], [camera height],
                     (size_t)[camera imageBufferRowBytes], now);
        }
        [lock lock];
        BOOL active = !stopping;
        [lock unlock];
        if (active) [camera setImageBuffer:pixels bpp:3 rowBytes:[camera width] * 3L];
    } @finally {
        [lock lock];
        --activeCallbacks;
        [self signalStopIfReadyLocked];
        [lock unlock];
    }
}
- (void)grabFinished:(MyCameraDriver *)camera withError:(CameraError)error {
    [lock lock];
    running = NO;
    if (!stopping) captureError = error;
    [lock unlock];
    if (error != CameraErrorOK) {
        fprintf(stderr, "QuickCam capture error %d (%s)\n", error,
                [cameraCentral localizedCStrForError:error]);
    }
}
- (void)cameraHasShutDown:(MyCameraDriver *)camera {
    [lock lock];
    running = NO;
    shutdownCompleted = YES;
    [self signalStopIfReadyLocked];
    [lock unlock];
}
- (void)dealloc {
    [driver setDelegate:nil];
    [driver release];
    free(pixels);
    [lock release];
    dispatch_release(stopped);
    [super dealloc];
}
@end

struct qc_session {
    QCCaptureSession *capture;
    uint32_t location;
    BOOL registered;
};

static void requestCaptureStop(QCCaptureSession *capture) {
    [capture->lock lock];
    BOOL requested = capture->stopping;
    capture->stopping = YES;
    capture->running = NO;
    [capture->lock unlock];
    if (requested) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            @synchronized (capture->driver) {
                [capture->driver shutdown];
            }
            [capture->lock lock];
            capture->shutdownReturned = YES;
            [capture signalStopIfReadyLocked];
            [capture->lock unlock];
        }
    });
}

int qc_initialize(void) {
    lastError[0] = '\0';
    if (![NSThread isMainThread]) return fail("Camera lifecycle operations require the main thread.");
    if (cameraCentral) return 0;
    cameraCentral = [MyCameraCentral sharedCameraCentral];
    if (![cameraCentral startupWithNotificationsOnMainThread:NO recognizeLaterPlugins:YES]) {
        cameraCentral = nil;
        return fail("USB camera discovery could not start.");
    }
    return 0;
}

static uint32_t propertyNumber(io_service_t service, CFStringRef key) {
    uint32_t value = 0;
    CFTypeRef property = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (property) {
        if (CFGetTypeID(property) == CFNumberGetTypeID())
            CFNumberGetValue(property, kCFNumberSInt32Type, &value);
        CFRelease(property);
    }
    return value;
}

size_t qc_enumerate(qc_device_info *devices, size_t capacity) {
    if (qc_initialize()) return 0;
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn result = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOUSBHostDevice"), &iterator);
    if (result != kIOReturnSuccess) {
        fail("USB enumeration failed.");
        return 0;
    }
    size_t count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        uint16_t vendor = propertyNumber(service, CFSTR("idVendor"));
        uint16_t product = propertyNumber(service, CFSTR("idProduct"));
        uint32_t location = propertyNumber(service, CFSTR("locationID"));
        uint64_t registryID = 0;
        if (vendor == 0x046d && (product == 0x08b2 || product == 0x08d7) &&
            [cameraCentral idOfCameraWithLocationID:location]) {
            if (IORegistryEntryGetRegistryEntryID(service, &registryID) != KERN_SUCCESS || !registryID) {
                IOObjectRelease(service);
                IOObjectRelease(iterator);
                fail("USB connection identity could not be read.");
                return 0;
            }
            if (devices && count < capacity)
                devices[count] = (qc_device_info){vendor, product, location, registryID};
            ++count;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}

int qc_prepare_idle_device(const qc_device_info *info) {
    lastError[0] = '\0';
    if (![NSThread isMainThread]) return fail("Camera lifecycle operations require the main thread.");
    if (!info || info->vendor_id != 0x046d || info->product_id != 0x08b2 ||
        !info->location_id || !info->registry_id)
        return fail("Idle preparation requires a connected QuickCam Pro 4000.");
    if ([activeCameraLocations countForObject:@(info->location_id)])
        return fail("The QuickCam Pro 4000 has an active or stopping capture session.");

    int status = -1;
    const char *stage = "find device";
    IOReturn result = kIOReturnNoDevice;
    io_service_t service = IO_OBJECT_NULL, interfaceService = IO_OBJECT_NULL;
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOCFPlugInInterface **plugin = NULL;
    IOUSBDeviceInterface **device = NULL;
    IOUSBInterfaceInterface220 **interface = NULL;
    BOOL deviceOpen = NO, interfaceOpen = NO;
    SInt32 score = 0;
    uint64_t registryID = 0;
    UInt16 vendor = 0, product = 0;
    UInt32 location = 0;
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(info->registry_id);
    if (!matching) { result = kIOReturnNoMemory; goto cleanup; }
    service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) goto cleanup;
    stage = "verify device identity";
    if (!IOObjectConformsTo(service, "IOUSBHostDevice") ||
        IORegistryEntryGetRegistryEntryID(service, &registryID) != KERN_SUCCESS ||
        registryID != info->registry_id ||
        propertyNumber(service, CFSTR("idVendor")) != info->vendor_id ||
        propertyNumber(service, CFSTR("idProduct")) != info->product_id ||
        propertyNumber(service, CFSTR("locationID")) != info->location_id) goto cleanup;

    stage = "create device interface";
    result = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &plugin, &score);
    if (result || !plugin) goto cleanup;
    result = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
    (*plugin)->Release(plugin); plugin = NULL;
    if (result || !device) goto cleanup;
    stage = "verify USB identity";
    result = (*device)->GetDeviceVendor(device, &vendor);
    if (result) goto cleanup;
    result = (*device)->GetDeviceProduct(device, &product);
    if (result) goto cleanup;
    result = (*device)->GetLocationID(device, &location);
    if (result) goto cleanup;
    if (vendor != info->vendor_id || product != info->product_id || location != info->location_id) {
        result = kIOReturnNoDevice;
        goto cleanup;
    }
    stage = "open device exclusively";
    result = (*device)->USBDeviceOpen(device);
    if (result) goto cleanup;
    deviceOpen = YES;
    IOUSBFindInterfaceRequest find = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    stage = "find video interface";
    result = (*device)->CreateInterfaceIterator(device, &find, &iterator);
    if (result || !iterator) goto cleanup;
    while ((interfaceService = IOIteratorNext(iterator))) {
        stage = "create video interface";
        result = IOCreatePlugInInterfaceForService(interfaceService, kIOUSBInterfaceUserClientTypeID,
                                                  kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(interfaceService); interfaceService = IO_OBJECT_NULL;
        if (result || !plugin) goto cleanup;
        result = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID220),
                                           (LPVOID *)&interface);
        (*plugin)->Release(plugin); plugin = NULL;
        if (result || !interface) goto cleanup;
        UInt8 number = UINT8_MAX;
        result = (*interface)->GetInterfaceNumber(interface, &number);
        if (result) goto cleanup;
        if (number == 0) break;
        (*interface)->Release(interface); interface = NULL;
    }
    if (!interface) { result = kIOReturnNoDevice; goto cleanup; }
    stage = "open video interface exclusively";
    result = (*interface)->USBInterfaceOpen(interface);
    if (result) goto cleanup;
    interfaceOpen = YES;
    UInt8 off[2] = {0, 0};
    IOUSBDevRequestTO request = {
        .bmRequestType = USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice),
        .bRequest = 0x05, .wValue = 0x3400, .wIndex = 3, .wLength = sizeof(off),
        .pData = off, .noDataTimeout = 250, .completionTimeout = 250,
    };
    stage = "clear activity light";
    result = (*interface)->ControlRequestTO(interface, 0, &request);
    if (!result && request.wLenDone != sizeof(off)) result = kIOReturnUnderrun;
    if (!result) status = 0;

cleanup:
    if (interfaceOpen) (*interface)->USBInterfaceClose(interface);
    if (interface) (*interface)->Release(interface);
    if (plugin) (*plugin)->Release(plugin);
    if (interfaceService) IOObjectRelease(interfaceService);
    if (iterator) IOObjectRelease(iterator);
    if (deviceOpen) (*device)->USBDeviceClose(device);
    if (device) (*device)->Release(device);
    if (service) IOObjectRelease(service);
    if (status) snprintf(lastError, sizeof(lastError), "Cannot prepare idle QuickCam Pro 4000: %s (0x%08x).", stage, result);
    return status;
}

qc_session *qc_start(uint32_t location, uint32_t width, uint32_t height,
                     uint32_t fps, qc_frame_callback callback, void *context) {
    if (qc_initialize()) return NULL;
    if (!callback || !fps || fps > 30) {
        fail("A frame callback and frame rate between 1 and 30 are required.");
        return NULL;
    }
    CameraResolution resolution = ResolutionInvalid;
    for (CameraResolution r = ResolutionMin; r <= ResolutionMax; ++r)
        if ((uint32_t)WidthOfResolution(r) == width && (uint32_t)HeightOfResolution(r) == height) resolution = r;
    if (resolution == ResolutionInvalid) {
        fail("Unsupported frame dimensions.");
        return NULL;
    }
    unsigned long cameraID = [cameraCentral idOfCameraWithLocationID:location];
    if (!cameraID) {
        fail("The selected legacy camera is not connected.");
        return NULL;
    }
    MyCameraDriver *driver = nil;
    CameraError error = [cameraCentral useCameraWithID:cameraID to:&driver acceptDummy:NO];
    if (error != CameraErrorOK || !driver) {
        snprintf(lastError, sizeof(lastError), "Cannot open camera: error %d (%s).", error,
                 [cameraCentral localizedCStrForError:error]);
        return NULL;
    }
    QCCaptureSession *capture = [[QCCaptureSession alloc] init];
    capture->driver = [driver retain];
    capture->callback = callback;
    capture->context = context;
    capture->minimumFrameInterval = 1000000000ull / fps - 1000000ull;
    [driver setDelegate:capture];
    if (![driver supportsResolution:resolution fps:(short)fps]) {
        snprintf(lastError, sizeof(lastError), "Camera does not support %ux%u at %u fps.", width, height, fps);
        requestCaptureStop(capture);
        dispatch_semaphore_wait(capture->stopped, DISPATCH_TIME_FOREVER);
        [capture release];
        return NULL;
    }
    [driver setResolution:resolution fps:(short)fps];
    capture->pixels = calloc((size_t)width * height, 3);
    qc_session *session = calloc(1, sizeof(*session));
    if (!capture->pixels || !session) {
        requestCaptureStop(capture);
        dispatch_semaphore_wait(capture->stopped, DISPATCH_TIME_FOREVER);
        [capture release];
        free(session);
        fail("Could not allocate capture buffers.");
        return NULL;
    }
    session->capture = capture;
    capture->running = YES;
    [driver setImageBuffer:capture->pixels bpp:3 rowBytes:width * 3L];
    if (![driver startGrabbing]) {
        qc_stop(session);
        fail("Could not start USB capture.");
        return NULL;
    }
    if (!activeCameraLocations) activeCameraLocations = [NSCountedSet new];
    [activeCameraLocations addObject:@(location)];
    session->location = location;
    session->registered = YES;
    return session;
}

void qc_request_stop(qc_session *session) {
    if (!session) return;
    if (![NSThread isMainThread]) {
        fail("Camera lifecycle operations require the main thread.");
        return;
    }
    requestCaptureStop(session->capture);
}

int qc_finish_stop(qc_session *session) {
    if (!session) return 1;
    if (![NSThread isMainThread]) {
        fail("Camera lifecycle operations require the main thread.");
        return 0;
    }
    QCCaptureSession *capture = session->capture;
    [capture->lock lock];
    BOOL ready = capture->stopReady;
    [capture->lock unlock];
    if (!ready) return 0;
    if (session->registered) [activeCameraLocations removeObject:@(session->location)];
    [capture release];
    free(session);
    return 1;
}

void qc_stop(qc_session *session) {
    if (!session) return;
    if (![NSThread isMainThread]) {
        fail("Camera lifecycle operations require the main thread.");
        return;
    }
    qc_request_stop(session);
    dispatch_semaphore_wait(session->capture->stopped, DISPATCH_TIME_FOREVER);
    qc_finish_stop(session);
}

int qc_status(qc_session *session) {
    if (!session) return 0;
    QCCaptureSession *capture = session->capture;
    [capture->lock lock];
    int status = capture->captureError ? -(int)capture->captureError : (capture->running ? 1 : 0);
    [capture->lock unlock];
    return status;
}

const char *qc_last_error(void) {
    return lastError;
}
