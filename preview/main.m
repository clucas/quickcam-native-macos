#import <Cocoa/Cocoa.h>
#include <stdatomic.h>
#include "QuickCamCapture.h"
#include "QCObsOutput.h"

@class QCPreviewApp;
@interface QCCameraPanel : NSObject {
@public
    QCPreviewApp *app;
    uint16_t product;
    qc_session *session;
    NSView *view;
    NSImageView *imageView;
    NSTextField *status;
    NSButton *button;
    _Atomic bool queuedFrame;
    uint64_t frameNumber;
    uint64_t generation;
}
- (id)initWithProduct:(uint16_t)identifier name:(NSString *)name app:(QCPreviewApp *)owner;
- (void)toggle:(id)sender;
- (void)stop;
@end

@interface QCPreviewApp : NSObject <NSApplicationDelegate> {
@public
    NSWindow *window;
    NSArray *panels;
    NSPopUpButton *selection;
    NSButton *outputButton;
    NSTextField *outputStatus;
    qc_obs_output *output;
    uint16_t outputProduct;
}
- (void)sendFrame:(NSData *)data stride:(size_t)stride time:(uint64_t)time product:(uint16_t)product;
- (void)stopOutput;
@end

static NSTextField *label(NSString *text, NSRect frame, CGFloat size) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.frame = frame;
    field.font = [NSFont systemFontOfSize:size];
    return field;
}

static void receiveFrame(void *context, const uint8_t *rgb, uint32_t width,
                         uint32_t height, size_t stride, uint64_t hostNS) {
    QCCameraPanel *panel = context;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&panel->queuedFrame, &expected, true)) return;
    NSData *data = [[NSData alloc] initWithBytes:rgb length:stride * height];
    uint64_t frame = ++panel->frameNumber;
    uint64_t generation = panel->generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (panel->session && panel->generation == generation) {
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width * 3 bitsPerPixel:24];
            for (uint32_t row = 0; row < height; ++row)
                memcpy(bitmap.bitmapData + row * bitmap.bytesPerRow,
                       (const uint8_t *)data.bytes + row * stride, width * 3);
            NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
            [image addRepresentation:bitmap];
            panel->imageView.image = image;
            panel->status.stringValue = [NSString stringWithFormat:@"Live · %u × %u · %llu frames", width, height, frame];
            [panel->app sendFrame:data stride:stride time:hostNS product:panel->product];
            [image release];
            [bitmap release];
        }
        atomic_store(&panel->queuedFrame, false);
    });
    [data release];
}

@implementation QCCameraPanel
- (id)initWithProduct:(uint16_t)identifier name:(NSString *)name app:(QCPreviewApp *)owner {
    self = [super init];
    if (!self) return nil;
    product = identifier;
    app = owner;
    view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 416, 408)];
    NSTextField *title = label(name, NSMakeRect(0, 376, 416, 28), 19);
    title.font = [NSFont boldSystemFontOfSize:19];
    [view addSubview:title];
    imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 56, 416, 312)];
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    imageView.wantsLayer = YES;
    imageView.layer.backgroundColor = NSColor.blackColor.CGColor;
    imageView.layer.cornerRadius = 10;
    [view addSubview:imageView];
    status = [label(@"Camera stopped", NSMakeRect(0, 26, 416, 24), 12) retain];
    [view addSubview:status];
    button = [[NSButton buttonWithTitle:@"Start preview" target:self action:@selector(toggle:)] retain];
    button.frame = NSMakeRect(0, 0, 150, 28);
    [view addSubview:button];
    return self;
}
- (void)toggle:(id)sender {
    if (session) { [self stop]; return; }
    qc_device_info devices[8];
    size_t count = qc_enumerate(devices, 8);
    uint32_t location = 0;
    for (size_t i = 0; i < count && i < 8; ++i)
        if (devices[i].product_id == product) location = devices[i].location_id;
    if (!location) {
        status.stringValue = @"Connect this camera, then try again.";
        return;
    }
    ++generation;
    frameNumber = 0;
    status.stringValue = @"Starting camera…";
    session = qc_start(location, 640, 480, 5, receiveFrame, self);
    if (!session) {
        status.stringValue = [NSString stringWithUTF8String:qc_last_error()];
        return;
    }
    button.title = @"Stop camera";
}
- (void)stop {
    if (!session) return;
    if (app->output && app->outputProduct == product) [app stopOutput];
    qc_stop(session);
    session = NULL;
    ++generation;
    button.title = @"Start preview";
    status.stringValue = @"Camera stopped";
    imageView.image = nil;
}
- (void)dealloc {
    [self stop];
    [view release];
    [imageView release];
    [status release];
    [button release];
    [super dealloc];
}
@end

