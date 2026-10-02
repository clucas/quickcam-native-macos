#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_dir/build"
xcrun clang -arch arm64 -mmacosx-version-min=13.0 -std=gnu11 -O2 \
  -Wall -Wextra -Wno-unused-parameter \
  "$project_dir/host/obs-output-test.m" \
  -framework Foundation -framework CoreMedia -framework CoreMediaIO \
  -framework CoreVideo -o "$project_dir/build/obs-output-test"
"$project_dir/build/obs-output-test"
