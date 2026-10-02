#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>

static int inspect(io_service_t service) {
    IOCFPlugInInterface **plugin = NULL;
    IOUSBDeviceInterface **device = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(service,
        kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (result != kIOReturnSuccess) return 0;
    HRESULT query = (*plugin)->QueryInterface(plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
    (*plugin)->Release(plugin);
    if (query || !device) return 0;
    UInt16 vendor = 0, product = 0;
    (*device)->GetDeviceVendor(device, &vendor);
    (*device)->GetDeviceProduct(device, &product);
    if (vendor != 0x046d || (product != 0x08b2 && product != 0x08d7)) {
        (*device)->Release(device);
        return 0;
    }
    UInt32 location = 0;
    (*device)->GetLocationID(device, &location);
    printf("DEVICE %04x:%04x location=%08x\n", vendor, product, location);
    result = (*device)->USBDeviceOpen(device);
    printf("  device open: 0x%08x\n", result);
    int opened = result == kIOReturnSuccess;
    IOUSBConfigurationDescriptorPtr config = NULL;
    result = (*device)->GetConfigurationDescriptorPtr(device, 0, &config);
    if (result == kIOReturnSuccess && config) {
        unsigned total = CFSwapInt16LittleToHost(config->wTotalLength);
        unsigned char *base = (unsigned char *)config;
        for (unsigned offset = 0; offset + 2 <= total;) {
            unsigned length = base[offset];
            if (length < 2 || offset + length > total) break;
            if (base[offset + 1] == kUSBInterfaceDesc && length >= 9) {
                printf("  interface=%u alt=%u endpoints=%u class=%02x subclass=%02x protocol=%02x\n",
                    base[offset + 2], base[offset + 3], base[offset + 4],
                    base[offset + 5], base[offset + 6], base[offset + 7]);
            } else if (base[offset + 1] == kUSBEndpointDesc && length >= 7) {
                printf("    endpoint=%02x attributes=%02x packet=%u interval=%u\n",
                    base[offset + 2], base[offset + 3],
                    base[offset + 4] | (base[offset + 5] << 8), base[offset + 6]);
            }
            offset += length;
        }
    }
    IOUSBFindInterfaceRequest request = {kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare};
    io_iterator_t iterator = IO_OBJECT_NULL;
    result = (*device)->CreateInterfaceIterator(device, &request, &iterator);
    if (result == kIOReturnSuccess) {
        io_service_t interfaceService;
        while ((interfaceService = IOIteratorNext(iterator))) {
            plugin = NULL;
            IOUSBInterfaceInterface **interface = NULL;
            result = IOCreatePlugInInterfaceForService(interfaceService,
                kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
            IOObjectRelease(interfaceService);
            if (result != kIOReturnSuccess) continue;
            query = (*plugin)->QueryInterface(plugin,
                CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&interface);
            (*plugin)->Release(plugin);
            if (query || !interface) continue;
            UInt8 number = 255;
            (*interface)->GetInterfaceNumber(interface, &number);
            if (number == 0) {
                result = (*interface)->USBInterfaceOpen(interface);
                printf("  video interface open: 0x%08x\n", result);
                if (result == kIOReturnSuccess) (*interface)->USBInterfaceClose(interface);
            }
            (*interface)->Release(interface);
        }
        IOObjectRelease(iterator);
    }
    if (opened) (*device)->USBDeviceClose(device);
    (*device)->Release(device);
    return 1;
}

int main(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn result = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOUSBHostDevice"), &iterator);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "USB enumeration failed: 0x%08x\n", result);
        return 1;
    }
    int count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        count += inspect(service);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    printf("Matched legacy cameras: %d\n", count);
    return count == 2 ? 0 : 2;
}
