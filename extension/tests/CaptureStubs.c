#include "CaptureStubs.h"
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint32_t location;
    int attempts, starts, requests, finishes, preparations;
    bool start_error, prepare_error;
    uint64_t prepared_registry;
    qc_session *active;
} fixture;

struct qc_session {
    fixture *owner;
    int status;
    bool stop_requested, shutdown_complete;
    qc_frame_callback callback;
    void *context;
};

static fixture fixtures[8];
static qc_device_info devices[8];
static size_t device_count;
static unsigned initialization_failures;
static bool discovery_error;
static const char *last_error = "";

static fixture *camera(uint32_t location) {
    assert(location != 0);
    for (size_t i = 0; i < 8; i++) {
        if (!fixtures[i].location) fixtures[i].location = location;
        if (fixtures[i].location == location) return &fixtures[i];
    }
    abort();
}

int qc_initialize(void) {
    last_error = "";
    if (initialization_failures) {
        initialization_failures--;
        last_error = "Test initialization failure";
        return -1;
    }
    return 0;
}

size_t qc_enumerate(qc_device_info *output, size_t capacity) {
    last_error = "";
    if (discovery_error) {
        last_error = "Test discovery failure";
        return 0;
    }
    size_t copied = capacity < device_count ? capacity : device_count;
    if (copied) memcpy(output, devices, copied * sizeof(*output));
    return device_count;
}

qc_session *qc_start(uint32_t location, uint32_t width, uint32_t height,
                     uint32_t fps, qc_frame_callback callback, void *context) {
    assert(width == 640 && height == 480 && fps == 5);
    assert(callback && context);
    fixture *owner = camera(location);
    assert(!owner->active);
    owner->attempts++;
    if (owner->start_error) {
        last_error = "Test capture open failure";
        return NULL;
    }
    last_error = "";
    owner->starts++;
    qc_session *session = calloc(1, sizeof(*session));
    assert(session);
    session->owner = owner;
    session->status = 1;
    session->callback = callback;
    session->context = context;
    owner->active = session;
    return session;
}

int qc_prepare_idle_device(const qc_device_info *device) {
    assert(device && device->vendor_id == 0x046d && device->product_id == 0x08b2);
    fixture *owner = camera(device->location_id);
    assert(!owner->active);
    owner->preparations++;
    owner->prepared_registry = device->registry_id;
    last_error = owner->prepare_error ? "Test idle device busy" : "";
    return owner->prepare_error ? -1 : 0;
}

int qc_status(qc_session *session) { return session->status; }

void qc_request_stop(qc_session *session) {
    if (session->stop_requested) return;
    session->stop_requested = true;
    session->status = 0;
    session->owner->requests++;
}

int qc_finish_stop(qc_session *session) {
    if (!session->stop_requested || !session->shutdown_complete) return 0;
    session->owner->finishes++;
    session->owner->active = NULL;
    free(session);
    return 1;
}

void qc_stop(qc_session *session) {
    (void)session;
    fputs("The extension must not use blocking qc_stop.\n", stderr);
    abort();
}

const char *qc_last_error(void) { return last_error; }
int test_capture_attempts(uint32_t location) { return camera(location)->attempts; }
int test_capture_starts(uint32_t location) { return camera(location)->starts; }
int test_capture_stop_requests(uint32_t location) { return camera(location)->requests; }
int test_capture_finishes(uint32_t location) { return camera(location)->finishes; }
int test_capture_preparations(uint32_t location) { return camera(location)->preparations; }
uint64_t test_capture_prepared_registry(uint32_t location) { return camera(location)->prepared_registry; }
void test_capture_prepare_error(uint32_t location, int enabled) { camera(location)->prepare_error = enabled != 0; }

int test_capture_outstanding(void) {
    int count = 0;
    for (size_t i = 0; i < 8; i++) if (fixtures[i].active) count++;
    return count;
}

void test_capture_reset(void) {
    assert(test_capture_outstanding() == 0);
    memset(fixtures, 0, sizeof(fixtures));
    device_count = 0;
    initialization_failures = 0;
    discovery_error = false;
    last_error = "";
}

void test_capture_devices(const qc_device_info *input, size_t count) {
    assert(count <= 8);
    if (count) memcpy(devices, input, count * sizeof(*input));
    device_count = count;
}

void test_capture_initialization_failures(unsigned count) { initialization_failures = count; }
void test_capture_discovery_error(int enabled) { discovery_error = enabled != 0; }
void test_capture_start_error(uint32_t location, int enabled) { camera(location)->start_error = enabled != 0; }
void test_capture_status(uint32_t location, int status) {
    assert(camera(location)->active);
    camera(location)->active->status = status;
}
void test_capture_complete_shutdown(uint32_t location) {
    assert(camera(location)->active);
    camera(location)->active->shutdown_complete = true;
}

void test_capture_deliver_invalid_frame(uint32_t location) {
    qc_session *session = camera(location)->active;
    assert(session);
    const uint8_t pixel[3] = {0, 0, 0};
    session->callback(session->context, pixel, 1, 1, sizeof(pixel), 0);
}
