#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/architectures.sh"
quickcam_build_architectures
build_dir="$project_dir/build"
output_app="$build_dir/QuickCam Native.app"
bundle_id="${QUICKCAM_BUNDLE_ID:-org.example.QuickCamNative}"
extension_id="$bundle_id.CameraExtension"
signing_identity="${QUICKCAM_SIGNING_IDENTITY:-}"
team_id="${QUICKCAM_TEAM_ID:-}"

if [[ ! "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]]; then
  printf '%s\n' 'Invalid bundle identifier.' >&2
  exit 1
fi
if [[ -n "$signing_identity" && -z "$team_id" ]]; then
  printf '%s\n' 'Set QUICKCAM_TEAM_ID with QUICKCAM_SIGNING_IDENTITY.' >&2
  exit 1
fi
if [[ -n "$signing_identity" && -z "${QUICKCAM_HOST_PROFILE:-}" ]]; then
  printf '%s\n' 'Set QUICKCAM_HOST_PROFILE to a Developer ID profile with System Extension capability.' >&2
  exit 1
fi
if [[ ! -f "$build_dir/libmacam64.a" || ! -f "$project_dir/src/QuickCamCapture.m" ]]; then
  printf '%s\n' 'Build the native capture library and provide src/QuickCamCapture.m first.' >&2
  exit 1
fi
quickcam_require_architectures "$build_dir/libmacam64.a"

mkdir -p "$build_dir"
staging_dir="$(mktemp -d "$build_dir/native-stage.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/QuickCam Native.app"
extension_dir="$app_dir/Contents/Library/SystemExtensions/$extension_id.systemextension"
mkdir -p "$app_dir/Contents/MacOS" "$extension_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources" "$extension_dir/Contents/Resources"
for resource_dir in "$app_dir/Contents/Resources" "$extension_dir/Contents/Resources"; do
  cp "$project_dir/host/COPYING.txt" "$project_dir/host/NOTICE.txt" \
    "$project_dir/host/LICENSE-pyvirtualcam-MIT.txt" "$resource_dir/"
  cp "$project_dir/LICENSE" "$project_dir/LICENSE-MIT" "$resource_dir/"
done
source_dir="$project_dir/vendor/macam64"
extension_binaries=()
host_binaries=()
for architecture in "${quickcam_archs[@]}"; do
  architecture_dir="$build_dir/extension/$architecture"
  mkdir -p "$architecture_dir" "$build_dir/swift-cache/$architecture"
  xcrun clang -arch "$architecture" -mmacosx-version-min=13.0 -std=gnu11 -fblocks -fno-objc-arc -O2 -g \
    -DMACAM=1 -Wno-deprecated-declarations -Wno-objc-method-access \
    -I"$project_dir/extension" -I"$source_dir/driver_core" \
    -I"$source_dir/utilities" -I"$source_dir/cameras" -I"$source_dir/app_specific" \
    -c "$project_dir/src/QuickCamCapture.m" -o "$architecture_dir/QuickCamCapture.o"
  xcrun swiftc -swift-version 5 -target "$architecture-apple-macos13.0" -O \
    -module-cache-path "$build_dir/swift-cache/$architecture" \
    -import-objc-header "$project_dir/extension/QuickCamCapture.h" \
    "$project_dir/extension/FrameConversion.swift" \
    "$project_dir/extension/QuickCamProvider.swift" "$project_dir/extension/main.swift" \
    "$architecture_dir/QuickCamCapture.o" "$build_dir/libmacam64.a" \
    -framework CoreMediaIO -framework Cocoa -framework IOKit -framework Carbon \
    -o "$architecture_dir/QuickCamCamera"
  xcrun swiftc -swift-version 5 -target "$architecture-apple-macos13.0" -O \
    -module-cache-path "$build_dir/swift-cache/$architecture" "$project_dir/host/main.swift" \
    -framework AppKit -framework SystemExtensions -o "$architecture_dir/QuickCamNative"
  extension_binaries+=("$architecture_dir/QuickCamCamera")
  host_binaries+=("$architecture_dir/QuickCamNative")
done
xcrun lipo -create "${extension_binaries[@]}" -output "$extension_dir/Contents/MacOS/QuickCamCamera"
xcrun lipo -create "${host_binaries[@]}" -output "$app_dir/Contents/MacOS/QuickCamNative"

/usr/bin/python3 - "$project_dir" "$app_dir" "$extension_dir" "$bundle_id" "$team_id" "$signing_identity" "$staging_dir" <<'PY'
import datetime
import fnmatch
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

project, app, extension = map(pathlib.Path, sys.argv[1:4])
bundle_id, team_id, identity, staging = sys.argv[4:]
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]+', bundle_id):
    raise SystemExit('Invalid bundle identifier.')
if identity and not re.fullmatch(r'[A-Z0-9]{10}', team_id):
    raise SystemExit('A 10-character Apple Team ID is required.')
extension_id = bundle_id + ".CameraExtension"
group = (team_id + "." if team_id else "") + bundle_id
for kind, destination, identifier in [("host", app, bundle_id), ("extension", extension, extension_id)]:
    with (project / kind / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    info["CFBundleIdentifier"] = identifier
    if kind == "extension":
        info["CMIOExtension"]["CMIOExtensionMachServiceName"] = group + ".CameraExtension"
    else:
        info["QuickCamExtensionIdentifier"] = extension_id
        info["QuickCamHasSigningIdentity"] = bool(identity)
    with (destination / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    entitlement_name = "Host.entitlements" if kind == "host" else "Camera.entitlements"
    with (project / kind / entitlement_name).open("rb") as stream:
        entitlements = plistlib.load(stream)
    entitlements["com.apple.security.application-groups"] = [group]
    profile_path = os.environ.get('QUICKCAM_' + kind.upper() + '_PROFILE') if identity else None
    if profile_path:
        profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', profile_path]))
        permissions = profile.get('Entitlements', {})
        expiry = profile.get('ExpirationDate')
        if not expiry or expiry <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
            raise SystemExit(f'{kind} provisioning profile is expired.')
        if team_id not in profile.get('TeamIdentifier', []):
            raise SystemExit(f'{kind} provisioning profile has a different Team ID.')
        permitted_id = permissions.get('com.apple.application-identifier', '')
        if not fnmatch.fnmatchcase(team_id + '.' + identifier, permitted_id):
            raise SystemExit(f'{kind} provisioning profile does not permit this bundle ID.')
        if not profile.get('ProvisionsAllDevices'):
            raise SystemExit(f'{kind} requires a Developer ID provisioning profile.')
        if kind == 'host' and permissions.get('com.apple.developer.system-extension.install') is not True:
            raise SystemExit('Host provisioning profile does not permit System Extension installation.')
        shutil.copyfile(profile_path, destination / 'Contents/embedded.provisionprofile')
        entitlements["com.apple.developer.team-identifier"] = team_id
        entitlements["com.apple.application-identifier"] = team_id + "." + identifier
    with (pathlib.Path(staging) / entitlement_name).open("wb") as stream:
        plistlib.dump(entitlements, stream)
PY

if [[ -n "$signing_identity" ]]; then
  codesign --force --sign "$signing_identity" --options runtime --timestamp \
    --entitlements "$staging_dir/Camera.entitlements" "$extension_dir"
  codesign --force --sign "$signing_identity" --options runtime --timestamp \
    --entitlements "$staging_dir/Host.entitlements" "$app_dir"
  codesign --verify --deep --strict "$app_dir"
  for signed_bundle in "$extension_dir" "$app_dir"; do
    signature="$(codesign -dvv "$signed_bundle" 2>&1)"
    if ! printf '%s\n' "$signature" | /usr/bin/grep -q '^Authority=Developer ID Application:' || \
       ! printf '%s\n' "$signature" | /usr/bin/grep -qx "TeamIdentifier=$team_id"; then
      printf '%s\n' 'Signing requires a Developer ID Application identity for the specified team.' >&2
      exit 1
    fi
  done
  /usr/bin/python3 - "$app_dir" "$extension_dir" "$staging_dir" <<'PY'
import pathlib
import plistlib
import subprocess
import sys

host, extension, staging = map(pathlib.Path, sys.argv[1:])
for kind, bundle in [('host', host), ('extension', extension)]:
    profile_path = bundle / 'Contents/embedded.provisionprofile'
    if not profile_path.exists():
        continue
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(profile_path)]))
    prefix = str(staging / (kind + '-signing-certificate-'))
    subprocess.run(['codesign', '--display', '--extract-certificates=' + prefix, str(bundle)],
                   check=True, capture_output=True)
    certificate = pathlib.Path(prefix + '0').read_bytes()
    if certificate not in profile.get('DeveloperCertificates', []):
        raise SystemExit(f'{kind} provisioning profile does not authorize the selected signing certificate.')
PY
  printf '%s\n' 'Notarization and macOS activation approval are separate steps.'
else
  codesign --force --sign - "$extension_dir"
  codesign --force --sign - "$app_dir"
  codesign --verify --deep --strict "$app_dir"
  printf '%s\n' 'No Apple signing identity: this build cannot activate the system extension.'
fi
if [[ -e "$output_app" ]]; then mv "$output_app" "$staging_dir/previous.app"; fi
mv "$app_dir" "$output_app"
printf 'Built: %s\n' "$output_app"
