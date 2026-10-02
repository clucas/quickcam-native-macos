/*
 Modified for Legacy QuickCam by Christophe Lucas, 2026-09-24.
 macam - webcam app and QuickTime driver component
 Copyright (C) 2002 Matthias Krauss (macam@matthias-krauss.de)

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 $Id$
 */

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include "MiscTools.h"

#import "MyCameraInfo.h"
#import "MyCameraCentral.h"
#import "MyCameraDriver.h"
#import "MyKiaraFamilyDriver.h"
#import "MyDummyCameraDriver.h"
#import "ZC030xDriver.h"

#include "unistd.h"


void DeviceAdded(void *refCon, io_iterator_t iterator);

static NSString* driverBundleName=@"net.sourceforge.webcam-osx.common";
static NSMutableDictionary* prefsDict=NULL;
MyCameraCentral* sharedCameraCentral=NULL;



@interface MyCameraRetirement : NSObject {
@public
    MyCameraInfo *info;
    MyCameraDriver *driver;
    dispatch_group_t completion;
    BOOL driverCompleted;
}
- (id)initWithInfo:(MyCameraInfo *)cameraInfo;
@end

@implementation MyCameraRetirement
- (id)initWithInfo:(MyCameraInfo *)cameraInfo {
    self = [super init];
    if (self) {
        info = [cameraInfo retain];
        driver = [[cameraInfo driver] retain];
        completion = dispatch_group_create();
        // Shutdown can return before the final USB callback.
        dispatch_group_enter(completion);
        dispatch_group_enter(completion);
    }
    return self;
}
- (void)dealloc {
    [info release];
    [driver release];
    dispatch_release(completion);
    [super dealloc];
}
@end

@interface MyCameraCentral (Private)

//Internal preferences handling. We cannot use NSUserDefaults here because we might be in someone else's bundle (in a lib)
- (id) prefsForKey:(NSString*) key;
- (void) setPrefs:(id)prefs forKey:(NSString*)key;
- (void) registerCameraDriver:(Class)driver;
- (void) stopUSBNotifications;
- (CameraError) locationIdOfUSBDeviceRef:(io_service_t)usbDeviceRef to:(UInt32*)outVal version:(UInt16*)bcdDevice;

- (NSString *) cameraDisabledKeyFromVendorID:(UInt16)vid andProductID:(UInt16)pid;
- (NSString *) cameraDisabledKeyFromDriver:(MyCameraDriver *)camera;

- (void) listAllCameras;
- (void) listAllDuplicates;
- (void) listAllMultiDriver;

@end
    

@implementation MyCameraCentral


//MyCameraCentral is a singleton. Use this function to get the shared instance
+ (MyCameraCentral*) sharedCameraCentral {
    if (!sharedCameraCentral) sharedCameraCentral=[[MyCameraCentral alloc] init];
    return sharedCameraCentral;
}

//See if someone has requested MyCameraCentral before
+ (BOOL) isCameraCentralExisting {
    return (sharedCameraCentral!=NULL)?YES:NO;
}


//Localization for driver-specific stuff. As a component, the standard stuff won't work...

+ (NSString*) localizedStringFor:(NSString*) str {
    NSBundle* bundle=[NSBundle bundleForClass:[self class]];
    NSString* ret=[bundle localizedStringForKey:str value:@"" table:@"DriverLocalizable"];
    return ret;
}

+ (void) localizedCStrFor:(char*)cKey into:(char*)cValue {
    NSAutoreleasePool* pool;
    NSString* string;
    const char* tmpCStr;
    if (!cValue) return;
    if (!cKey) return;
    pool=[[NSAutoreleasePool alloc] init];
    string=[NSString stringWithUTF8String:cKey];
    string=[self localizedStringFor:string];
    tmpCStr=[string UTF8String];
    CStr2CStr(tmpCStr,cValue);	//Note: No bounds check! Don't write dramas...
    [pool release];
}

- (char*) localizedCStrForError:(CameraError)err {
    char* cstr;
    switch (err) {
        case CameraErrorOK:
        case CameraErrorBusy:
        case CameraErrorNoPower:
        case CameraErrorNoCam:
        case CameraErrorNoMem:
        case CameraErrorNoBandwidth:
        case CameraErrorTimeout:
        case CameraErrorUSBProblem:
        case CameraErrorInternal:
            cstr=localizedErrorCStrs[err];
            break;
        default:
            cstr=localizedUnknownErrorCStr;
            break;
    }
    return cstr;
}
    

//Init, startup, shutdown, dealloc

