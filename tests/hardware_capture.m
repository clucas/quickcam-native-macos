#import <Foundation/Foundation.h>
#include "QuickCamCapture.h"
#include <stdatomic.h>
#include <stdio.h>

typedef struct {
    _Atomic unsigned frames;
    _Atomic unsigned invalid;
    uint64_t timestamp;
    unsigned product;
    unsigned round;
} Result;

static void frame(void *context, const uint8_t *rgb, uint32_t width, uint32_t height,
                  size_t stride, uint64_t timestamp) {
    Result *result = context;
    if (!rgb || width != 640 || height != 480 || stride < width * 3 ||
        (result->timestamp && timestamp <= result->timestamp))
        atomic_fetch_add(&result->invalid, 1);
    result->timestamp = timestamp;
    unsigned count = atomic_fetch_add(&result->frames, 1) + 1;
    if (count == 15 && result->round == 0) {
        char path[128];
        snprintf(path, sizeof(path), "build/camera-%04x-vga.ppm", result->product);
        FILE *file = fopen(path, "wb");
        if (file) {
            fprintf(file, "P6\n%u %u\n255\n", width, height);
            for (unsigned y = 0; y < height; ++y) fwrite(rgb + y * stride, 3, width, file);
            fclose(file);
        }
    }
}

int main(void) {
    @autoreleasepool {
        qc_device_info devices[8];
        size_t count = qc_enumerate(devices, 8);
        if (count != 2) { fprintf(stderr, "Expected both legacy cameras; got %zu.\n", count); return 1; }
        for (unsigned round = 0; round < 2; ++round) {
            Result results[2] = {{0}};
            qc_session *sessions[2] = {0};
            for (size_t i = 0; i < count; ++i) {
                if (devices[i].vendor_id != 0x046d ||
                    (devices[i].product_id != 0x08b2 && devices[i].product_id != 0x08d7)) return 2;
                results[i].product = devices[i].product_id;
                results[i].round = round;
                sessions[i] = qc_start(devices[i].location_id, 640, 480, 5, frame, &results[i]);
                if (!sessions[i]) {
                    fprintf(stderr, "START %04x: %s\n", devices[i].product_id, qc_last_error());
                    for (size_t j = 0; j < i; ++j) qc_stop(sessions[j]);
                    return 3;
                }
            }
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
            while ([deadline timeIntervalSinceNow] > 0 &&
                   (atomic_load(&results[0].frames) < 20 || atomic_load(&results[1].frames) < 20))
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, .1, false);
            for (size_t i = 0; i < count; ++i) qc_stop(sessions[i]);
            unsigned snapshots[2] = {atomic_load(&results[0].frames), atomic_load(&results[1].frames)};
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, .5, false);
            for (size_t i = 0; i < count; ++i) {
                unsigned frames = atomic_load(&results[i].frames);
                unsigned invalid = atomic_load(&results[i].invalid);
                fprintf(stderr, "ROUND %u CAMERA %04x frames=%u invalid=%u stopped=%s\n",
                        round, devices[i].product_id, frames, invalid, frames == snapshots[i] ? "yes" : "NO");
                if (frames < 20 || invalid || frames != snapshots[i]) return 4;
            }
        }
        fprintf(stderr, "PASS: both cameras capture VGA simultaneously, stop, and restart.\n");
        return 0;
    }
}
