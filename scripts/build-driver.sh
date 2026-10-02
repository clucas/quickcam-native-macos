#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/architectures.sh"
quickcam_build_architectures
source_dir="$project_dir/vendor/macam64"
build_dir="$project_dir/build/driver"
mkdir -p "$build_dir"
cd "$source_dir"
flags=(-mmacosx-version-min=13.0 -std=gnu11 -O2 -g -DMACAM=1 -Wno-deprecated-declarations -Wno-objc-method-access -Wno-format -Wno-incompatible-pointer-types)
if [[ "${QUICKCAM_VERBOSE:-0}" == "1" ]]; then flags+=(-DVERBOSE=1); fi
for include_dir in app_specific cameras cameras/spca5xx_files driver_core sensors utilities; do
  flags+=("-I$source_dir/$include_dir")
done
sources=(
  driver_core/MyCameraCentral.m driver_core/MyCameraDriver.m driver_core/MyCameraInfo.m driver_core/MyDummyCameraDriver.m
  cameras/MyPhilipsCameraDriver.m cameras/MyKiaraFamilyDriver.m
  cameras/GenericDriver.m cameras/SPCA5XXDriver.m cameras/ZC030xDriver.m
  cameras/pwc_files/pwc-dec23.c cameras/pwc_files/pwc-kiara.c cameras/pwc_files/pwc-misc.c cameras/pwc_files/pwc-timon.c cameras/pwc_files/pwc-uncompress.c
  cameras/spca5xx_files/gspcadecoder.c
  utilities/AGC.m utilities/BayerConverter.m utilities/FrameCounter.m utilities/Histogram.m utilities/LookUpTable.m
  utilities/MiniGraphicsTools.c utilities/MiscTools.c utilities/RGB888Scaler.m utilities/RGBScaler.m utilities/Resolvers.c utilities/yuv2rgb.c
)
libraries=()
for architecture in "${quickcam_archs[@]}"; do
  architecture_dir="$build_dir/$architecture"
  mkdir -p "$architecture_dir"
  objects=()
  for source in "${sources[@]}"; do
    object="$architecture_dir/${source//\//_}.o"
    xcrun clang -arch "$architecture" "${flags[@]}" -c "$source" -o "$object"
    objects+=("$object")
  done
  library="$architecture_dir/libmacam64.a"
  xcrun libtool -static -o "$library" "${objects[@]}"
  libraries+=("$library")
done
xcrun lipo -create "${libraries[@]}" -output "$project_dir/build/libmacam64.a"
printf '%s\n' "$project_dir/build/libmacam64.a"