- (id) init 
{
    [super init];
    cameraTypes=[[NSMutableArray alloc] initWithCapacity:10];
    cameras=[[NSMutableArray alloc] initWithCapacity:10];
    matchingNotifications = [[NSMutableArray alloc] init];
    retiringCameras = [[NSMutableArray alloc] init];
    delegate=NULL;
    inVDIG = NO;
    
//    if (Gestalt(gestaltSystemVersion, &osVersion) != noErr)
        osVersion = 0x1047;  // Assume recent OS version

    // Cache localized error codes
    
    [[self class] localizedCStrFor:"CameraErrorOK" into:localizedErrorCStrs[CameraErrorOK]];
    [[self class] localizedCStrFor:"CameraErrorBusy" into:localizedErrorCStrs[CameraErrorBusy]];
    [[self class] localizedCStrFor:"CameraErrorNoPower" into:localizedErrorCStrs[CameraErrorNoPower]];
    [[self class] localizedCStrFor:"CameraErrorNoCam" into:localizedErrorCStrs[CameraErrorNoCam]];
    [[self class] localizedCStrFor:"CameraErrorNoMem" into:localizedErrorCStrs[CameraErrorNoMem]];
    [[self class] localizedCStrFor:"CameraErrorNoBandwidth" into:localizedErrorCStrs[CameraErrorNoBandwidth]];
    [[self class] localizedCStrFor:"CameraErrorTimeout" into:localizedErrorCStrs[CameraErrorTimeout]];
    [[self class] localizedCStrFor:"CameraErrorUSBProblem" into:localizedErrorCStrs[CameraErrorUSBProblem]];
    [[self class] localizedCStrFor:"CameraErrorUnimplemented" into:localizedErrorCStrs[CameraErrorUnimplemented]];
    [[self class] localizedCStrFor:"CameraErrorInternal" into:localizedErrorCStrs[CameraErrorInternal]];
    [[self class] localizedCStrFor:"CameraErrorDecoding" into:localizedErrorCStrs[CameraErrorDecoding]];
    [[self class] localizedCStrFor:"CameraErrorUSBNeedsUSB2" into:localizedErrorCStrs[CameraErrorUSBNeedsUSB2]];
    [[self class] localizedCStrFor:"UnknownError" into:localizedUnknownErrorCStr];
    
    return self;
}

- (void) dealloc 
{
    [self shutdown];	//Make sure everything's shut down
    if (cameraTypes!=NULL) 
        [cameraTypes release]; 
    cameraTypes=NULL;
    
    if (cameras!=NULL) 
        [cameras release]; 
    cameras=NULL;
    
    [matchingNotifications release];
    [retiringCameras release];
    [super dealloc];
}

- (void) listAllCameras
{
    @synchronized (self) {
    int             i;
    MyCameraInfo *  info = NULL;
    
    printf("\n");
    printf("List of all Cameras:\n");
    printf("==========\n");
    
    for (i = 0; i < [cameraTypes count]; i++) 
    {
        info = [cameraTypes objectAtIndex:i];
        
        printf("%03lu, 0x%04X, 0x%04X, %s, %s\n", [info cid], (unsigned) [info vendorID], (unsigned) [info productID], [NSStringFromClass([info driverClass]) UTF8String], [[info cameraName] UTF8String]);
    }
    
    printf("========== ==========\n");
    }
}

- (void) listAllDuplicates
{
    @synchronized (self) {
    int             i, j;
    BOOL            first;
    MyCameraInfo *  info = NULL;
    
    printf("\n");
    printf("List of all Duplicates (VID, PID, Driver):\n");
    
    for (i = 0; i < [cameraTypes count]; i++) 
    {
        SInt32          usbVendor;
        SInt32          usbProduct;
        NSString *      driverName;
        
        first = YES;
        info = [cameraTypes objectAtIndex:i];
        
        usbVendor = [info vendorID];
        usbProduct = [info productID];
        driverName = NSStringFromClass([info driverClass]);
        
        for (j = 0; j < [cameraTypes count]; j++) 
        {
            MyCameraInfo * other = [cameraTypes objectAtIndex:j];
            
            if (usbVendor != [other vendorID]) 
                continue;
            
            if (usbProduct != [other productID]) 
                continue;
            
            if (![driverName isEqualToString:NSStringFromClass([other driverClass])]) 
                continue;
            
            if (j == i) 
                continue;
            
            if (j < i) 
                break;
            
            if (first) 
            {
                first = NO;
                printf("==========\n");
                printf("%03lu, 0x%04X, 0x%04X, %s, %s\n", [info cid], (unsigned) [info vendorID], (unsigned) [info productID], [NSStringFromClass([info driverClass]) UTF8String], [[info cameraName] UTF8String]);
            }
            printf("%03lu, 0x%04X, 0x%04X, %s, %s\n", [other cid], (unsigned) [other vendorID], (unsigned) [other productID], [NSStringFromClass([other driverClass]) UTF8String], [[other cameraName] UTF8String]);
        }
    }
    
    printf("========== ==========\n");
    }
}

- (void) listAllMultiDriver
{
    @synchronized (self) {
    int             i, j;
    BOOL            first;
    MyCameraInfo *  info = NULL;
    
    printf("\n");
    printf("List of cameras with Multiple Drivers (VID, PID):\n");
    
    for (i = 0; i < [cameraTypes count]; i++) 
    {
        SInt32          usbVendor;
        SInt32          usbProduct;
        
        first = YES;
        info = [cameraTypes objectAtIndex:i];
        
        usbVendor = [info vendorID];
        usbProduct = [info productID];
        
        for (j = 0; j < [cameraTypes count]; j++) 
        {
            MyCameraInfo * other = [cameraTypes objectAtIndex:j];
            
            if (usbVendor != [other vendorID]) 
                continue;
            
            if (usbProduct != [other productID]) 
                continue;
            
            if (j == i) 
                continue;
            
            if (j < i) 
                break;
            
            if (first) 
            {
                first = NO;
                printf("==========\n");
                printf("%03lu, 0x%04X, 0x%04X, %s, %s\n", [info cid], (unsigned) [info vendorID], (unsigned) [info productID], [NSStringFromClass([info driverClass]) UTF8String], [[info cameraName] UTF8String]);
            }
            printf("%03lu, 0x%04X, 0x%04X, %s, %s\n", [other cid], (unsigned) [other vendorID], (unsigned) [other productID], [NSStringFromClass([other driverClass]) UTF8String], [[other cameraName] UTF8String]);
        }
    }
    
    printf("========== ==========\n");
    }
}

