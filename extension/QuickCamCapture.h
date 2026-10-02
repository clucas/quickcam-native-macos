#ifndef QUICKCAM_CAPTURE_H
#define QUICKCAM_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint16_t vendor_id;
    uint16_t product_id;
    uint32_t location_id;
    uint64_t registry_id;
} qc_device_info;

typedef struct qc_session qc_session;

/* RGB24 bytes remain valid until the callback returns. host_ns uses the host clock. */
typedef void (*qc_frame_callback)(void *context, const uint8_t *rgb24,
                                  uint32_t width, uint32_t height,
                                  size_t bytes_per_row, uint64_t host_ns);

/* Call initialization, enumeration, start, and stop operations on the main thread. */
int qc_initialize(void);
size_t qc_enumerate(qc_device_info *devices, size_t capacity);
/* Clears an idle Pro 4000 light without capture. Returns 0 on success; retry on error. */
int qc_prepare_idle_device(const qc_device_info *info);
qc_session *qc_start(uint32_t location_id, uint32_t width, uint32_t height,
                     uint32_t frames_per_second, qc_frame_callback callback,
                     void *context);
/* Returns 1 while running, 0 after stopping, or a negative CameraError. */
/* The caller owns the session until qc_stop or successful qc_finish_stop. */
int qc_status(qc_session *session);
/* Initiates shutdown without waiting. Repeated requests on a live handle are safe. */
void qc_request_stop(qc_session *session);
/* Returns 0 while pending. Returns 1 and consumes the handle once callbacks stop. */
/* Keep the callback context alive until 1; the consumed handle is then invalid. */
int qc_finish_stop(qc_session *session);
/* Blocking wrapper that consumes the handle after capture and callbacks stop. */
void qc_stop(qc_session *session);
const char *qc_last_error(void);

#ifdef __cplusplus
}
#endif
#endif
