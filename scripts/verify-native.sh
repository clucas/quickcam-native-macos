#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/architectures.sh"
quickcam_build_architectures
usage() {
  printf '%s\n' 'Usage: verify-native.sh --build-only | [08b2|08d7] [--snapshot-dir DIRECTORY]' >&2
  exit 2
}
build_only=false
product_seen=false
snapshot_seen=false
argument_index=1
while [[ $argument_index -le $# ]]; do
  argument="${!argument_index}"
  case "$argument" in
    --build-only)
      [[ $# -eq 1 ]] || usage
      build_only=true
      ;;
    08b2|08d7)
      [[ "$product_seen" == false ]] || usage
      product_seen=true
      ;;
    --snapshot-dir)
      [[ "$snapshot_seen" == false ]] || usage
      snapshot_seen=true
      argument_index=$((argument_index + 1))
      [[ $argument_index -le $# ]] || usage
      snapshot_directory="${!argument_index}"
      [[ -n "$snapshot_directory" && "$snapshot_directory" != --* ]] || usage
      ;;
    *) usage ;;
  esac
  argument_index=$((argument_index + 1))
done
verification_app="$project_dir/build/QuickCam Native Verification.app"
verification_binary="$verification_app/Contents/MacOS/QuickCam Native Verification"
mkdir -p "$verification_app/Contents/MacOS"
xcrun clang "${quickcam_arch_flags[@]}" -mmacosx-version-min=13.0 -fno-objc-arc -fblocks -O2 -g \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  "$project_dir/tests/verify_native.m" -framework Foundation -framework AVFoundation \
  -framework CoreMedia -framework CoreVideo -framework CoreImage -framework CoreGraphics \
  -o "$verification_binary"
cat > "$verification_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>QuickCam Native Verification</string>
<key>CFBundleIdentifier</key><string>local.quickcam.NativeVerification</string>
<key>CFBundleName</key><string>QuickCam Native Verification</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSCameraUsageDescription</key><string>Verify the two separately named legacy Logitech webcams. Other cameras are not opened.</string>
</dict></plist>
PLIST
codesign --force --sign - "$verification_app"
codesign --verify --strict "$verification_app"
if [[ "$build_only" == true ]]; then
  printf 'Built without opening a camera: %s\n' "$verification_app"
else
  "$verification_binary" "$@"
fi
