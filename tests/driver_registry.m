#import "MyCameraCentral.h"
#include <stdatomic.h>
@interface TestRegistry : MyCameraCentral
- (MyCameraInfo *)addSyntheticCamera;
@end
@implementation TestRegistry
- (MyCameraInfo *)addSyntheticCamera {
 @synchronized(self) {
  MyCameraInfo *info=[MyCameraInfo new];
  [info setCameraName:@"Concurrent camera"];
  [info setDriverClass:[NSObject class]];
  [info setLocationID:123]; [info setVendorID:0x046d]; [info setProductID:0x08b2];
  [cameras addObject:info];
  return [info retain];
 }
}
@end
int main(void) {
 @autoreleasepool {
  TestRegistry *central=[TestRegistry new];
  dispatch_group_t group=dispatch_group_create();
  for (int worker=0;worker<4;++worker) dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
   for (int round=0;round<5000;++round) @autoreleasepool {
    if (worker==0) {
     MyCameraInfo *info=[central addSyntheticCamera];
     [central deviceRemoved:[info cid]];
     [info release];
    } else if (worker==1) {
     [central cameraHasShutDown:[NSObject new]];
    } else {
     unsigned long cid=[central idOfCameraWithIndex:0];
     NSString *name=[central nameForID:cid];
     if (name && ![name isEqualToString:@"Concurrent camera"]) abort();
     [central numCameras]; [central versionOfCameraWithIndex:0];
     [central idOfCameraWithLocationID:123]; [central indexOfDriverClass:[NSObject class]];
    }
   }
  });
  if (dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))) return 1;
  if ([central numCameras]!=0) return 2;
  dispatch_release(group); [central release];
 }
 puts("20,000 concurrent registry operations passed");
 return 0;
}
