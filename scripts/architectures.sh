#!/bin/bash

quickcam_build_architectures() {
  local requested_archs="${QUICKCAM_ARCHS-arm64 x86_64}"
  if [[ "$requested_archs" == *$'\n'* ]]; then
    printf '%s\n' 'QUICKCAM_ARCHS must be a space-separated list of arm64 and/or x86_64.' >&2
    return 1
  fi
  IFS=$' \t' read -r -a quickcam_archs <<< "$requested_archs"
  if [[ ${#quickcam_archs[@]} -eq 0 ]]; then
    printf '%s\n' 'QUICKCAM_ARCHS must contain arm64 and/or x86_64.' >&2
    return 1
  fi
  quickcam_arch_flags=()
  local architecture seen_archs=' '
  for architecture in "${quickcam_archs[@]}"; do
    case "$architecture" in
      arm64|x86_64) ;;
      *) printf 'Unsupported architecture: %s. Use arm64 and/or x86_64.\n' "$architecture" >&2; return 1 ;;
    esac
    if [[ "$seen_archs" == *" $architecture "* ]]; then
      printf 'Duplicate architecture in QUICKCAM_ARCHS: %s\n' "$architecture" >&2
      return 1
    fi
    seen_archs+="$architecture "
    quickcam_arch_flags+=(-arch "$architecture")
  done
}

quickcam_require_architectures() {
  local library="$1" library_archs architecture
  if [[ ! -f "$library" ]]; then
    printf 'Missing library: %s. Build its driver or capture library first.\n' "$library" >&2
    return 1
  fi
  if ! library_archs="$(xcrun lipo -archs "$library")"; then
    return 1
  fi
  for architecture in "${quickcam_archs[@]}"; do
    if [[ " $library_archs " == *" $architecture "* ]]; then continue; fi
    printf 'Rebuild %s with QUICKCAM_ARCHS="%s".\n' "$library" "${quickcam_archs[*]}" >&2
    return 1
  done
}

quickcam_test_architecture() {
  local native_arch
  native_arch="$(uname -m)"
  if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
    native_arch=arm64
  fi
  quickcam_test_arch="${QUICKCAM_TEST_ARCH-$native_arch}"
  case "$quickcam_test_arch" in
    arm64|x86_64) ;;
    *) printf 'Unsupported QUICKCAM_TEST_ARCH: %s. Use arm64 or x86_64.\n' "$quickcam_test_arch" >&2; return 1 ;;
  esac
  if ! /usr/bin/arch "-$quickcam_test_arch" /usr/bin/true 2>/dev/null; then
    printf 'Cannot run %s tests on this Mac. x86_64 tests on Apple silicon require Rosetta.\n' "$quickcam_test_arch" >&2
    return 1
  fi
  printf 'Running tests for %s.\n' "$quickcam_test_arch"
}

quickcam_run_test() {
  /usr/bin/arch "-$quickcam_test_arch" "$@"
}
