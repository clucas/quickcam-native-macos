# QuickCam Native for macOS

QuickCam Native 0.2.2 makes two older Logitech USB webcams available as separate cameras to video applications, including Zoom and Google Meet. Its CoreMediaIO camera extension captures each webcam only while an application requests it. After activation, macOS manages the extension; the QuickCam host app does not need to remain open.

This repository contains source code and build instructions. It does not include signed apps, certificates, provisioning profiles, or developer-account configuration. To install the native extension, build and sign it with your own Apple Developer Program account.

| USB vendor:product | Camera | Capture driver |
| --- | --- | --- |
| `046d:08b2` | Logitech QuickCam Pro 4000 | Philips/PWC, `MyKiaraFamilyDriver` |
| `046d:08d7` | Logitech QuickCam Communicate STX | ZC030x/GSPCA, `ZC030xDriverMic` |

The USB allowlist contains exactly these two IDs. Other cameras, including the Logitech C270, are not opened by this driver. Both supported cameras provide **640 × 480 video at 5 frames per second**. Microphone audio is not captured; select an audio input separately in your video app.

For the Pro 4000, the activity light follows capture. On each USB connection, the extension also briefly claims the idle video interface to turn the light off without capturing frames. A brief power-on flash can occur before macOS detects the camera. The idle operation skips cameras whose USB interface is already in use.

## Requirements

- An Apple silicon Mac. The build targets macOS 13 or later; hardware testing used an M4 Pro running macOS Tahoe.
- Xcode or Apple's Command Line Tools, selected through `xcode-select`, with a macOS SDK, Swift, Clang, `libtool`, and `codesign`.
- For native extension installation: a Developer ID Application signing certificate, a matching host provisioning profile with **System Extension** capability, and access to Apple's notarization service.

The build uses the included source and Apple's frameworks. It needs no downloaded code dependencies. Native camera support does not require OBS.

## Build and install the native extension

