/*
 * OBS CMIO sink discovery follows pyvirtualcam's MIT-licensed virtual_output.hpp.
 * Source: https://github.com/letmaik/pyvirtualcam/blob/v0.15.0/pyvirtualcam/native_macos_obs_cmioextension/virtual_output.hpp
 * Copyright (C) 2025 Sebastian Beckmann; (C) 2021 Jannik Vogel.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
#import <Foundation/Foundation.h>
#import <CoreMediaIO/CoreMediaIO.h>
#import <CoreVideo/CoreVideo.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include "QCObsOutput.h"

struct qc_obs_output {
    CMIODeviceID device;
    CMIOStreamID stream;
    CMSimpleQueueRef queue;
    CVPixelBufferPoolRef pool;
    CFDictionaryRef limits;
    CMVideoFormatDescriptionRef format;
    uint32_t width, height, fps;
    BOOL started;
};

static _Thread_local char lastError[256];
static atomic_bool outputActive;

static int fail(const char *message, OSStatus status) {
    snprintf(lastError, sizeof(lastError), "%s (status %d)", message, (int)status);
    return -1;
}

static void queueAltered(CMIOStreamID stream, void *token, void *context) {}

static void *propertyArray(CMIOObjectID object, CMIOObjectPropertySelector selector, UInt32 *size) {
    CMIOObjectPropertyAddress address = {selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
    *size = 0;
    if (CMIOObjectGetPropertyDataSize(object, &address, 0, NULL, size) != noErr || !*size) return NULL;
    void *data = calloc(1, *size);
    if (!data) return NULL;
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(object, &address, 0, NULL, *size, &used, data) != noErr) {
        free(data);
        return NULL;
    }
    *size = used;
    return data;
}

qc_obs_output *qc_obs_open(uint32_t width, uint32_t height, uint32_t fps) {
    lastError[0] = '\0';
    if (!width || width % 2 || width > 4096 || !height || height > 2160 || !fps || fps > 60) {
        fail("Invalid virtual camera dimensions or frame rate", -1);
        return NULL;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(&outputActive, &expected, true)) {
        fail("A QuickCam output to OBS is already active", -1);
        return NULL;
    }
    qc_obs_output *output = calloc(1, sizeof(*output));
    if (!output) {
        atomic_store(&outputActive, false);
        fail("Cannot allocate OBS output", -1);
        return NULL;
    }
    output->width = width;
    output->height = height;
    output->fps = fps;
    output->limits = CFBridgingRetain(@{(id)kCVPixelBufferPoolAllocationThresholdKey: @8});
    UInt32 size;
    CMIODeviceID *devices = propertyArray(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices, &size);
    for (UInt32 i = 0; devices && i < size / sizeof(*devices); i++) {
        CMIOObjectPropertyAddress address = {kCMIODevicePropertyDeviceUID, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        CFStringRef uid = NULL;
        UInt32 used;
        OSStatus status = CMIOObjectGetPropertyData(devices[i], &address, 0, NULL, sizeof(uid), &used, &uid);
        if (status == noErr && uid) {
            if (CFEqual(uid, CFSTR("7626645E-4425-469E-9D8B-97E0FA59AC75"))) output->device = devices[i];
            CFRelease(uid);
        }
        if (output->device) break;
    }
    free(devices);
    if (!output->device) {
        fail("OBS Virtual Camera is not installed; activate it in OBS 30 or later", -1);
        goto failed;
    }
    CMIOStreamID *streams = propertyArray(output->device, kCMIODevicePropertyStreams, &size);
    for (UInt32 i = 0; streams && i < size / sizeof(*streams); i++) {
        CMIOObjectPropertyAddress address = {kCMIOStreamPropertyDirection, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        UInt32 direction = UINT32_MAX, used = 0;
        OSStatus status = CMIOObjectGetPropertyData(streams[i], &address, 0, NULL, sizeof(direction), &used, &direction);
        if (status == noErr && direction == 0) { output->stream = streams[i]; break; }
    }
    free(streams);
    if (!output->stream) { fail("OBS camera has no output stream", -1); goto failed; }
    NSDictionary *attributes = @{
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_422YpCbCr8),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    OSStatus status = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (CFDictionaryRef)attributes, &output->pool);
    if (status != noErr) { fail("Cannot allocate virtual camera frame pool", status); goto failed; }
    status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_422YpCbCr8, width, height, NULL, &output->format);
    if (status != noErr) { fail("Cannot create virtual camera format", status); goto failed; }
    status = CMIOStreamCopyBufferQueue(output->stream, queueAltered, NULL, &output->queue);
    if (status != noErr || !output->queue) { fail("Cannot get virtual camera queue", status); goto failed; }
    status = CMIODeviceStartStream(output->device, output->stream);
    if (status != noErr) { fail("Cannot start virtual camera stream", status); goto failed; }
    output->started = YES;
    return output;
failed:
    qc_obs_close(output);
    return NULL;
}

static uint8_t clampByte(int value) { return value < 0 ? 0 : value > 255 ? 255 : value; }

static void rgbToUYVY(const uint8_t *rgb24, size_t stride, uint8_t *destination,
                     size_t outputStride, uint32_t width, uint32_t height) {
    for (uint32_t y = 0; y < height; y++) {
        const uint8_t *sourceRow = rgb24 + y * stride;
        uint8_t *destinationRow = destination + y * outputStride;
        for (uint32_t x = 0; x < width; x += 2) {
            const uint8_t *a = sourceRow + x * 3, *b = a + 3;
            int r = (a[0] + b[0] + 1) / 2, g = (a[1] + b[1] + 1) / 2, blue = (a[2] + b[2] + 1) / 2;
            destinationRow[x * 2] = clampByte(128 + ((-38 * r - 74 * g + 112 * blue + 128) >> 8));
            destinationRow[x * 2 + 1] = clampByte(16 + ((66 * a[0] + 129 * a[1] + 25 * a[2] + 128) >> 8));
            destinationRow[x * 2 + 2] = clampByte(128 + ((112 * r - 94 * g - 18 * blue + 128) >> 8));
            destinationRow[x * 2 + 3] = clampByte(16 + ((66 * b[0] + 129 * b[1] + 25 * b[2] + 128) >> 8));
        }
    }
}

int qc_obs_send(qc_obs_output *output, const uint8_t *rgb24, size_t stride, uint64_t host_ns) {
    if (!output || !output->started || !rgb24 || stride < output->width * 3 || host_ns > INT64_MAX)
        return fail("Invalid virtual camera frame", -1);
    if (CMSimpleQueueGetCount(output->queue) >= CMSimpleQueueGetCapacity(output->queue)) return 1;
    CVPixelBufferRef pixels = NULL;
    OSStatus status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
        output->pool, output->limits, &pixels);
    if (status == kCVReturnWouldExceedAllocationThreshold) return 1;
    if (status != noErr) return fail("Cannot allocate virtual camera frame", status);
    status = CVPixelBufferLockBaseAddress(pixels, 0);
    if (status != noErr) { CVPixelBufferRelease(pixels); return fail("Cannot lock virtual camera frame", status); }
    uint8_t *destination = CVPixelBufferGetBaseAddress(pixels);
    size_t outputStride = CVPixelBufferGetBytesPerRow(pixels);
    rgbToUYVY(rgb24, stride, destination, outputStride, output->width, output->height);
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, output->fps),
        .presentationTimeStamp = CMTimeMake(host_ns, 1000000000),
        .decodeTimeStamp = kCMTimeInvalid
    };
    CMSampleBufferRef sample = NULL;
    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixels, true, NULL, NULL,
        output->format, &timing, &sample);
    CVPixelBufferRelease(pixels);
    if (status != noErr) return fail("Cannot create virtual camera sample", status);
    status = CMSimpleQueueEnqueue(output->queue, sample);
    if (status != noErr) { CFRelease(sample); return 1; }
    return 0;
}

void qc_obs_close(qc_obs_output *output) {
    if (!output) return;
    if (output->started) CMIODeviceStopStream(output->device, output->stream);
    if (output->queue) CFRelease(output->queue);
    if (output->format) CFRelease(output->format);
    if (output->pool) CVPixelBufferPoolRelease(output->pool);
    if (output->limits) CFRelease(output->limits);
    free(output);
    atomic_store(&outputActive, false);
}

const char *qc_obs_last_error(void) { return lastError; }