- (BOOL) startupWithNotificationsOnMainThread:(BOOL)nomt recognizeLaterPlugins:(BOOL)rlp {
    @synchronized (self) {
        if (started) return YES;
        @autoreleasepool {
            doNotificationsOnMainThread = nomt;
            recognizeLaterPlugins = rlp;
            if (![cameraTypes count]) {
                [self registerCameraDriver:[MyKiaraFamilyDriver class]];
                [self registerCameraDriver:[ZC030xDriverMic class]];
            }
            notifyPort = IONotificationPortCreate(kIOMainPortDefault);
            if (!notifyPort) goto failed;
            CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(notifyPort);
            if (!source) goto failed;
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);

            for (MyCameraInfo *info in cameraTypes) {
                SInt32 vendor = [info vendorID];
                SInt32 product = [info productID];
                CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
                if (!matching) goto failed;
                CFNumberRef vendorNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vendor);
                CFNumberRef productNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &product);
                if (!vendorNumber || !productNumber) {
                    if (vendorNumber) CFRelease(vendorNumber);
                    if (productNumber) CFRelease(productNumber);
                    CFRelease(matching);
                    goto failed;
                }
                CFDictionarySetValue(matching, CFSTR(kUSBVendorID), vendorNumber);
                CFDictionarySetValue(matching, CFSTR(kUSBProductID), productNumber);
                CFRelease(vendorNumber);
                CFRelease(productNumber);
                io_iterator_t iterator = IO_OBJECT_NULL;
                kern_return_t result;
                if (recognizeLaterPlugins) {
                    result = IOServiceAddMatchingNotification(notifyPort, kIOFirstMatchNotification,
                        matching, DeviceAdded, info, &iterator);
                } else {
                    result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
                }
                if (result != KERN_SUCCESS) {
                    if (iterator) IOObjectRelease(iterator);
                    goto failed;
                }
                if (recognizeLaterPlugins && iterator)
                    [matchingNotifications addObject:[NSNumber numberWithUnsignedInt:iterator]];
                DeviceAdded(info, iterator);
                if (!recognizeLaterPlugins && iterator) IOObjectRelease(iterator);
            }
            long numTestCameras = [[self prefsForKey:@"Dummy cameras"] longValue];
            for (long i = 0; i < numTestCameras; ++i) {
                MyCameraInfo *info = [[MyCameraInfo alloc] init];
                [info setDriverClass:[MyDummyCameraDriver class]];
                [info setProductID:[MyDummyCameraDriver cameraUsbProductID]];
                [info setVendorID:[MyDummyCameraDriver cameraUsbVendorID]];
                [info setCameraName:[NSString stringWithFormat:@"%@ #%li", [MyDummyCameraDriver cameraName], i + 1]];
                [info setCentral:self];
                [cameras addObject:info];
            }
            started = YES;
            return YES;
        failed:
            [self shutdown];
            return NO;
        }
    }
}

- (void)stopUSBNotifications {
    for (NSNumber *iterator in matchingNotifications)
        IOObjectRelease([iterator unsignedIntValue]);
    [matchingNotifications removeAllObjects];
    for (MyCameraInfo *info in cameras) {
        if ([info notification]) {
            IOObjectRelease([info notification]);
            [info setNotification:IO_OBJECT_NULL];
        }
    }
    if (notifyPort) {
        IONotificationPortDestroy(notifyPort);
        notifyPort = NULL;
    }
    started = NO;
}

- (void) shutdown {
    @synchronized (self) {
    [self stopUSBNotifications];
    MyCameraInfo* info;
    NSAutoreleasePool* pool=[[NSAutoreleasePool alloc] init];	//Get a pool to catch the remaining drivers

    //shutdown all cameras
    while ([cameras count]>0) {
        info=[cameras lastObject];
        [cameras removeLastObject];
        //disconnect from the driver and autorelease our retain
        if ([info driver]!=NULL) {
            [[info driver] setCentral:NULL];
            [[info driver] shutdown];
        }
        [info release];
    }

    //release cameryTypes cameraInfos
    while ([cameraTypes count]>0) {
        info=[cameraTypes lastObject];
        [cameraTypes removeLastObject];
        [info release];
    }
    [pool release];
    }
}

- (id) delegate {
    return delegate;
}

- (void) setDelegate:(id)d {
    delegate=d;
}

- (BOOL) doNotificationsOnMainThread {
    return doNotificationsOnMainThread;
}

- (void) setVDIG:(BOOL)v
{
    inVDIG = v;
}

- (SInt32) osVersion
{
    return osVersion;
}

