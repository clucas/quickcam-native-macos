#import "MyCameraCentral.h"
#include <assert.h>
#include <string.h>

typedef struct { CFRunLoopSourceRef source; } TestPort;
static unsigned livePorts, liveIterators, matchingCalls, dictionaryCalls, nextIterator;
static BOOL iterators[128];
static BOOL failPort, failSource;
static unsigned failDictionary, failNotification;

static void perform(void *context) {}

IONotificationPortRef IONotificationPortCreate(mach_port_t port) {
    if (failPort) return NULL;
    TestPort *result = calloc(1, sizeof(*result));
    CFRunLoopSourceContext context = {.version = 0, .perform = perform};
    result->source = CFRunLoopSourceCreate(NULL, 0, &context);
    ++livePorts;
    return (IONotificationPortRef)result;
}
CFRunLoopSourceRef IONotificationPortGetRunLoopSource(IONotificationPortRef port) {
    return failSource ? NULL : ((TestPort *)port)->source;
}
void IONotificationPortDestroy(IONotificationPortRef port) {
    TestPort *value = (TestPort *)port;
    CFRunLoopSourceInvalidate(value->source);
    CFRelease(value->source);
    free(value);
    assert(livePorts);
    --livePorts;
}
CFMutableDictionaryRef IOServiceMatching(const char *className) {
    assert(strcmp(className, kIOUSBDeviceClassName) == 0);
    if (++dictionaryCalls == failDictionary) return NULL;
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                     &kCFTypeDictionaryValueCallBacks);
}
kern_return_t IOServiceAddMatchingNotification(IONotificationPortRef port,
    const io_name_t type, CFDictionaryRef matching, IOServiceMatchingCallback callback,
    void *context, io_iterator_t *iterator) {
    SInt32 vendor = 0, product = 0;
    assert(CFNumberGetValue(CFDictionaryGetValue(matching, CFSTR(kUSBVendorID)),
                           kCFNumberSInt32Type, &vendor));
    assert(CFNumberGetValue(CFDictionaryGetValue(matching, CFSTR(kUSBProductID)),
                           kCFNumberSInt32Type, &product));
    assert(vendor == 0x046d && (product == 0x08b2 || product == 0x08d7));
    assert(strcmp(type, kIOFirstMatchNotification) == 0 && callback && context);
    CFRelease(matching);
    ++matchingCalls;
    *iterator = IO_OBJECT_NULL;
    if (matchingCalls == failNotification) return kIOReturnError;
    assert(++nextIterator < 128);
    iterators[nextIterator] = YES;
    ++liveIterators;
    *iterator = nextIterator;
    return KERN_SUCCESS;
}
io_object_t IOIteratorNext(io_iterator_t iterator) {
    assert(iterator < 128 && iterators[iterator]);
    return IO_OBJECT_NULL;
}
kern_return_t IOObjectRelease(io_object_t object) {
    assert(object < 128 && iterators[object] && liveIterators);
    iterators[object] = NO;
    --liveIterators;
    return KERN_SUCCESS;
}

@interface RetryCentral : MyCameraCentral
- (BOOL)isEmpty;
@end
@implementation RetryCentral
- (id)prefsForKey:(NSString *)key { return nil; }
- (BOOL)isEmpty { return !started && !notifyPort && ![cameraTypes count] && ![matchingNotifications count] && ![cameras count]; }
@end

int main(void) {
    @autoreleasepool {
        for (unsigned failure = 0; failure < 5; ++failure) {
            RetryCentral *central = [RetryCentral new];
            matchingCalls = dictionaryCalls = 0;
            failPort = failure == 0;
            failSource = failure == 1;
            failDictionary = failure == 2 ? 2 : 0;
            failNotification = failure == 3 ? 1 : failure == 4 ? 2 : 0;
            assert(![central startupWithNotificationsOnMainThread:NO recognizeLaterPlugins:YES]);
            assert([central isEmpty] && livePorts == 0 && liveIterators == 0);
            failPort = failSource = NO;
            failDictionary = failNotification = 0;
            matchingCalls = dictionaryCalls = 0;
            assert([central startupWithNotificationsOnMainThread:NO recognizeLaterPlugins:YES]);
            assert(matchingCalls == 2 && livePorts == 1 && liveIterators == 2);
            assert([central startupWithNotificationsOnMainThread:NO recognizeLaterPlugins:YES]);
            assert(matchingCalls == 2 && livePorts == 1 && liveIterators == 2);
            [central shutdown];
            assert([central isEmpty] && livePorts == 0 && liveIterators == 0);
            [central release];
        }
        puts("startup retry: port, source, dictionary, and partial notification failures roll back without duplicate registrations");
    }
    return 0;
}
