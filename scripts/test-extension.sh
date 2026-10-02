#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/architectures.sh"
quickcam_test_architecture
build_dir="$project_dir/build/extension-tests/$quickcam_test_arch"
mkdir -p "$build_dir" "$project_dir/build/swift-cache/$quickcam_test_arch"
xcrun clang -arch "$quickcam_test_arch" -mmacosx-version-min=13.0 -std=gnu11 -Wall -Wextra \
  -c "$project_dir/extension/tests/CaptureStubs.c" -o "$build_dir/CaptureStubs.o"
swift_flags=(-swift-version 5 -target "$quickcam_test_arch-apple-macos13.0"
  -module-cache-path "$project_dir/build/swift-cache/$quickcam_test_arch")
xcrun swiftc "${swift_flags[@]}" \
  -import-objc-header "$project_dir/extension/tests/CaptureStubs.h" \
  "$project_dir/extension/FrameConversion.swift" \
  "$project_dir/extension/QuickCamProvider.swift" \
  "$project_dir/extension/tests/CaptureLifecycleTests.swift" \
  "$build_dir/CaptureStubs.o" -framework Cocoa -framework CoreMediaIO \
  -o "$build_dir/capture-lifecycle-test"
quickcam_run_test "$build_dir/capture-lifecycle-test"
xcrun swiftc "${swift_flags[@]}" \
  "$project_dir/extension/FrameConversion.swift" \
  "$project_dir/extension/FrameConversionTests.swift" -o "$build_dir/frame-conversion-test"
quickcam_run_test "$build_dir/frame-conversion-test"
