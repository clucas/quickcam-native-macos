#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v rsvg-convert >/dev/null; then
  printf '%s\n' 'Regenerating the icon requires rsvg-convert from librsvg. Normal app builds use the included AppIcon.icns.' >&2
  exit 1
fi
iconset="$project_dir/build/icon/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    suffix=""
    if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
    rsvg-convert --width "$pixels" --height "$pixels" \
      --output "$iconset/icon_${size}x${size}${suffix}.png" "$project_dir/host/AppIcon.svg"
  done
done
iconutil --convert icns --output "$project_dir/host/AppIcon.icns" "$iconset"
printf 'Built: %s\n' "$project_dir/host/AppIcon.icns"
