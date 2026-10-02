#import "MyCameraDriver.h"
#include <stdatomic.h>
#include <unistd.h>
@interface TestCentral : NSObject { @public atomic_int notifications; }
- (BOOL)doNotificationsOnMainThread;
- (void)cameraHasShutDown:(id)camera;
@end
@implementation TestCentral
- (BOOL)doNotificationsOnMainThread { return NO; }
- (void)cameraHasShutDown:(id)camera { atomic_fetch_add(&notifications, 1); }
@end
@interface TestDelegate : NSObject { @public atomic_int shutdowns; atomic_int lateGrab; TestCentral *owner; dispatch_semaphore_t stopped; }
@end
@implementation TestDelegate
- (void)cameraHasShutDown:(id)camera {
 if (atomic_load(&owner->notifications) != 1) abort();
 atomic_fetch_add(&shutdowns, 1);
 dispatch_semaphore_signal(stopped);
}
- (void)grabFinished:(id)camera withError:(CameraError)error {
 if (atomic_load(&shutdowns) != 0) atomic_fetch_add(&lateGrab, 1);
}
@end
@interface TestDriver : MyCameraDriver { @public atomic_int closes; }
@end
@implementation TestDriver
- (BOOL)supportsResolution:(CameraResolution)r fps:(short)f { return YES; }
- (CameraResolution)defaultResolutionAndRate:(short *)f { *f=5; return ResolutionSIF; }
- (CameraError)decodingThread { usleep(1000); return CameraErrorOK; }
- (void)usbCloseConnection { atomic_fetch_add(&closes, 1); }
@end
int main(void) {
 for (int i=0; i<100; ++i) {
  @autoreleasepool {
   TestCentral *central = [TestCentral new];
   TestDelegate *delegate = [TestDelegate new];
   delegate->owner=central; delegate->stopped=dispatch_semaphore_create(0);
   TestDriver *camera=[[TestDriver alloc] initWithCentral:central];
   [camera setDelegate:delegate]; [camera startupWithUsbLocationId:0]; [camera startGrabbing];
   dispatch_group_t group=dispatch_group_create();
   for (int j=0;j<4;++j) dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{ @autoreleasepool { [camera shutdown]; } });
   dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
   if (dispatch_semaphore_wait(delegate->stopped,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)) != 0) return 1;
   usleep(1000);
   if (atomic_load(&camera->closes)!=1 || atomic_load(&delegate->shutdowns)!=1 || atomic_load(&delegate->lateGrab)) return 2;
   [camera setDelegate:nil]; [camera release];
   dispatch_release(delegate->stopped); [delegate release]; [central release]; dispatch_release(group);
  }
 }
 puts("100 concurrent shutdown rounds passed");
 return 0;
}