- (short) numCameras {
    @synchronized (self) {
    return [cameras count];
    }
}

- (short) indexOfCamera:(MyCameraDriver*)driver {
    @synchronized (self) {
    short i=0;
    while (i<[cameras count]) {
        if ([[cameras objectAtIndex:i] driver]==driver) return i;
        else i++;
    }
    return -1;
    }
}

- (short) indexOfDriverClass:(Class)driverClass 
{
    @synchronized (self) {
    short i=0;
    while (i<[cameras count]) 
    {
        if ([[cameras objectAtIndex:i] driverClass] == driverClass) 
            return i;
        else i++;
    }
    return -1;
    }
}

- (unsigned long) idOfCameraWithIndex:(short)idx {
    @synchronized (self) {
    if ((idx<0)||(idx>=[self numCameras])) return 0;
    return [[cameras objectAtIndex:idx] cid];
    }
}

- (UInt16) versionOfCameraWithIndex:(short)idx 
{
    @synchronized (self) {
    if ((idx < 0) || (idx >= [self numCameras])) 
        return 0;
    
    return [[cameras objectAtIndex:idx] versionNumber];
    }
}

- (unsigned long) idOfCameraWithLocationID:(UInt32)locID {
    @synchronized (self) {
    short i;
    for (i=0;i<[cameras count];i++) {
        if ([[cameras objectAtIndex:i] locationID]==locID) return [[cameras objectAtIndex:i] cid];
    }
    return 0;    
    }
}

- (CameraError) useCameraWithID:(unsigned long)cid to:(MyCameraDriver**)outCam acceptDummy:(BOOL)acceptDummy {
    @synchronized (self) {
    long l;
    MyCameraInfo* dev=NULL;
    MyCameraDriver* cam=NULL;
    CameraError err=CameraErrorOK;
    if (outCam) *outCam=NULL;
    for (l=0;(l<[cameras count])&&(dev==NULL);l++) {
        dev=[cameras objectAtIndex:l];
        if ([dev cid]!=cid) dev=NULL;
    }
    if (dev==NULL) {
#ifdef VERBOSE
        NSLog(@"MyCameraCentral: cid not found");
#endif
        err=CameraErrorInternal;
    }
    if (!err) {
        if ([dev driver]) err=CameraErrorBusy;
    }
    if (!err) {
        cam=[[[dev driverClass] alloc] initWithCentral:self];
        if (!cam) {
#ifdef VERBOSE
            NSLog(@"MyCameraCentral: could not instantiate driver");
#endif
            err=CameraErrorNoMem;
        }
    }
    if (!err) {
        [cam setDelegate:delegate];
        [cam setCameraInfo:dev];
        err=[cam startupWithUsbLocationId:[dev locationID]];
        if (err!=CameraErrorOK) {
            [cam release];
            cam=NULL;
        }
    }
    if (err&&acceptDummy) {	//We have an error and the sender wants a dummy in case of an error
        cam=[self useDummyForError:err];
    }
    if (cam!=NULL) {
        [dev setDriver:cam];
//        [cam setCameraInfo:dev];
        [self setCameraToDefaults:cam];
        if (outCam) *outCam=cam;
    }
    return err;
    }
}

- (MyCameraDriver*) useDummyForError:(CameraError)err {
    MyCameraDriver* driver=[[MyDummyCameraDriver alloc] initWithError:err central:self];
    if (driver) {
        [driver setDelegate:delegate];
        [driver startupWithUsbLocationId:0];
    }
    return driver;
}

- (NSString *) nameForID:(unsigned long) cid 
{
    @synchronized (self) {
    long l;
    
    for (l = 0; l < [cameras count]; l++) 
        if ([[cameras objectAtIndex:l] cid] == cid) 
        {
 			NSString * name = [[cameras objectAtIndex:l] cameraName]; // get camera name
 			int  i, counter = 1;
 			NSString * modifiedName = nil;
            
 			for (i = 0; i < [cameras count]; i++)  // look again over all cameras
            {
 				NSString * findName = [[cameras objectAtIndex:i] cameraName];
				if( [findName isEqualToString:name]) // Are there any cameras with the same name?
 				{
 					if (i == l) 
                        modifiedName = [NSString stringWithFormat: @"%@ #%d", name, counter];  // We found our own camera again 
                    
 					counter++;  // Number of cameras with the same name (plus one)
 				}
 			}
            
            return [[((counter > 2) ? modifiedName : name) retain] autorelease];  // Modify name if more then one camera
        } 
    
    return NULL;
    }
}

- (NSString *) nameForDriver:(MyCameraDriver*) driver 
{
    @synchronized (self) {
    long l;
    
    for (l = 0; l < [cameras count]; l++) 
        if ([[cameras objectAtIndex:l] driver] == driver) 
            return [[[[cameras objectAtIndex:l] cameraName] retain] autorelease];
    
    return NULL;
    }
}

- (BOOL) getName:(char*)name forID:(unsigned long)cid maxLength:(unsigned)maxLength
{
    NSString * camName = [self nameForID:cid];
    
    if (!camName) 
        return NO;
    
    [camName getCString:name maxLength:maxLength encoding:NSUTF8StringEncoding];
    
    return YES;
}

