#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/architectures.sh"
quickcam_test_architecture
build_dir="$project_dir/build/microphone-tests/$quickcam_test_arch"
mkdir -p "$build_dir" "$project_dir/build/swift-cache/$quickcam_test_arch"
xcrun swiftc -swift-version 5 -target "$quickcam_test_arch-apple-macos13.0" \
  -module-cache-path "$project_dir/build/swift-cache/$quickcam_test_arch" \
  "$project_dir/host/QuickCamMicrophones.swift" "$project_dir/tests/microphone_support.swift" \
  -framework CoreAudio -o "$build_dir/microphone-support-test"
quickcam_run_test "$build_dir/microphone-support-test"