Clone [this repository](https://github.com/clucas/quickcam-native-macos), then run from its root:

```sh
bash scripts/build-driver.sh
bash scripts/build-extension.sh
```

Without signing settings, the result is an inspection build at `build/QuickCam Native.app`. Its installation button is disabled. An ad hoc signature does not satisfy system-extension activation requirements.

For an installable build, register your own host App ID with System Extension capability and create its Developer ID provisioning profile. Keep signing material outside this repository. Replace the placeholders below with your own values:

```sh
export QUICKCAM_BUNDLE_ID='com.yourorganization.QuickCamNative'
export QUICKCAM_TEAM_ID='YOUR_TEAM_ID'
export QUICKCAM_SIGNING_IDENTITY='Developer ID Application: Your Name (YOUR_TEAM_ID)'
export QUICKCAM_HOST_PROFILE='/path/to/your/host.provisionprofile'
bash scripts/build-extension.sh
```

The unsigned default host identifier is `org.example.QuickCamNative`. Signed builds must set `QUICKCAM_BUNDLE_ID` to their own registered identifier. The extension identifier appends `.CameraExtension`. The extension uses sandbox, USB, and team-prefixed app-group entitlements. It does not normally need a separate provisioning profile; `QUICKCAM_EXTENSION_PROFILE` supports one when needed.

Notarize and staple `build/QuickCam Native.app` using your developer account, then copy it to `/Applications`. Open **QuickCam Native**, click **Install Camera Support**, and complete macOS's camera-extension approval. See Apple's [system-extension documentation](https://developer.apple.com/documentation/systemextensions) and [notarization instructions](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Reopen your video app to refresh its camera list. Each connected supported webcam appears under its own name. Both can be used at the same time. **Remove Camera Support** in the host app requests removal of this extension only.

The native extension runs in user space. It does not install a kernel driver, replace Apple's camera drivers, or require disabling SIP. Quit the optional Legacy QuickCam preview app before using native camera entries: both use the same USB interfaces.

## Tests

Run synthetic tests without opening cameras:

```sh
bash scripts/test-driver.sh
bash scripts/test-extension.sh
```

These cover the USB allowlist, hotplug registration, capture lifecycle, concurrent shutdown and registry access, reconnect recovery, activity-light control, exclusive USB ownership, and pixel conversion.

After activating the extension, verify both native camera entries:

```sh
bash scripts/verify-native.sh
```

Allow camera access for **QuickCam Native Verification** if macOS prompts. The verifier opens only the native QuickCam device IDs and checks at least 20 frames from each at 640 × 480 with increasing timestamps. It saves no images by default. Use `--build-only` to compile without opening cameras, `08b2` or `08d7` to test one model, or `--snapshot-dir "$PWD/build/native-snapshots"` to save one PNG per camera.

To test direct USB capture, stop all applications using the native cameras and close the preview app, then run:

```sh
bash scripts/test-driver.sh --hardware
```

This captures both cameras, checks frame timestamps, and tests stop and restart. It writes sample PPM images under `build/`. For a single-camera diagnostic, build the capture tool and run:

```sh
bash scripts/build-capture.sh
build/quickcam-capture 08b2 build/pro4000.ppm 5 640 480
build/quickcam-capture 08d7 build/stx.ppm 5 640 480
```

The arguments are `PRODUCT_ID OUTPUT_PPM FPS WIDTH HEIGHT`. Running the tool without arguments lists supported connected cameras. To rebuild with detailed driver diagnostics, run `QUICKCAM_VERBOSE=1 bash scripts/build-driver.sh`, then rebuild the extension or preview app.

## Optional preview and OBS output

The separate Legacy QuickCam app provides local previews and can send one selected feed to the official OBS Virtual Camera extension:

```sh
bash scripts/build-driver.sh
bash scripts/build-capture.sh
bash scripts/build-preview.sh
open "build/Legacy QuickCam.app"
```

This preview build has an ad hoc signature. Local previews need no OBS installation. To share its selected feed, install official Apple silicon [OBS Studio](https://obsproject.com/download) version 30 or later and activate its virtual camera extension. In Legacy QuickCam, select a camera and click **Send to video apps**. Choose **OBS Virtual Camera** in your video app and keep Legacy QuickCam running. OBS itself may remain closed.

Both previews can run together, but OBS Virtual Camera carries one selected feed. Stop sharing before using OBS to produce that feed. After reconnecting a camera, start its preview again; reopen Legacy QuickCam if needed. Do not use the preview and native extension for the same camera at the same time.

To check the shared OBS feed, start sharing and run `bash scripts/verify-video.sh "$PWD/build/shared-camera.png"`. This receives 20 frames and saves a PNG. Use `--build-only` to compile the verifier without opening a camera.

## Source layout

- `vendor/macam64/`: camera protocols, decoders, and driver support, ported to ARM64.
- `src/QuickCamCapture.m` and `extension/QuickCamCapture.h`: C capture API over the IOKit USB drivers.
- `extension/`: CoreMediaIO devices, capture demand, reconnect handling, and frame delivery.
- `host/main.swift`: native extension installation and removal.
- `preview/main.m` and `host/QCObsOutput.m`: optional previews and OBS output adapter.
- `scripts/` and `tests/`: builds, synthetic tests, and hardware verification.

The driver preserves the active USB configuration so opening video does not reset the camera's audio interface.

## License and provenance

This repository uses separate license scopes:

- New application, capture bridge, and build/test code: **MIT**, as described in [LICENSE-MIT](LICENSE-MIT).
- Vendored macam64 camera drivers and decoders: **GPL-2.0-or-later**, with original notices preserved.
- The combined application, which links those drivers: **GPL-2.0-or-later**.

See [the license overview](LICENSE), [the GPL text](vendor/macam64/COPYING.txt), and [third-party notices](host/NOTICE.txt).

The vendored driver source is [smokris/macam64](https://github.com/smokris/macam64), based on commit [`8caa6f99f142c9e3741083546a49e63ec508043f`](https://github.com/smokris/macam64/commit/8caa6f99f142c9e3741083546a49e63ec508043f). It derives from the macam project and incorporates Philips/PWC and GSPCA camera protocols and decoders. This port builds the required classes for ARM64, restores the STX driver, restricts device matching, preserves active USB configurations, and synchronizes capture shutdown and registry access. Original copyright and license notices remain in the source tree.

The OBS output adapter adapts discovery and queue handling from the MIT-licensed [`virtual_output.hpp` in pyvirtualcam v0.15.0](https://github.com/letmaik/pyvirtualcam/blob/v0.15.0/pyvirtualcam/native_macos_obs_cmioextension/virtual_output.hpp), by Sebastian Beckmann and Jannik Vogel. Its file-specific [MIT license](host/LICENSE-pyvirtualcam-MIT.txt) is included. No pyvirtualcam Python binding or libyuv implementation is required.

OBS Studio and its signed camera extension are separate dependencies distributed by the OBS Project. They are not included or modified here. QuickCam Native is an independent project, not an official Logitech product. The included licenses contain the warranty terms.