- (BOOL) getRegistrationName:(char*)name forID:(unsigned long)cid maxLength:(unsigned)maxLength
{
    @synchronized (self) {
    long l;
    NSString * camName = nil;
    
    for (l = 0; l < [cameras count]; l++) 
        if ([[cameras objectAtIndex:l] cid] == cid) 
        {
 			NSString * name = [[cameras objectAtIndex:l] cameraName];
            camName = [NSString stringWithFormat: @"%@ #%lu", name, cid]; 
 			// This is not so user friendly but name is not be changed after other cameras unplugging etc.
        }
    
    if (!camName) 
        return NO;
    
    [camName getCString:name maxLength:maxLength encoding:NSUTF8StringEncoding];
    
    return YES;
    }
}

/*These functions read and write the camera settings. We cannot use the direct user defaults mechanism because we're sometimes a client in another app and we don't want to mess up the app's preferences. So we use the lower-level persistentDomainForName mechanism. */

- (BOOL) setCameraToDefaults:(MyCameraDriver*) cam {
    @synchronized (self) {
    NSAutoreleasePool* pool=[[NSAutoreleasePool alloc] init];
    BOOL ok=YES;
    short idx;
    unsigned long cid;
    NSDictionary* camDict;
    if (ok) {
        if (!cam) ok=NO;
    }
    if (ok) {
        idx=[self indexOfCamera:cam];
        if (idx<0) ok=NO;		//This camera is not listed as connected
    }
    if (ok) {
        cid=[self idOfCameraWithIndex:idx];
        if (cid<1) ok=NO;		//This camera has no cid (should not happen ever)
    }
    if (ok) {
        //We use the driver class instead of the camera name to prevent differences due to localization
        camDict=[self prefsForKey:NSStringFromClass([[cameras objectAtIndex:idx] driverClass])];
        if (!camDict) ok=NO;		//There are no defaults for the camera listed
    }
    if (ok) {
        if ([camDict objectForKey:@"brightness"])
            [cam setBrightness:[[camDict objectForKey:@"brightness"] floatValue]];
        if ([camDict objectForKey:@"contrast"])
            [cam setContrast:[[camDict objectForKey:@"contrast"] floatValue]];
        if ([camDict objectForKey:@"saturation"])
            [cam setSaturation:[[camDict objectForKey:@"saturation"] floatValue]];
        if ([camDict objectForKey:@"hue"])
            [cam setHue:[[camDict objectForKey:@"hue"] floatValue]];
        if ([camDict objectForKey:@"gamma"])
            [cam setGamma:[[camDict objectForKey:@"gamma"] floatValue]];
        if ([camDict objectForKey:@"sharpness"])
            [cam setSharpness:[[camDict objectForKey:@"sharpness"] floatValue]];
        if ([camDict objectForKey:@"gain"])
            [cam setGain:[[camDict objectForKey:@"gain"] floatValue]];
        if ([camDict objectForKey:@"shutter"])
            [cam setShutter:[[camDict objectForKey:@"shutter"] floatValue]];
        if ([camDict objectForKey:@"autogain"])
            [cam setAutoGain:[[camDict objectForKey:@"autogain"] boolValue]];
        if ([camDict objectForKey:@"hflip"])
            [cam setHFlip:[[camDict objectForKey:@"hflip"] boolValue]];
        if ([camDict objectForKey:@"orientation"])
            [cam setOrientation:[[camDict objectForKey:@"orientation"] shortValue]];
        if ([camDict objectForKey:@"compression"])
            [cam setCompression:[[camDict objectForKey:@"compression"] shortValue]];
        if ([camDict objectForKey:@"resolution"]&&[camDict objectForKey:@"fps"])
            [cam setResolution:[[camDict objectForKey:@"resolution"] shortValue] fps:[[camDict objectForKey:@"fps"] shortValue]];
       	if ([camDict objectForKey:@"white balance"])
            [cam setWhiteBalanceMode:(WhiteBalanceMode)[[camDict objectForKey:@"white balance"] shortValue]];
       	if ([camDict objectForKey:@"flicker control"])
            [cam setFlicker:(FlickerType)[[camDict objectForKey:@"flicker control"] shortValue]];
       	if ([camDict objectForKey:@"bandwidth reduction"])
            [cam setUSBReducedBandwidth:[[camDict objectForKey:@"bandwidth reduction"] boolValue]];
    }
    [pool release];
    return ok;
    }
}

- (BOOL) deleteCameraSettings:(MyCameraDriver *) cam
{
    @synchronized (self) {
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    BOOL ok = YES;
    short idx;
    unsigned long cid;
    
    if (ok) 
    {
        if (!cam) 
            ok = NO;
    }
    
    if (ok) 
    {
        idx = [self indexOfCamera:cam];
        if (idx < 0) 
            ok = NO;		//This camera is not listed as connected
    }
    if (ok) 
    {
        cid = [self idOfCameraWithIndex:idx];
        if (cid < 1) 
            ok = NO;		//This camera has no cid (should not happen ever)
    }
    if (ok) 
    {
        [self setPrefs:NULL forKey:NSStringFromClass([[cameras objectAtIndex:idx] driverClass])];
    }
    [pool release];
    return ok;
    }
}

