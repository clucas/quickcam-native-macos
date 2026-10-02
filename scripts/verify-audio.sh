#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/architectures.sh"
quickcam_build_architectures
usage() {
  printf '%s\n' 'Usage: verify-audio.sh --build-only | --self-test | [--physical] [08b2|08d7]' >&2
  exit 2
}
build_only=false
physical_seen=false
product_seen=false
for argument in "$@"; do
  case "$argument" in
    --build-only) [[ $# -eq 1 ]] || usage; build_only=true ;;
    --self-test) [[ $# -eq 1 ]] || usage ;;
    --physical) [[ "$physical_seen" == false ]] || usage; physical_seen=true ;;
    08b2|08d7) [[ "$product_seen" == false ]] || usage; product_seen=true ;;
    *) usage ;;
  esac
done
verification_app="$project_dir/build/QuickCam Audio Verification.app"
verification_binary="$verification_app/Contents/MacOS/QuickCam Audio Verification"
mkdir -p "$verification_app/Contents/MacOS"
binaries=()
for architecture in "${quickcam_archs[@]}"; do
  architecture_dir="$project_dir/build/verify-audio/$architecture"
  mkdir -p "$architecture_dir" "$project_dir/build/swift-cache/$architecture"
  xcrun swiftc -swift-version 5 -target "$architecture-apple-macos13.0" -O \
    -module-cache-path "$project_dir/build/swift-cache/$architecture" \
    "$project_dir/tools/verify-audio/main.swift" \
    -framework AppKit -framework AVFoundation -framework CoreAudio -framework CryptoKit \
    -o "$architecture_dir/QuickCam Audio Verification"
  binaries+=("$architecture_dir/QuickCam Audio Verification")
done
xcrun lipo -create "${binaries[@]}" -output "$verification_binary"
cat > "$verification_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>QuickCam Audio Verification</string>
<key>CFBundleIdentifier</key><string>local.quickcam.AudioVerification</string>
<key>CFBundleName</key><string>QuickCam Audio Verification</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSMicrophoneUsageDescription</key><string>Test the selected QuickCam microphones for two seconds each. Only sample counts and sound levels are reported; no audio is saved.</string>
</dict></plist>
PLIST
entitlements="$project_dir/build/verify-audio/Audio.entitlements"
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
PLIST
signing_identity="${QUICKCAM_SIGNING_IDENTITY:--}"
codesign --force --sign "$signing_identity" --options runtime --entitlements "$entitlements" "$verification_app"
codesign --verify --strict "$verification_app"
if [[ "$build_only" == true ]]; then
  printf 'Built without opening a microphone: %s\n' "$verification_app"
else
  "$verification_binary" "$@"
fi
