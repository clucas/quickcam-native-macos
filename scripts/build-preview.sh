#!/bin/bash
set -euo pipefail
camera_project="$(cd "$(dirname "$0")/.." && pwd)"
source "$camera_project/scripts/architectures.sh"
quickcam_build_architectures
cd "$camera_project"
quickcam_require_architectures build/libQuickCamCapture.a
quickcam_require_architectures build/libmacam64.a
camera_app="build/Legacy QuickCam.app"
mkdir -p "$camera_app/Contents/MacOS" "$camera_app/Contents/Resources"
xcrun clang "${quickcam_arch_flags[@]}" -mmacosx-version-min=13.0 -fno-objc-arc -fblocks -O2 -g \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -Iextension -Ihost \
  preview/main.m host/QCObsOutput.m build/libQuickCamCapture.a build/libmacam64.a \
  -ObjC -framework Cocoa -framework IOKit -framework Carbon -framework CoreMediaIO \
  -framework CoreMedia -framework CoreVideo -o "$camera_app/Contents/MacOS/Legacy QuickCam"
cat > "$camera_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.quickcam.LegacyQuickCam</string>
<key>CFBundleName</key><string>Legacy QuickCam</string>
<key>CFBundleDisplayName</key><string>Legacy QuickCam</string>
<key>CFBundleExecutable</key><string>Legacy QuickCam</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>Preview your legacy Logitech webcams and send the selected camera to your video apps.</string>
</dict></plist>
PLIST
cp vendor/macam64/COPYING.txt "$camera_app/Contents/Resources/LICENSE-macam.txt"
cp host/COPYING.txt host/NOTICE.txt host/LICENSE-pyvirtualcam-MIT.txt "$camera_app/Contents/Resources/"
cp LICENSE LICENSE-MIT "$camera_app/Contents/Resources/"
printf '%s\n' 'Source and build instructions: https://github.com/clucas/quickcam-native-macos' > "$camera_app/Contents/Resources/SOURCE.txt"
codesign --force --sign - "$camera_app"
codesign --verify --strict "$camera_app"
