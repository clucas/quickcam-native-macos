#import <Foundation/Foundation.h>
#include "QuickCamCapture.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *path;
    _Atomic unsigned frames;
    _Atomic unsigned saved;
} CaptureResult;

static void receiveFrame(void *context, const uint8_t *rgb, uint32_t width,
                         uint32_t height, size_t stride, uint64_t hostNS) {
    CaptureResult *result = context;
    unsigned frame = atomic_fetch_add(&result->frames, 1) + 1;
    if (frame == 10 && result->path) {
        FILE *file = fopen(result->path, "wb");
        if (file) {
            fprintf(file, "P6\n%u %u\n255\n", width, height);
            for (unsigned y = 0; y < height; ++y) fwrite(rgb + y * stride, 3, width, file);
            if (!ferror(file)) atomic_store(&result->saved, 1);
            fclose(file);
        }
    }
    if (frame == 1 || frame % 10 == 0)
        fprintf(stderr, "FRAME %u %ux%u stride=%zu host_ns=%llu\n", frame,
                width, height, stride, (unsigned long long)hostNS);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (qc_initialize()) {
            fprintf(stderr, "%s\n", qc_last_error());
            return 1;
        }
        qc_device_info devices[8];
        size_t count = qc_enumerate(devices, 8);
        for (size_t i = 0; i < count && i < 8; ++i)
            fprintf(stderr, "CAMERA %04x:%04x location=%08x\n", devices[i].vendor_id,
                    devices[i].product_id, devices[i].location_id);
        if (argc == 1) return count ? 0 : 1;
        unsigned product = (unsigned)strtoul(argv[1], NULL, 16);
        uint32_t location = 0;
        for (size_t i = 0; i < count && i < 8; ++i)
            if (devices[i].product_id == product) location = devices[i].location_id;
        if (!location) {
            fprintf(stderr, "Requested USB product was not found.\n");
            return 2;
        }
        CaptureResult result = {.path = argc > 2 ? argv[2] : NULL};
        unsigned fps = argc > 3 ? (unsigned)strtoul(argv[3], NULL, 10) : 5;
        unsigned width = argc > 4 ? (unsigned)strtoul(argv[4], NULL, 10) : 320;
        unsigned height = argc > 5 ? (unsigned)strtoul(argv[5], NULL, 10) : 240;
        qc_session *session = qc_start(location, width, height, fps, receiveFrame, &result);
        if (!session) {
            fprintf(stderr, "%s\n", qc_last_error());
            return 3;
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
        while (atomic_load(&result.frames) < 30 && [deadline timeIntervalSinceNow] > 0)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        qc_stop(session);
        unsigned frames = atomic_load(&result.frames);
        fprintf(stderr, "RESULT frames=%u saved=%u\n", frames, atomic_load(&result.saved));
        return frames >= 10 && (!result.path || atomic_load(&result.saved)) ? 0 : 4;
    }
}
