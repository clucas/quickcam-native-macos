#import "../src/QuickCamCapture.m"
#include <assert.h>

enum Failure {
    NoFailure, MissingDevice, WrongClass, RegistryError, WrongRegistry,
    WrongVendor, WrongProduct, WrongLocation, DevicePlugin, DeviceQuery,
    USBVendorError, USBProductError, USBLocationError, WrongUSBIdentity,
    DeviceBusy, InterfaceIterator, InterfacePlugin, InterfaceQuery,
    InterfaceNumber, MissingVideo, InterfaceBusy, ControlError, ShortControl,
};
static enum Failure failure;
static uint64_t currentRegistry = 901, requestedRegistry;
static unsigned lookups, controls, deviceOpens, interfaceOpens, deviceCloses, interfaceCloses;
static unsigned liveObjects[5], livePlugins, liveDevices, liveInterfaces;
static unsigned iteratorIndex;
static BOOL enumeration, deviceOpened, interfaceOpened;
static const qc_device_info pro = {0x046d, 0x08b2, 0x21200000, 901};

typedef struct { IOCFPlugInInterface *vtable; unsigned kind; } FakePlugin;
typedef struct { IOUSBInterfaceInterface220 *vtable; UInt8 number; } FakeInterface;
static IOUSBDeviceInterface deviceTable;
static IOUSBDeviceInterface *device = &deviceTable;
static IOUSBInterfaceInterface220 interfaceTable;
static FakeInterface audio = {&interfaceTable, 1}, video = {&interfaceTable, 0};
static IOCFPlugInInterface pluginTable;
static FakePlugin devicePlugin = {&pluginTable, 0}, audioPlugin = {&pluginTable, 1}, videoPlugin = {&pluginTable, 2};

static void clean(void) {
    for (unsigned i=0; i<5; ++i) assert(liveObjects[i]==0);
    assert(!livePlugins && !liveDevices && !liveInterfaces);
    assert(!deviceOpened && !interfaceOpened);
    assert(deviceCloses==deviceOpens && interfaceCloses==interfaceOpens);
}

static void reset(enum Failure value) {
    clean();
    failure=value;
    lookups=controls=deviceOpens=interfaceOpens=deviceCloses=interfaceCloses=0;
    iteratorIndex=0;
    enumeration=NO;
}

