#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
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
bash scripts/build-driver.sh
mkdir -p build/tests
flags=(-arch arm64 -mmacosx-version-min=13.0 -std=gnu11 -fblocks -fno-objc-arc -O2 -g
  -DMACAM=1 -Wno-deprecated-declarations
  -Ivendor/macam64/driver_core -Ivendor/macam64/utilities -Ivendor/macam64/cameras
  -Ivendor/macam64/cameras/spca5xx_files -Iextension -Ihost)
frameworks=(-framework Cocoa -framework IOKit -framework Carbon)
for test_name in driver_allowlist driver_hotplug driver_lifecycle driver_registry driver_led idle_led capture_async_stop central_startup_retry central_async_removal; do
  xcrun clang "${flags[@]}" "tests/$test_name.m" build/libmacam64.a \
    "${frameworks[@]}" -o "build/tests/$test_name"
  "build/tests/$test_name"
done
bash scripts/test-obs-output.sh
if [[ "$hardware" == 1 ]]; then
  bash scripts/build-capture.sh
  xcrun clang "${flags[@]}" tests/hardware_capture.m \
    build/libQuickCamCapture.a build/libmacam64.a -ObjC "${frameworks[@]}" \
    -o build/tests/hardware_capture
  build/tests/hardware_capture
fi
