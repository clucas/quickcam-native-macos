#import "../src/QuickCamCapture.m"
#include <assert.h>
#include <stdatomic.h>
#include <unistd.h>

static atomic_uint destroyedCaptures;

@interface TrackedCapture : QCCaptureSession
@end
@implementation TrackedCapture
- (void)dealloc {
    atomic_fetch_add(&destroyedCaptures, 1);
    [super dealloc];
}
@end

@interface DeferredDriver : MyCameraDriver {
@public
    dispatch_semaphore_t shutdownEntered;
    dispatch_semaphore_t allowShutdownReturn;
    atomic_uint shutdownCalls;
    BOOL completeInsideShutdown;
    unsigned char *testPixels;
}
- (void)complete;
@end
@implementation DeferredDriver
- (id)init {
    self = [super initWithCentral:nil];
    if (self) {
        shutdownEntered = dispatch_semaphore_create(0);
        allowShutdownReturn = dispatch_semaphore_create(0);
    }
    return self;
}
- (void)shutdown {
    atomic_fetch_add(&shutdownCalls, 1);
    dispatch_semaphore_signal(shutdownEntered);
    dispatch_semaphore_wait(allowShutdownReturn, DISPATCH_TIME_FOREVER);
    if (completeInsideShutdown) [self complete];
}
- (void)complete {
    [[self delegate] cameraHasShutDown:self];
}
- (short)width { return 1; }
- (short)height { return 1; }
- (long)imageBufferRowBytes { return 3; }
- (unsigned char *)imageBuffer { return testPixels; }
- (void)setImageBuffer:(unsigned char *)buffer bpp:(short)bpp rowBytes:(long)stride {}
- (void)dealloc {
    dispatch_release(shutdownEntered);
    dispatch_release(allowShutdownReturn);
    [super dealloc];
}
@end

typedef struct {
    atomic_uint calls;
    dispatch_semaphore_t entered;
    dispatch_semaphore_t resume;
    dispatch_semaphore_t returned;
} FrameGate;

static void receiveFrame(void *context, const uint8_t *rgb, uint32_t width,
                         uint32_t height, size_t stride, uint64_t timestamp) {
    FrameGate *gate = context;
    atomic_fetch_add(&gate->calls, 1);
    assert(width == 1 && height == 1 && stride == 3);
    if (gate->entered) {
        dispatch_semaphore_signal(gate->entered);
        dispatch_semaphore_wait(gate->resume, DISPATCH_TIME_FOREVER);
    }
    assert(rgb[0] == 0x5a);
}

static qc_session *newSession(DeferredDriver *driver, FrameGate *gate) {
    TrackedCapture *capture = [TrackedCapture new];
    capture->driver = [driver retain];
    capture->pixels = malloc(3);
    memset(capture->pixels, 0x5a, 3);
    driver->testPixels = capture->pixels;
    capture->callback = receiveFrame;
    capture->context = gate;
    capture->running = YES;
    [driver setDelegate:capture];
    qc_session *session = calloc(1, sizeof(*session));
    session->capture = capture;
    return session;
}