- (BOOL) saveCameraSettingsAsDefaults:(MyCameraDriver*) cam {
    @synchronized (self) {
    NSAutoreleasePool* pool=[[NSAutoreleasePool alloc] init];
    BOOL ok=YES;
    short idx;
    unsigned long cid;
    NSMutableDictionary* camDict;
    if (ok) {
        if (!cam) ok=NO;
    }
    if (ok) {
        idx=[self indexOfCamera:cam];
        if (idx<0) ok=NO;		//This camera is not listed as connected
    }
    if (ok) {
        cid=[self idOfCameraWithIndex:idx];
        if (cid<1) ok=NO;		//This camera has no cid (should not happen ever)
    }
    if (ok) {
        camDict=[NSMutableDictionary dictionaryWithCapacity:11];
        if (!camDict) ok=NO;
    }
    if (ok) {
        if ([cam canSetBrightness])
            [camDict setObject:[NSNumber numberWithFloat:[cam brightness]] forKey:@"brightness"];
        if ([cam canSetContrast])
            [camDict setObject:[NSNumber numberWithFloat:[cam contrast]] forKey:@"contrast"];
        if ([cam canSetSaturation])
            [camDict setObject:[NSNumber numberWithFloat:[cam saturation]] forKey:@"saturation"];
        if ([cam canSetHue])
            [camDict setObject:[NSNumber numberWithFloat:[cam hue]] forKey:@"hue"];
        if ([cam canSetGamma])
            [camDict setObject:[NSNumber numberWithFloat:[cam gamma]] forKey:@"gamma"];
        if ([cam canSetSharpness])
            [camDict setObject:[NSNumber numberWithFloat:[cam sharpness]] forKey:@"sharpness"];
        if ([cam canSetGain])
            [camDict setObject:[NSNumber numberWithFloat:[cam gain]] forKey:@"gain"];
        if ([cam canSetShutter])
            [camDict setObject:[NSNumber numberWithFloat:[cam shutter]] forKey:@"shutter"];
        if ([cam canSetAutoGain])
            [camDict setObject:[NSNumber numberWithBool:[cam isAutoGain]] forKey:@"autogain"];
        if ([cam canSetHFlip])
            [camDict setObject:[NSNumber numberWithBool:[cam hFlip]] forKey:@"hflip"];
        if (YES) // ([cam canSetOrientation])
            [camDict setObject:[NSNumber numberWithShort:[cam orientation]] forKey:@"orientation"];
        if ([cam maxCompression]>0)
            [camDict setObject:[NSNumber numberWithShort:[cam compression]] forKey:@"compression"];
        if ([cam canSetWhiteBalanceMode])
            [camDict setObject:[NSNumber numberWithShort:(short)[cam whiteBalanceMode]] forKey:@"white balance"];
        if ([cam canSetFlicker])
            [camDict setObject:[NSNumber numberWithShort:(short)[cam flicker]] forKey:@"flicker control"];
        if ([cam canSetUSBReducedBandwidth])
            [camDict setObject:[NSNumber numberWithBool:[cam usbReducedBandwidth]] forKey:@"bandwidth reduction"];
        
        [camDict setObject:[NSNumber numberWithShort:[cam resolution]] forKey:@"resolution"];
        [camDict setObject:[NSNumber numberWithShort:[cam fps]] forKey:@"fps"];
        //We use the driver class instead of the camera name to prevent differences due to localization
        [self setPrefs:camDict forKey:NSStringFromClass([[cameras objectAtIndex:idx] driverClass])];
    }
    [pool release];
    return ok;
    }
}

void DeviceRemoved( void *refCon,io_service_t service,natural_t messageType,void *messageArgument ) {
    MyCameraInfo* dev=(MyCameraInfo*)refCon;
    if (messageType!=kIOMessageServiceIsTerminated) return;
    if (dev==NULL) {
#ifdef VERBOSE
        NSLog(@"MaCameraCentral:DeviceRemoved: bad refCon");
#endif
    } else {
        [[dev central] deviceRemoved:[dev cid]];
    }
}
    
- (void) deviceRemoved:(unsigned long)cid {
    MyCameraRetirement *retirement = nil;
    @synchronized (self) {
        MyCameraInfo *removed = nil;
        for (MyCameraInfo *info in cameras) {
            if ([info cid] == cid) {
                removed = info;
                break;
            }
        }
        if (!removed) return;
        if ([removed notification]) {
            IOObjectRelease([removed notification]);
            [removed setNotification:IO_OBJECT_NULL];
        }
        if ([removed driver]) {
            retirement = [[MyCameraRetirement alloc] initWithInfo:removed];
            [retiringCameras addObject:retirement];
        }
        [cameras removeObjectIdenticalTo:removed];
        [removed release];
    }
    if (!retirement) return;
    dispatch_group_notify(retirement->completion,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                @synchronized (self) {
                    [retiringCameras removeObjectIdenticalTo:retirement];
                }
            }
        });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            @synchronized (retirement->driver) {
                [retirement->driver stopUsingUSB];
                [retirement->driver shutdown];
            }
            dispatch_group_leave(retirement->completion);
        }
    });
    [retirement release];
}

void DeviceAdded(void *refCon, io_iterator_t iterator) {
    MyCameraInfo* info=(MyCameraInfo*)refCon;
    if (info!=NULL) {
        [[info central] deviceAdded:iterator info:info];
    }
}

