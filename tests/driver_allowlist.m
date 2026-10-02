#import "MyCameraCentral.h"
#import "MyKiaraFamilyDriver.h"
#import "ZC030xDriver.h"
@interface MyCameraCentral (DriverTest)
- (void)registerCameraDriver:(Class)driver;
@end
int main(void) {
 @autoreleasepool {
   MyCameraCentral *central = [[MyCameraCentral alloc] init];
   [central registerCameraDriver:[MyKiaraFamilyDriver class]];
   [central registerCameraDriver:[ZC030xDriverMic class]];
   NSArray *registered = [central valueForKey:@"cameraTypes"];
   if ([registered count] != 2) return 1;
   for (MyCameraInfo *info in registered) {
     if ([info vendorID] != 0x046d || ([info productID] != 0x08b2 && [info productID] != 0x08d7)) return 2;
   }
   MyKiaraFamilyDriver *camera = [[MyKiaraFamilyDriver alloc] initWithCentral:central];
   if (![camera supportsResolution:ResolutionSIF fps:5] || ![camera supportsResolution:ResolutionVGA fps:5]) return 3;
   [camera release];
   [central release];
   puts("native driver class and USB allowlist checks passed");
 }
 return 0;
}
