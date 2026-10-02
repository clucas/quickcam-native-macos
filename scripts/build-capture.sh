#!/bin/bash
set -euo pipefail
camera_project="$(cd "$(dirname "$0")/.." && pwd)"
source "$camera_project/scripts/architectures.sh"
quickcam_build_architectures
cd "$camera_project"
quickcam_require_architectures build/libmacam64.a
mkdir -p build
capture_flags=(-mmacosx-version-min=13.0 -fblocks -fno-objc-arc -O2 -g
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
  -Iextension -Ivendor/macam64/driver_core -Ivendor/macam64/utilities -Ivendor/macam64/cameras)
libraries=()
for architecture in "${quickcam_archs[@]}"; do
  architecture_dir="build/capture/$architecture"
  mkdir -p "$architecture_dir"
  xcrun clang -arch "$architecture" "${capture_flags[@]}" -c src/QuickCamCapture.m -o "$architecture_dir/QuickCamCapture.o"
  library="$architecture_dir/libQuickCamCapture.a"
  xcrun libtool -static -o "$library" "$architecture_dir/QuickCamCapture.o"
  libraries+=("$library")
done
xcrun lipo -create "${libraries[@]}" -output build/libQuickCamCapture.a
xcrun clang "${quickcam_arch_flags[@]}" "${capture_flags[@]}" src/capture_cli.m build/libQuickCamCapture.a build/libmacam64.a \
  -ObjC -framework Cocoa -framework IOKit -framework Carbon -o build/quickcam-capture