@implementation QCPreviewApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMenu *menu = [[[NSMenu alloc] init] autorelease];
    NSMenuItem *item = [[[NSMenuItem alloc] init] autorelease];
    [menu addItem:item];
    NSMenu *appMenu = [[[NSMenu alloc] initWithTitle:@"Legacy QuickCam"] autorelease];
    [appMenu addItemWithTitle:@"Quit Legacy QuickCam" action:@selector(terminate:) keyEquivalent:@"q"];
    item.submenu = appMenu;
    NSApp.mainMenu = menu;
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 904, 594)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Legacy QuickCam";
    window.releasedWhenClosed = NO;
    [window center];
    NSView *content = window.contentView;
    NSTextField *title = label(@"Your QuickCams, live", NSMakeRect(28, 544, 840, 30), 25);
    title.font = [NSFont boldSystemFontOfSize:25];
    [content addSubview:title];
    [content addSubview:label(@"Preview both cameras. Send either one to your video apps.", NSMakeRect(28, 516, 840, 24), 13)];
    panels = [[NSArray alloc] initWithObjects:
        [[[QCCameraPanel alloc] initWithProduct:0x08b2 name:@"QuickCam Pro 4000" app:self] autorelease],
        [[[QCCameraPanel alloc] initWithProduct:0x08d7 name:@"QuickCam Communicate STX" app:self] autorelease], nil];
    for (NSUInteger index = 0; index < panels.count; ++index) {
        QCCameraPanel *panel = panels[index];
        panel->view.frameOrigin = NSMakePoint(28 + index * 440, 100);
        [content addSubview:panel->view];
    }
    selection = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(28, 52, 270, 30) pullsDown:NO];
    [selection addItemsWithTitles:@[@"QuickCam Pro 4000", @"QuickCam Communicate STX"]];
    [content addSubview:selection];
    outputButton = [[NSButton buttonWithTitle:@"Send to video apps" target:self action:@selector(toggleOutput:)] retain];
    outputButton.frame = NSMakeRect(310, 52, 178, 30);
    [content addSubview:outputButton];
    outputStatus = [label(@"In your video app, select OBS Virtual Camera.", NSMakeRect(28, 18, 848, 26), 12) retain];
    [content addSubview:outputStatus];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(checkCameras:)
                                  userInfo:nil repeats:YES];
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--preview-all"])
        for (QCCameraPanel *panel in panels) [panel toggle:nil];
}
- (void)checkCameras:(NSTimer *)timer {
    for (QCCameraPanel *panel in panels) {
        if (panel->session && qc_status(panel->session) <= 0) {
            [panel stop];
            panel->status.stringValue = @"Camera disconnected or capture ended. Reconnect and start again.";
        }
    }
}
- (void)toggleOutput:(id)sender {
    if (output) { [self stopOutput]; return; }
    QCCameraPanel *panel = panels[selection.indexOfSelectedItem];
    if (!panel->session) [panel toggle:nil];
    if (!panel->session) return;
    output = qc_obs_open(640, 480, 5);
    if (!output) {
        outputStatus.stringValue = [NSString stringWithUTF8String:qc_obs_last_error()];
        return;
    }
    outputProduct = panel->product;
    selection.enabled = NO;
    outputButton.title = @"Stop sharing";
    outputStatus.stringValue = @"Sharing this camera. Select OBS Virtual Camera in your video app.";
}
- (void)sendFrame:(NSData *)data stride:(size_t)stride time:(uint64_t)time product:(uint16_t)product {
    if (output && outputProduct == product && qc_obs_send(output, data.bytes, stride, time) < 0) {
        NSString *error = [NSString stringWithUTF8String:qc_obs_last_error()];
        [self stopOutput];
        outputStatus.stringValue = error;
    }
}
- (void)stopOutput {
    if (output) qc_obs_close(output);
    output = NULL;
    selection.enabled = YES;
    outputButton.title = @"Send to video apps";
    outputStatus.stringValue = @"Sharing stopped. Click Send to video apps to resume.";
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopOutput];
    for (QCCameraPanel *panel in panels) [panel stop];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        QCPreviewApp *delegate = [[QCPreviewApp alloc] init];
        NSApp.delegate = delegate;
        [NSApp run];
        [delegate release];
    }
    return 0;
}
