#!/bin/bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: verify-video.sh OUTPUT.png' \
    '       verify-video.sh --build-only' \
    'Publish a legacy camera through OBS Virtual Camera before capturing.'
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi
if [[ "$1" == '--help' || "$1" == '-h' ]]; then
  usage
  exit 0
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/architectures.sh"
quickcam_build_architectures
verification_app="$project_dir/build/QuickCam Verification.app"
verification_binary="$verification_app/Contents/MacOS/QuickCam Verification"
mkdir -p "$verification_app/Contents/MacOS"

xcrun clang "${quickcam_arch_flags[@]}" -mmacosx-version-min=13.0 -fno-objc-arc -fblocks -O2 -g \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  "$project_dir/tests/verify_virtual.m" \
  -framework Cocoa -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework CoreImage -o "$verification_binary"

cat > "$verification_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>QuickCam Verification</string>
    <key>CFBundleIdentifier</key><string>local.quickcam.Verification</string>
    <key>CFBundleName</key><string>QuickCam Verification</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>NSCameraUsageDescription</key>
    <string>Verify that the custom Logitech drivers provide video through OBS Virtual Camera. The other cameras are not opened.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$verification_app"
codesign --verify --strict "$verification_app"
if [[ "$1" == '--build-only' ]]; then
  printf 'Built without opening a camera: %s\n' "$verification_app"
  exit 0
fi

output_png="$1"
if [[ ! -d "$(dirname "$output_png")" ]]; then
  printf 'Output directory does not exist: %s\n' "$(dirname "$output_png")" >&2
  exit 2
fi
"$verification_binary" "$output_png"
