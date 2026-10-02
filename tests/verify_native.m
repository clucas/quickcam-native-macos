#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#include <stdatomic.h>

@interface NativeFrames : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
@public
    _Atomic unsigned frames;
    _Atomic unsigned invalid;
    CMTime previousTimestamp;
    BOOL captureSnapshot;
    CVPixelBufferRef snapshot;
}
@end

@implementation NativeFrames
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample
       fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sample);
    unsigned count = atomic_load(&frames);
    BOOL valid = pixels && CVPixelBufferGetWidth(pixels) == 640 &&
        CVPixelBufferGetHeight(pixels) == 480 &&
        CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA &&
        CMTIME_IS_NUMERIC(timestamp) &&
        (!count || CMTimeCompare(timestamp, previousTimestamp) > 0);
    if (!valid) atomic_fetch_add(&invalid, 1);
    if (valid && captureSnapshot && !snapshot && count >= 9)
        snapshot = CVPixelBufferRetain(pixels);
    previousTimestamp = timestamp;
    atomic_fetch_add(&frames, 1);
}

- (void)dealloc {
    if (snapshot) CVPixelBufferRelease(snapshot);
    [super dealloc];
}
@end

static BOOL writeSnapshot(CVPixelBufferRef pixels, NSString *path) {
    if (!pixels) {
        fprintf(stderr, "No valid frame is available for snapshot %s.\n", path.fileSystemRepresentation);
        return NO;
    }
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixels];
    CIContext *context = [CIContext contextWithOptions:nil];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSError *error = nil;
    BOOL saved = colorSpace && [context writePNGRepresentationOfImage:image
        toURL:[NSURL fileURLWithPath:path] format:kCIFormatRGBA8 colorSpace:colorSpace options:@{} error:&error];
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    if (!saved)
        fprintf(stderr, "Cannot save snapshot %s: %s\n", path.fileSystemRepresentation,
                error ? error.description.UTF8String : "Cannot create the PNG image.");
    return saved;
}