CFMutableDictionaryRef IORegistryEntryIDMatching(uint64_t entryID) {
    requestedRegistry=entryID;
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
io_service_t IOServiceGetMatchingService(mach_port_t port, CFDictionaryRef matching) {
    ++lookups;
    CFRelease(matching);
    if (failure==MissingDevice || requestedRegistry!=currentRegistry) return IO_OBJECT_NULL;
    ++liveObjects[0];
    return 100;
}
CFMutableDictionaryRef IOServiceMatching(const char *name) {
    assert(strcmp(name, "IOUSBHostDevice")==0);
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
kern_return_t IOServiceGetMatchingServices(mach_port_t port, CFDictionaryRef matching, io_iterator_t *iterator) {
    CFRelease(matching);
    enumeration=YES;
    ++liveObjects[1];
    *iterator=101;
    return KERN_SUCCESS;
}
boolean_t IOObjectConformsTo(io_object_t object, const io_name_t name) {
    assert(object==100 && strcmp(name, "IOUSBHostDevice")==0);
    return failure!=WrongClass;
}
kern_return_t IORegistryEntryGetRegistryEntryID(io_registry_entry_t entry, uint64_t *entryID) {
    assert(entry==100);
    if (failure==RegistryError) return kIOReturnError;
    *entryID=currentRegistry+(failure==WrongRegistry);
    return KERN_SUCCESS;
}
CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    assert(entry==100);
    uint32_t value;
    if (CFEqual(key, CFSTR("idVendor"))) value=pro.vendor_id+(failure==WrongVendor);
    else if (CFEqual(key, CFSTR("idProduct"))) value=pro.product_id+(failure==WrongProduct);
    else { assert(CFEqual(key, CFSTR("locationID"))); value=pro.location_id+(failure==WrongLocation); }
    return CFNumberCreate(allocator, kCFNumberSInt32Type, &value);
}
io_object_t IOIteratorNext(io_iterator_t iterator) {
    assert(iterator==101 && liveObjects[1]);
    if (enumeration) {
        if (iteratorIndex++) return IO_OBJECT_NULL;
        ++liveObjects[0]; return 100;
    }
    unsigned next=iteratorIndex++;
    if (next>1 || (next==1 && failure==MissingVideo)) return IO_OBJECT_NULL;
    ++liveObjects[2+next];
    return 102+next;
}
kern_return_t IOObjectRelease(io_object_t object) {
    assert(object>=100 && object<=103 && liveObjects[object-100]);
    --liveObjects[object-100];
    return KERN_SUCCESS;
}
IOReturn IOCreatePlugInInterfaceForService(io_service_t service, CFUUIDRef type, CFUUIDRef pluginID,
                                          IOCFPlugInInterface ***output, SInt32 *score) {
    BOOL isDevice=service==100;
    assert(CFEqual(type, isDevice ? kIOUSBDeviceUserClientTypeID : kIOUSBInterfaceUserClientTypeID));
    assert(CFEqual(pluginID, kIOCFPlugInInterfaceID));
    if (failure==(isDevice ? DevicePlugin : InterfacePlugin)) return kIOReturnError;
    *output=(IOCFPlugInInterface **)(isDevice ? &devicePlugin : service==102 ? &audioPlugin : &videoPlugin);
    ++livePlugins;
    return kIOReturnSuccess;
}

static HRESULT query(void *self, REFIID uuid, LPVOID *output) {
    FakePlugin *plugin=self;
    if (failure==(plugin->kind==0 ? DeviceQuery : InterfaceQuery)) return E_NOINTERFACE;
    CFUUIDBytes expected=CFUUIDGetUUIDBytes(plugin->kind==0 ? kIOUSBDeviceInterfaceID : kIOUSBInterfaceInterfaceID220);
    assert(memcmp(&uuid, &expected, sizeof(uuid))==0);
    if (plugin->kind==0) { *output=&device; ++liveDevices; }
    else { *output=plugin->kind==1 ? (void *)&audio : (void *)&video; ++liveInterfaces; }
    return S_OK;
}
static ULONG pluginRelease(void *self) { assert(livePlugins); return --livePlugins; }
static ULONG deviceRelease(void *self) { assert(self==&device && liveDevices && !deviceOpened); return --liveDevices; }
static ULONG interfaceRelease(void *self) { assert(liveInterfaces && !interfaceOpened); return --liveInterfaces; }
static IOReturn getVendor(void *self, UInt16 *value) {
    *value=pro.vendor_id+(failure==WrongUSBIdentity);
    return failure==USBVendorError ? kIOReturnError : kIOReturnSuccess;
}
static IOReturn getProduct(void *self, UInt16 *value) {
    *value=pro.product_id;
    return failure==USBProductError ? kIOReturnError : kIOReturnSuccess;
}
static IOReturn getLocation(void *self, UInt32 *value) {
    *value=pro.location_id;
    return failure==USBLocationError ? kIOReturnError : kIOReturnSuccess;
}
static IOReturn deviceOpen(void *self) {
    if (failure==DeviceBusy) return kIOReturnExclusiveAccess;
    assert(!deviceOpened); deviceOpened=YES; ++deviceOpens;
    return kIOReturnSuccess;
}
static IOReturn deviceClose(void *self) {
    assert(deviceOpened && !interfaceOpened); deviceOpened=NO; ++deviceCloses;
    return kIOReturnSuccess;
}
static IOReturn getInterfaces(void *self, IOUSBFindInterfaceRequest *request, io_iterator_t *iterator) {
    assert(deviceOpened);
    if (failure==InterfaceIterator) return kIOReturnError;
    ++liveObjects[1]; *iterator=101;
    return kIOReturnSuccess;
}
static IOReturn getNumber(void *self, UInt8 *number) {
    *number=((FakeInterface *)self)->number;
    return failure==InterfaceNumber ? kIOReturnError : kIOReturnSuccess;
}
static IOReturn interfaceOpen(void *self) {
    assert(self==&video && deviceOpened);
    if (failure==InterfaceBusy) return kIOReturnExclusiveAccess;
    assert(!interfaceOpened); interfaceOpened=YES; ++interfaceOpens;
    return kIOReturnSuccess;
}
static IOReturn interfaceClose(void *self) {
    assert(self==&video && deviceOpened && interfaceOpened);
    interfaceOpened=NO; ++interfaceCloses;
    return kIOReturnSuccess;
}
static IOReturn control(void *self, UInt8 pipe, IOUSBDevRequestTO *request) {
    assert(self==&video && deviceOpened && interfaceOpened);
    assert(pipe==0 && request->bmRequestType==0x40 && request->bRequest==5);
    assert(request->wValue==0x3400 && request->wIndex==3 && request->wLength==2);
    assert(request->pData && ((UInt8 *)request->pData)[0]==0 && ((UInt8 *)request->pData)[1]==0);
    assert(request->noDataTimeout==250 && request->completionTimeout==250);
    ++controls;
    request->wLenDone=failure==ShortControl ? 1 : 2;
    return failure==ControlError ? kIOReturnNotResponding : kIOReturnSuccess;
}

@interface EnumerationCentral : MyCameraCentral
@end
@implementation EnumerationCentral
- (unsigned long)idOfCameraWithLocationID:(UInt32)location { return location==pro.location_id ? 1 : 0; }
@end

static qc_session *registeredSession(void) {
    qc_session *session=calloc(1, sizeof(*session));
    session->capture=[QCCaptureSession new];
    session->location=pro.location_id;
    session->registered=YES;
    [activeCameraLocations addObject:@(pro.location_id)];
    return session;
}

int main(void) {
    @autoreleasepool {
        pluginTable=(IOCFPlugInInterface){.QueryInterface=query, .Release=pluginRelease};
        deviceTable=(IOUSBDeviceInterface){.Release=deviceRelease, .GetDeviceVendor=getVendor,
            .GetDeviceProduct=getProduct, .GetLocationID=getLocation, .USBDeviceOpen=deviceOpen,
            .USBDeviceClose=deviceClose, .CreateInterfaceIterator=getInterfaces};
        interfaceTable=(IOUSBInterfaceInterface220){.Release=interfaceRelease, .GetInterfaceNumber=getNumber,
            .USBInterfaceOpen=interfaceOpen, .USBInterfaceClose=interfaceClose, .ControlRequestTO=control};
        for (enum Failure value=NoFailure; value<=ShortControl; ++value) {
            reset(value);
            int result=qc_prepare_idle_device(&pro);
            assert((result==0)==(value==NoFailure));
            assert(controls==(value==NoFailure || value==ControlError || value==ShortControl ? 1 : 0));
            assert(result ? strlen(qc_last_error())>0 : strlen(qc_last_error())==0);
            clean();
        }

        reset(NoFailure);
        assert(qc_prepare_idle_device(NULL)!=0);
        const uint16_t unsupported[]={0x08d7, 0x0825};
        for (unsigned i=0; i<2; ++i) {
            qc_device_info info=pro; info.product_id=unsupported[i];
            assert(qc_prepare_idle_device(&info)!=0);
        }
        qc_device_info info=pro; info.registry_id=0;
        assert(qc_prepare_idle_device(&info)!=0 && lookups==0);
        dispatch_semaphore_t checked=dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            @autoreleasepool {
                assert(qc_prepare_idle_device(&pro)!=0);
                assert(strstr(qc_last_error(), "main thread"));
                dispatch_semaphore_signal(checked);
            }
        });
        assert(dispatch_semaphore_wait(checked, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC))==0);
        dispatch_release(checked);
        assert(lookups==0);

        activeCameraLocations=[NSCountedSet new];
        qc_session *first=registeredSession(), *second=registeredSession();
        assert(qc_prepare_idle_device(&pro)!=0 && lookups==0);
        first->capture->stopReady=YES;
        assert(qc_finish_stop(first)==1);
        assert(qc_prepare_idle_device(&pro)!=0 && lookups==0);
        assert(qc_finish_stop(second)==0);
        second->capture->stopReady=YES;
        assert(qc_finish_stop(second)==1);
        assert(qc_prepare_idle_device(&pro)==0 && controls==1);

        reset(NoFailure);
        cameraCentral=[EnumerationCentral new];
        qc_device_info before={0}, after={0};
        assert(qc_enumerate(&before, 1)==1 && before.registry_id==currentRegistry);
        ++currentRegistry;
        reset(NoFailure);
        assert(qc_enumerate(&after, 1)==1 && after.registry_id==currentRegistry);
        assert(before.location_id==after.location_id && before.registry_id!=after.registry_id);
        reset(NoFailure);
        assert(qc_prepare_idle_device(&before)!=0 && controls==0);
        assert(qc_prepare_idle_device(&after)==0 && controls==1);
        reset(RegistryError);
        assert(qc_enumerate(&after, 1)==0 && strstr(qc_last_error(), "identity"));
        clean();
        [cameraCentral release]; cameraCentral=nil;
        [activeCameraLocations release]; activeCameraLocations=nil;
        puts("idle LED: exact connection, exclusive video ownership, bounded command, busy sessions, reconnect identity, and failure cleanup passed");
    }
    return 0;
}
