#include "yuv2rgb.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const uint8_t luma[2][4] = {{16, 64, 128, 235}, {0, 90, 180, 255}};
static const uint8_t chromaU[2] = {90, 200};
static const uint8_t chromaV[2] = {240, 16};
static const uint8_t colorRGB[2][4][3] = {
    {{173, 0, 0}, {221, 0, 0}, {0, 183, 255}, {77, 255, 255}},
    {{157, 0, 0}, {247, 23, 22}, {22, 235, 255}, {97, 255, 255}},
};

static size_t makeSource(uint8_t *source, YUVStyle style, int width, int height,
                         bool color) {
    uint8_t *cursor = source;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; x += 4) {
            if (style == YUVCPIA422Style || (style == YUVCPIA420Style && y % 2 == 0)) {
                for (int pair = 0; pair < 2; ++pair) {
                    *cursor++ = luma[y % 2][pair * 2];
                    *cursor++ = color ? chromaU[pair] : 128;
                    *cursor++ = luma[y % 2][pair * 2 + 1];
                    *cursor++ = color ? chromaV[pair] : 128;
                }
            } else {
                memcpy(cursor, luma[y % 2], 4);
                cursor += 4;
                if (style == YUVPhilipsStyle) {
                    for (int pair = 0; pair < 2; ++pair)
                        *cursor++ = color ? (y % 2 ? chromaV[pair] : chromaU[pair]) : 128;
                }
            }
        }
    }
    if (style == YUVOV420Style) {
        for (int plane = 0; plane < 2; ++plane)
            for (int i = 0; i < width * height / 4; ++i)
                *cursor++ = color ? (plane ? chromaV[i % 2] : chromaU[i % 2]) : 128;
    }
    return (size_t)(cursor - source);
}

static void checkConversion(YUVStyle style, int width, int height, short bpp,
                            bool flip, size_t rowPadding, size_t alignmentOffset,
                            bool color, bool trailingGuard) {
    const size_t sourceLength = width * height * (style == YUVCPIA422Style ? 2 : 3) /
                                (style == YUVCPIA422Style ? 1 : 2);
    const size_t stride = width * bpp + rowPadding;
    const size_t outputLength = height * stride;
    const size_t prefix = 16 + alignmentOffset;
    const size_t allocationLength = prefix + outputLength + (trailingGuard ? 16 : 0);
    uint8_t *input = malloc(prefix + sourceLength);
    uint8_t *output = malloc(allocationLength);
    uint8_t *expected = malloc(allocationLength);
    assert(input && output && expected);
    memset(input, 0x5a, prefix);
    memset(output, 0xa5, allocationLength);
    memset(expected, 0xa5, allocationLength);
    assert(makeSource(input + prefix, style, width, height, color) == sourceLength);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const int sourceX = (flip ? width - x - 1 : x) % 4;
            uint8_t *pixel = expected + prefix + y * stride + x * bpp;
            if (bpp == 4) *pixel++ = 255;
            for (int channel = 0; channel < 3; ++channel)
                pixel[channel] = color ? colorRGB[y % 2][sourceX][channel] :
                                         luma[y % 2][sourceX];
        }
    }

    yuv2rgb(width, height, style, input + prefix, output + prefix, bpp,
            0, (long)rowPadding, flip);
    if (memcmp(output, expected, allocationLength) != 0) {
        fprintf(stderr, "YUV output/bounds mismatch: style=%d %dx%d bpp=%d flip=%d "
                        "padding=%zu offset=%zu color=%d guard=%d\n",
                style, width, height, bpp, flip, rowPadding, alignmentOffset,
                color, trailingGuard);
        abort();
    }
    for (size_t i = 0; i < prefix; ++i) assert(input[i] == 0x5a);
    free(expected);
    free(output);
    free(input);
}

int main(void) {
    const size_t offsets[] = {0, 1, 3, 7};
    const size_t padding[] = {0, 1, 7};
    for (YUVStyle style = YUVPhilipsStyle; style <= YUVOV420Style; ++style)
        for (int blocks = 1; blocks <= 2; ++blocks)
            for (short bpp = 3; bpp <= 4; ++bpp)
                for (int flip = 0; flip <= 1; ++flip)
                    for (size_t p = 0; p < sizeof(padding) / sizeof(padding[0]); ++p)
                        for (size_t a = 0; a < sizeof(offsets) / sizeof(offsets[0]); ++a)
                            for (int color = 0; color <= 1; ++color)
                                for (int guard = 0; guard <= 1; ++guard)
                                    checkConversion(style, blocks * 4, blocks * 2, bpp,
                                                    flip, padding[p], offsets[a], color, guard);
    puts("YUV converters: RGB24/ARGB bytes, mirrored rows, strides, unaligned buffers, and bounds passed");
    return 0;
}
