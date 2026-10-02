#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/architectures.sh"
cd "$project_dir"
usage() {
  printf '%s\n' 'Usage: bash scripts/test-driver.sh [--hardware]' \
    'Default: run synthetic driver and RGB conversion tests without opening cameras.' \
    '--hardware: also capture both attached legacy cameras, stop, and restart them.'
}
hardware=0
if [[ $# -gt 1 ]]; then usage >&2; exit 2; fi
case "${1:-}" in
  '') ;;
  --hardware) hardware=1 ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
quickcam_test_architecture
QUICKCAM_ARCHS="$quickcam_test_arch" bash scripts/build-driver.sh
test_dir="build/tests/$quickcam_test_arch"
mkdir -p "$test_dir"
flags=(-arch "$quickcam_test_arch" -mmacosx-version-min=13.0 -std=gnu11 -fblocks -fno-objc-arc -O2 -g
  -DMACAM=1 -Wno-deprecated-declarations
  -Ivendor/macam64/driver_core -Ivendor/macam64/utilities -Ivendor/macam64/cameras
  -Ivendor/macam64/cameras/spca5xx_files -Iextension -Ihost)
frameworks=(-framework Cocoa -framework IOKit -framework Carbon)
for test_name in driver_allowlist driver_hotplug driver_lifecycle driver_registry driver_led driver_rgb24 idle_led capture_async_stop central_startup_retry central_async_removal; do
  xcrun clang "${flags[@]}" "tests/$test_name.m" build/libmacam64.a \
    "${frameworks[@]}" -o "$test_dir/$test_name"
  quickcam_run_test "$test_dir/$test_name"
done
QUICKCAM_TEST_ARCH="$quickcam_test_arch" bash scripts/test-obs-output.sh
if [[ "$hardware" == 1 ]]; then
  QUICKCAM_ARCHS="$quickcam_test_arch" bash scripts/build-capture.sh
  xcrun clang "${flags[@]}" tests/hardware_capture.m \
    build/libQuickCamCapture.a build/libmacam64.a -ObjC "${frameworks[@]}" \
    -o "$test_dir/hardware_capture"
  quickcam_run_test "$test_dir/hardware_capture"
fi