static void awaitSignal(dispatch_semaphore_t semaphore) {
    assert(dispatch_semaphore_wait(semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
}

static void consumeWhenReady(qc_session *session) {
    for (unsigned i = 0; i < 2000; ++i) {
        if (qc_finish_stop(session)) return;
        usleep(1000);
    }
    assert(!"shutdown did not complete");
}

static void testDeferredShutdown(void) {
    DeferredDriver *driver = [DeferredDriver new];
    FrameGate gate = {0};
    qc_session *session = newSession(driver, &gate);
    assert(qc_finish_stop(session) == 0);
    uint64_t before = hostNanoseconds();
    qc_request_stop(session);
    assert(hostNanoseconds() - before < 100000000ull);
    qc_request_stop(session);
    qc_request_stop(session);
    awaitSignal(driver->shutdownEntered);
    assert(atomic_load(&driver->shutdownCalls) == 1);
    assert(qc_status(session) == 0);
    [driver complete];
    for (unsigned i = 0; i < 20; ++i) assert(qc_finish_stop(session) == 0);
    assert(session->capture->pixels[0] == 0x5a);
    dispatch_semaphore_signal(driver->allowShutdownReturn);
    consumeWhenReady(session);
    [driver release];
}

static void testLateCompletion(void) {
    DeferredDriver *driver = [DeferredDriver new];
    FrameGate gate = {0};
    qc_session *session = newSession(driver, &gate);
    dispatch_semaphore_signal(driver->allowShutdownReturn);
    qc_request_stop(session);
    awaitSignal(driver->shutdownEntered);
    for (unsigned i = 0; i < 20; ++i) {
        assert(qc_finish_stop(session) == 0);
        usleep(1000);
    }
    [session->capture imageReady:driver];
    assert(atomic_load(&gate.calls) == 0);
    assert(session->capture->pixels[0] == 0x5a);
    qc_request_stop(session);
    assert(atomic_load(&driver->shutdownCalls) == 1);
    [driver complete];
    consumeWhenReady(session);
    [driver release];
}

static void testInFlightCallback(void) {
    DeferredDriver *driver = [DeferredDriver new];
    FrameGate gate = {0};
    gate.entered = dispatch_semaphore_create(0);
    gate.resume = dispatch_semaphore_create(0);
    gate.returned = dispatch_semaphore_create(0);
    FrameGate *gatePointer = &gate;
    qc_session *session = newSession(driver, &gate);
    QCCaptureSession *capture = session->capture;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            [capture imageReady:driver];
            dispatch_semaphore_signal(gatePointer->returned);
        }
    });
    awaitSignal(gate.entered);
    dispatch_semaphore_signal(driver->allowShutdownReturn);
    qc_request_stop(session);
    awaitSignal(driver->shutdownEntered);
    [driver complete];
    for (unsigned i = 0; i < 20; ++i) {
        assert(qc_finish_stop(session) == 0);
        usleep(1000);
    }
    dispatch_semaphore_signal(gate.resume);
    awaitSignal(gate.returned);
    consumeWhenReady(session);
    assert(atomic_load(&gate.calls) == 1);
    dispatch_release(gate.entered);
    dispatch_release(gate.resume);
    dispatch_release(gate.returned);
    [driver release];
}

static void testIndependentStops(void) {
    DeferredDriver *blocked = [DeferredDriver new];
    DeferredDriver *ready = [DeferredDriver new];
    FrameGate gates[2] = {0};
    qc_session *pending = newSession(blocked, &gates[0]);
    qc_session *completed = newSession(ready, &gates[1]);
    qc_request_stop(pending);
    awaitSignal(blocked->shutdownEntered);
    ready->completeInsideShutdown = YES;
    dispatch_semaphore_signal(ready->allowShutdownReturn);
    qc_request_stop(completed);
    consumeWhenReady(completed);
    assert(qc_finish_stop(pending) == 0);
    [blocked complete];
    dispatch_semaphore_signal(blocked->allowShutdownReturn);
    consumeWhenReady(pending);
    [blocked release];
    [ready release];
}

static void testMainThreadContract(void) {
    DeferredDriver *driver = [DeferredDriver new];
    FrameGate gate = {0};
    qc_session *session = newSession(driver, &gate);
    dispatch_semaphore_t checked = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            qc_request_stop(session);
            assert(qc_finish_stop(session) == 0);
            assert(strstr(qc_last_error(), "main thread") != NULL);
            dispatch_semaphore_signal(checked);
        }
    });
    awaitSignal(checked);
    assert(atomic_load(&driver->shutdownCalls) == 0);
    driver->completeInsideShutdown = YES;
    dispatch_semaphore_signal(driver->allowShutdownReturn);
    qc_stop(session);
    assert(atomic_load(&driver->shutdownCalls) == 1);
    dispatch_release(checked);
    [driver release];
}

int main(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ _exit(99); });
    @autoreleasepool {
        testDeferredShutdown();
        testLateCompletion();
        testInFlightCallback();
        testIndependentStops();
        testMainThreadContract();
        qc_request_stop(NULL);
        assert(qc_finish_stop(NULL) == 1);
        qc_stop(NULL);
        for (unsigned i = 0; i < 2000 && atomic_load(&destroyedCaptures) < 6; ++i) usleep(1000);
        assert(atomic_load(&destroyedCaptures) == 6);
        puts("asynchronous stop: blocked driver, late completion, in-flight callback, independent cameras, idempotence, and main-thread contract passed");
    }
    return 0;
}