- (void) deviceAdded:(io_iterator_t)iterator info:(MyCameraInfo*)type {
    @synchronized (self) {
    kern_return_t	ret;
    io_service_t	usbDeviceRef;
    MyCameraInfo*	dev;
    io_object_t		notification;
    while ((usbDeviceRef = IOIteratorNext(iterator))) {
        UInt32 locID;
        UInt16 versionNumber;
        
        //Setup our data object we use to track the device while it is plugged
        dev=[type copy];
        if (!dev) {
#ifdef VERBOSE
            NSLog(@"Could not copy MyCameraInfo object on insertion of a device");
#endif
            IOObjectRelease(usbDeviceRef);
            continue;
        }

        //Request notification if the device is unplugged
        ret = IOServiceAddInterestNotification(notifyPort,
                                               usbDeviceRef,
                                               kIOGeneralInterest,
                                               DeviceRemoved,
                                               dev,
                                               &notification);
        if (ret!=KERN_SUCCESS) {
#ifdef VERBOSE
            NSLog(@"IOServiceAddInterestNotification returned %08x\n",ret);
#endif
            IOObjectRelease(usbDeviceRef);
            [dev release];
            continue;
        }
        //Try to find our USB location ID
        if ([self locationIdOfUSBDeviceRef:usbDeviceRef to:&locID version:&versionNumber]!=CameraErrorOK) {
#ifdef VERBOSE
            NSLog(@"failed to get location id");
#endif
            IOObjectRelease(notification);
            IOObjectRelease(usbDeviceRef);
            [dev release];
            continue;
        }
        //Remember the notification (we have to release it later)
        [dev setNotification:notification];
        [dev setLocationID:locID];
        [dev setVersionNumber:versionNumber];
        IOObjectRelease(usbDeviceRef);

        //Put the new entry to the list of available cameras
        [cameras addObject:dev];

        //Spread the news that a camera was plugged in
        [self cameraDetected:[dev cid]];
    }
    }
}

- (void) cameraDetected:(unsigned long) cid {
    if (delegate) {
        if ([delegate respondsToSelector:@selector(cameraDetected:)]) {
            [delegate cameraDetected:cid];
        }
    }
}

- (void) cameraHasShutDown:(id)sender {
    @synchronized (self) {
    long i;
    MyCameraInfo* info;
    for(i=0;i<[cameras count];i++) {
        info=[cameras objectAtIndex:i];
        if ([info driver]==sender) {
            [info setDriver:NULL];	//If it's still in the list: mark it as available
        }
    }
    for (MyCameraRetirement *retirement in retiringCameras) {
        if (retirement->driver == sender && !retirement->driverCompleted) {
            retirement->driverCompleted = YES;
            [retirement->info setDriver:nil];
            dispatch_group_leave(retirement->completion);
        }
    }
    [sender autorelease];		//We clear our reference to that driver. When we receive this, we have built it.
    }
}



- (id) prefsForKey:(NSString*) key {
    id val=NULL;
    if (!key) return NULL;		//No key, no value
    if (!prefsDict) {			//No prefs there. Try to load prefs file.
        NSString* pathName=[[NSString stringWithFormat:@"~/Library/Preferences/%@.plist",driverBundleName] stringByExpandingTildeInPath];
        NSDictionary* dict;
        dict=[NSDictionary dictionaryWithContentsOfFile:pathName];
        if (dict) prefsDict=[dict mutableCopy];
    }
    if (!prefsDict) {			//No file there. Try to open a new one
        prefsDict=[[NSMutableDictionary alloc] initWithCapacity:3];
    }
    if (!prefsDict) return NULL;	//Still no prefs dict there - give up
    val=[prefsDict objectForKey:key];
    if (!val) return NULL;		//No value for that key
    val=[val copy];
    if (!val) return NULL;		//Probably no mem or some non-copying object (could that happen? I guess not)
    [val autorelease];
    return val;
}

- (void) setPrefs:(id)value forKey:(NSString*)key {
    NSString* pathName;
    if (!key) return;			//No key, no change
    [self prefsForKey:key];		//Ensure the prefs are loaded
    if (!prefsDict) return;		//Still no prefs? Give up.
//Do the change
    if (value) {
        [prefsDict setObject:[[value copy] autorelease] forKey:key];
    } else {
        [prefsDict removeObjectForKey:key];
    }
//Write to file
    pathName=[[NSString stringWithFormat:@"~/Library/Preferences/%@.plist",driverBundleName] stringByExpandingTildeInPath];
    [prefsDict writeToFile:pathName atomically:YES];
}

