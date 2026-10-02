#!/bin/bash
set -euo pipefail
camera_project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$camera_project"
mkdir -p build
capture_flags=(-arch arm64 -mmacosx-version-min=13.0 -fblocks -fno-objc-arc -O2 -g
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
  -Iextension -Ivendor/macam64/driver_core -Ivendor/macam64/utilities -Ivendor/macam64/cameras)
clang "${capture_flags[@]}" -c src/QuickCamCapture.m -o build/QuickCamCapture.o
libtool -static -o build/libQuickCamCapture.a build/QuickCamCapture.o
clang "${capture_flags[@]}" src/capture_cli.m build/libQuickCamCapture.a build/libmacam64.a \
  -ObjC -framework Cocoa -framework IOKit -framework Carbon -o build/quickcam-capture
