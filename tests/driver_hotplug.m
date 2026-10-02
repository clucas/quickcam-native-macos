#import "MyCameraCentral.h"
#include <assert.h>
#include <string.h>

static unsigned registrations;
static unsigned products;

kern_return_t IOServiceAddMatchingNotification(IONotificationPortRef port,
    const io_name_t notificationType, CFDictionaryRef matching,
    IOServiceMatchingCallback callback, void *context, io_iterator_t *iterator) {
    SInt32 vendor = 0;
    SInt32 product = 0;
    CFNumberRef vendorNumber = CFDictionaryGetValue(matching, CFSTR(kUSBVendorID));
    CFNumberRef productNumber = CFDictionaryGetValue(matching, CFSTR(kUSBProductID));
    assert(vendorNumber && productNumber);
    assert(CFNumberGetValue(vendorNumber, kCFNumberSInt32Type, &vendor));
    assert(CFNumberGetValue(productNumber, kCFNumberSInt32Type, &product));
    assert(vendor == 0x046d);
    assert(product == 0x08b2 || product == 0x08d7);
    assert(strcmp(notificationType, kIOFirstMatchNotification) == 0);
    assert(callback && context);
    products |= product == 0x08b2 ? 1 : 2;
    ++registrations;
    *iterator = IO_OBJECT_NULL;
    CFRelease(matching);
    return KERN_SUCCESS;
}

io_object_t IOIteratorNext(io_iterator_t iterator) {
    assert(iterator == IO_OBJECT_NULL);
    return IO_OBJECT_NULL;
}

int main(void) {
    @autoreleasepool {
        MyCameraCentral *central = [[MyCameraCentral alloc] init];
        assert([central startupWithNotificationsOnMainThread:NO recognizeLaterPlugins:YES]);
        assert(registrations == 2 && products == 3);
        assert([central numCameras] == 0);
        [central release];
        puts("hotplug registers exactly the two supported USB IDs");
    }
    return 0;
}
