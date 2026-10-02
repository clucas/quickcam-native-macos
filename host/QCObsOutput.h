#ifndef QUICKCAM_OBS_OUTPUT_H
#define QUICKCAM_OBS_OUTPUT_H
#include <stddef.h>
#include <stdint.h>

typedef struct qc_obs_output qc_obs_output;

/* OBS 30+ must have installed and activated its signed camera extension. */
qc_obs_output *qc_obs_open(uint32_t width, uint32_t height, uint32_t fps);
/* Returns 0 on delivery, 1 when a full queue drops the frame, and -1 on error. */
int qc_obs_send(qc_obs_output *output, const uint8_t *rgb24, size_t stride, uint64_t host_ns);
/* Stop capture callbacks before closing their output. */
void qc_obs_close(qc_obs_output *output);
const char *qc_obs_last_error(void);

#endif