- (void) registerCameraDriver:(Class)driver 
{
    @synchronized (self) {
    NSArray * arr = [driver cameraUsbDescriptions];
    int i;
    
    for (i = 0; i < [arr count]; i++) 
    {
        NSDictionary * dict = [arr objectAtIndex:i];
        UInt16 vid = [[dict objectForKey:@"idVendor"] unsignedShortValue];
        UInt16 pid = [[dict objectForKey:@"idProduct"] unsignedShortValue];
        if (vid != 0x046d || (pid != 0x08b2 && pid != 0x08d7))
            continue;
        
        if (inVDIG) 
            if ([self cameraDisabled:driver withVendorID:vid andProductID:pid]) 
                continue;  // Skip this one
        
        MyCameraInfo * info = [[MyCameraInfo alloc] init];
        if (info != NULL) 
        {
            [info setCameraName:[dict objectForKey:@"name"]];
            [info setVendorID:[[dict objectForKey:@"idVendor"] unsignedShortValue]];
            [info setProductID:[[dict objectForKey:@"idProduct"] unsignedShortValue]];
            [info setDriverClass:driver];
            [info setCentral: self];
            [cameraTypes addObject:info];
        }
    }
    }
}

- (NSString *) cameraDisabledKeyFromVendorID:(UInt16)vid andProductID:(UInt16)pid
{
    return [NSString stringWithFormat:@"Disable 0x%04x:0x%04x", vid, pid];
}

- (NSString *) cameraDisabledKeyFromDriver:(MyCameraDriver *)camera
{
    @synchronized (self) {
    short idx;
    UInt16 vid, pid;
    MyCameraInfo * info = NULL;
    
    idx = [self indexOfCamera:camera];
    if (idx < 0)  // This camera is not listed as connected
        return NULL;
    
    info = [cameras objectAtIndex:idx];
    vid = [info vendorID];
    pid = [info productID];
    
    return [self cameraDisabledKeyFromVendorID:vid andProductID:pid];
    }
}

//
//
//
- (BOOL) cameraDisabled:(Class)driver withVendorID:(UInt16)vid andProductID:(UInt16)pid
{
    BOOL disable = NO;  // default setting
    NSString * key = NULL;
    id obj = NULL;
    
    if ([driver isUVC]) 
        if (osVersion >= 0x1043) 
            disable = YES;
    
    key = [self cameraDisabledKeyFromVendorID:vid andProductID:pid];
    
    obj = [self prefsForKey:key];
    if (obj) 
        disable = [obj boolValue];
    
    return disable;
}

//
// set this camera to be disabled in the preferences
// this has no effect on the macam application
//
- (void) setDisableCamera:(MyCameraDriver *)camera yesNo:(BOOL)disable
{
    NSString * key = [self cameraDisabledKeyFromDriver:camera];
    
    if (key == NULL) 
        return;
    
    [self setPrefs:[NSNumber numberWithBool:disable] forKey:key];
}

//
// return whether the camera is set to be disabled in the preferences,
// not whether it is actually disabled now or not
//
- (BOOL) isCameraDisabled:(MyCameraDriver *)camera
{
    @synchronized (self) {
    short idx;
    UInt16 vid, pid;
    MyCameraInfo * info = NULL;
    
    idx = [self indexOfCamera:camera];
    if (idx < 0)  // This camera is not listed as connected
        return NO;
    
    info = [cameras objectAtIndex:idx];
    vid = [info vendorID];
    pid = [info productID];
    
    return [self cameraDisabled:[camera class] withVendorID:vid andProductID:pid];
    }
}

- (CameraError) locationIdOfUSBDeviceRef:(io_service_t)usbDeviceRef to:(UInt32*)outVal version:(UInt16*)bcdDevice
{
    UInt32 locID=0;
    UInt16 version = 0;
    kern_return_t kernelErr;
    SInt32 score;
    IOCFPlugInInterface **plugin=NULL;
    CameraError err=CameraErrorOK;
    HRESULT res;
    IOUSBDeviceInterface** dev=NULL;

    kernelErr = IOCreatePlugInInterfaceForService(usbDeviceRef, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);

    if ((kernelErr!=kIOReturnSuccess)||(!plugin)) {
#ifdef VERBOSE
        NSLog(@"MyCameraCentral: IOCreatePlugInInterfaceForService; Could not get plugin");
#endif
        return CameraErrorUSBProblem;
    }
    if (!err) {
        res=(*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),(LPVOID*)(&dev));
        (*plugin)->Release(plugin);
        plugin=NULL;
        if ((res)||(!dev)) {
#ifdef VERBOSE
            NSLog(@"MyCameraCentral: IOCreatePlugInInterfaceForService; Could not get device interface");
#endif
            err=CameraErrorUSBProblem;
        }
    }
    if (!err) {
        kernelErr = (*dev)->GetLocationID(dev,&locID);
        if (kernelErr!=KERN_SUCCESS) 
        {
#ifdef VERBOSE
            NSLog(@"MyCameraCentral: IOCreatePlugInInterfaceForService; Could not get Location ID");
#endif
            err=CameraErrorUSBProblem;
        }
        kernelErr = (*dev)->GetDeviceReleaseNumber(dev, &version);
        if (kernelErr!=KERN_SUCCESS) 
        {
#ifdef VERBOSE
            NSLog(@"MyCameraCentral: IOCreatePlugInInterfaceForService; Could not get Release Number");
#endif
            err=CameraErrorUSBProblem;
        }
        (*dev)->Release(dev);
    }
    if (outVal) 
    {
        if (!err) 
            *outVal=locID;
        else 
            *outVal=0;
    }
    if (bcdDevice) 
    {
        if (!err) 
            *bcdDevice=version;
        else 
            *bcdDevice=0;
    }
    return err;
}


@end