static BOOL awaitCameraPermission(void) {
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusNotDetermined) {
        __block BOOL answered = NO;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ answered = YES; });
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
        while (!answered && deadline.timeIntervalSinceNow > 0)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, .1, false);
    }
    return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusAuthorized;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *product = nil, *snapshotDirectory = nil;
        BOOL validArguments = YES;
        for (int index = 1; index < argc; ++index) {
            NSString *argument = [NSString stringWithUTF8String:argv[index]];
            if (!argument.length) {
                validArguments = NO;
                break;
            }
            if ([argument isEqualToString:@"--snapshot-dir"] && !snapshotDirectory && index + 1 < argc) {
                NSString *directory = [NSString stringWithUTF8String:argv[++index]];
                if (!directory.length || [directory hasPrefix:@"--"]) {
                    validArguments = NO;
                    break;
                }
                snapshotDirectory = [directory.stringByExpandingTildeInPath stringByStandardizingPath];
            } else if (!product && [@[@"08b2", @"08d7"] containsObject:argument.lowercaseString]) {
                product = argument.lowercaseString;
            } else {
                validArguments = NO;
                break;
            }
        }
        if (!validArguments) {
            fprintf(stderr, "Usage: QuickCam Native Verification [08b2|08d7] [--snapshot-dir DIRECTORY]\n");
            return 2;
        }
        if (snapshotDirectory) {
            NSError *error = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:snapshotDirectory
                withIntermediateDirectories:YES attributes:nil error:&error]) {
                fprintf(stderr, "Cannot create snapshot directory %s: %s\n",
                        snapshotDirectory.fileSystemRepresentation, error.description.UTF8String);
                return 8;
            }
        }
        if (!awaitCameraPermission()) {
            fprintf(stderr, "Camera permission is required for native-camera verification.\n");
            return 3;
        }
        NSDictionary *models = @{@"08B2": @"Logitech QuickCam Pro 4000",
                                 @"08D7": @"Logitech QuickCam Communicate STX"};
        NSMutableDictionary *cameras = [NSMutableDictionary dictionary];
        for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
            for (NSString *identifier in models) {
                NSString *prefix = [@"0D39E1F7-8B41-4364-9F4D-" stringByAppendingString:identifier];
                if ([device.uniqueID.uppercaseString hasPrefix:prefix] &&
                    [device.localizedName isEqualToString:models[identifier]]) cameras[identifier] = device;
            }
        }
        NSArray *products = product ? @[product.uppercaseString] : @[@"08B2", @"08D7"];
        for (NSString *identifier in products) {
            if (!cameras[identifier]) {
                fprintf(stderr, "Native camera %s is missing; activate the extension and connect the webcam.\n",
                        identifier.UTF8String);
                return 4;
            }
        }
        NSMutableArray *sessions = [NSMutableArray array];
        NSMutableArray *outputs = [NSMutableArray array];
        NSMutableArray *receivers = [NSMutableArray array];
        dispatch_queue_t queue = dispatch_queue_create("local.quickcam.native-verification", DISPATCH_QUEUE_SERIAL);
        int result = 0;
        for (NSString *identifier in products) {
            AVCaptureDevice *camera = cameras[identifier];
            NSError *error = nil;
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&error];
            if (!input) {
                fprintf(stderr, "Cannot open %s: %s\n", identifier.UTF8String, error.description.UTF8String);
                result = 5;
                break;
            }
            AVCaptureSession *session = [[[AVCaptureSession alloc] init] autorelease];
            AVCaptureVideoDataOutput *output = [[[AVCaptureVideoDataOutput alloc] init] autorelease];
            NativeFrames *receiver = [[[NativeFrames alloc] init] autorelease];
            receiver->captureSnapshot = snapshotDirectory != nil;
            output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            output.alwaysDiscardsLateVideoFrames = YES;
            if (![session canAddInput:input] || ![session canAddOutput:output]) {
                result = 6;
                break;
            }
            [output setSampleBufferDelegate:receiver queue:queue];
            [session addInput:input];
            [session addOutput:output];
            [sessions addObject:session];
            [outputs addObject:output];
            [receivers addObject:receiver];
            fprintf(stderr, "Opening only %s (%s)\n", camera.localizedName.UTF8String, camera.uniqueID.UTF8String);
        }
        if (!result) {
            for (AVCaptureSession *session in sessions) [session startRunning];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
            while (deadline.timeIntervalSinceNow > 0) {
                BOOL complete = YES;
                for (NativeFrames *receiver in receivers)
                    if (atomic_load(&receiver->frames) < 20) complete = NO;
                if (complete) break;
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, .1, false);
            }
        }
        for (AVCaptureSession *session in sessions) [session stopRunning];
        for (AVCaptureVideoDataOutput *output in outputs) [output setSampleBufferDelegate:nil queue:NULL];
        dispatch_sync(queue, ^{});
        for (NSUInteger index = 0; index < receivers.count; ++index) {
            NativeFrames *receiver = receivers[index];
            unsigned frames = atomic_load(&receiver->frames), invalid = atomic_load(&receiver->invalid);
            fprintf(stderr, "CAMERA %s frames=%u invalid=%u\n", [products[index] UTF8String], frames, invalid);
            if (!result && (frames < 20 || invalid)) result = 7;
            if (snapshotDirectory) {
                NSString *filename = [NSString stringWithFormat:@"quickcam-%@.png", [products[index] lowercaseString]];
                NSString *path = [snapshotDirectory stringByAppendingPathComponent:filename];
                if (writeSnapshot(receiver->snapshot, path))
                    fprintf(stderr, "SNAPSHOT %s %s\n", [products[index] UTF8String], path.fileSystemRepresentation);
                else if (!result) result = 8;
            }
        }
        dispatch_release(queue);
        return result;
    }
}
