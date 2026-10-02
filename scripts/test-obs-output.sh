#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/architectures.sh"
quickcam_test_architecture
test_dir="$project_dir/build/tests/$quickcam_test_arch"
mkdir -p "$test_dir"
xcrun clang -arch "$quickcam_test_arch" -mmacosx-version-min=13.0 -std=gnu11 -O2 \
  -Wall -Wextra -Wno-unused-parameter \
  "$project_dir/host/obs-output-test.m" \
  -framework Foundation -framework CoreMedia -framework CoreMediaIO \
  -framework CoreVideo -o "$test_dir/obs-output-test"
quickcam_run_test "$test_dir/obs-output-test"
