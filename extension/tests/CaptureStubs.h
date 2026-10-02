#include "../QuickCamCapture.h"

void test_capture_reset(void);
void test_capture_devices(const qc_device_info *devices, size_t count);
void test_capture_initialization_failures(unsigned count);
void test_capture_discovery_error(int enabled);
void test_capture_status(uint32_t location, int status);
void test_capture_complete_shutdown(uint32_t location);
void test_capture_deliver_invalid_frame(uint32_t location);
void test_capture_start_error(uint32_t location, int enabled);
int test_capture_attempts(uint32_t location);
int test_capture_starts(uint32_t location);
int test_capture_stop_requests(uint32_t location);
int test_capture_finishes(uint32_t location);
int test_capture_outstanding(void);
void test_capture_prepare_error(uint32_t location, int enabled);
int test_capture_preparations(uint32_t location);
uint64_t test_capture_prepared_registry(uint32_t location);
