#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#include <stdatomic.h>

@interface VerifyFrames : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
@public
    _Atomic unsigned frames;
    NSString *path;
}
@end
@implementation VerifyFrames
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample
       fromConnection:(AVCaptureConnection *)connection {
    unsigned frame = atomic_fetch_add(&frames, 1) + 1;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
    if (frame == 10) {
        CIImage *image = [CIImage imageWithCVPixelBuffer:pixels];
        CIContext *context = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [context createCGImage:image fromRect:image.extent];
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
        BOOL saved = [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                      writeToFile:path atomically:YES];
        fprintf(stderr, "FRAME %u: %zux%zu saved=%s\n", frame,
                CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), saved ? "yes" : "NO");
        [bitmap release];
        CGImageRelease(cgImage);
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusNotDetermined) {
            __block BOOL answered = NO;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{ answered = YES; });
            }];
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:45];
            while (!answered && until.timeIntervalSinceNow > 0)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, .1, false);
        }
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
            fprintf(stderr, "Camera permission is required for AVFoundation verification.\n");
            return 3;
        }
        AVCaptureDevice *camera = nil;
        for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo])
            if ([device.uniqueID isEqualToString:@"7626645E-4425-469E-9D8B-97E0FA59AC75"]) camera = device;
        if (!camera) { fprintf(stderr, "OBS Virtual Camera is not available.\n"); return 4; }
        fprintf(stderr, "Using only %s (%s)\n", camera.localizedName.UTF8String, camera.uniqueID.UTF8String);
        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&error];
        if (!input) { fprintf(stderr, "%s\n", error.description.UTF8String); return 5; }
        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        output.alwaysDiscardsLateVideoFrames = YES;
        VerifyFrames *receiver = [[VerifyFrames alloc] init];
        receiver->path = [[NSString alloc] initWithUTF8String:argv[1]];
        dispatch_queue_t queue = dispatch_queue_create("local.quickcam.verification", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:receiver queue:queue];
        if (![session canAddInput:input] || ![session canAddOutput:output]) return 6;
        [session addInput:input];
        [session addOutput:output];
        [session startRunning];
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:12];
        while (atomic_load(&receiver->frames) < 20 && until.timeIntervalSinceNow > 0)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, .1, false);
        [session stopRunning];
        [output setSampleBufferDelegate:nil queue:NULL];
        dispatch_sync(queue, ^{});
        unsigned frames = atomic_load(&receiver->frames);
        fprintf(stderr, "AVFOUNDATION RESULT frames=%u\n", frames);
        [receiver->path release];
        [receiver release];
        [session release];
        [output release];
        dispatch_release(queue);
        return frames >= 20 ? 0 : 7;
    }
}
