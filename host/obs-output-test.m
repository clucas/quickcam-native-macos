#include <assert.h>
#include <string.h>
#include "QCObsOutput.m"

int main(void) {
    @autoreleasepool {
        const uint8_t source[] = {255,255,255, 0,0,0, 0xA5,0xA5,0xA5,
                                  255,0,0, 255,0,0, 0xA5,0xA5,0xA5};
        uint8_t output[16];
        memset(output, 0xCC, sizeof(output));
        rgbToUYVY(source, 9, output, 8, 2, 2);
        const uint8_t expected[] = {128,235,128,16, 0xCC,0xCC,0xCC,0xCC,
                                     90,82,240,82, 0xCC,0xCC,0xCC,0xCC};
        assert(memcmp(output, expected, sizeof(expected)) == 0);
        assert(qc_obs_open(0, 240, 5) == NULL);
        assert(qc_obs_open(321, 240, 5) == NULL);
        assert(qc_obs_send(NULL, source, 9, 0) == -1);
        atomic_store(&outputActive, true);
        assert(qc_obs_open(320, 240, 5) == NULL);
        assert(strstr(qc_obs_last_error(), "already active") != NULL);
        atomic_store(&outputActive, false);
        qc_obs_close(NULL);
        puts("OBS RGB24/UYVY stride, colors, and invalid-argument tests passed.");
    }
}
