#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_ROOT
readonly PROCESS_GUARD="$REPOSITORY_ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard verify-protocol-xcframework 600 "$0" "$@"

readonly SOURCE_HEADERS="$REPOSITORY_ROOT/Rust/DeviceHubFFI/include"
readonly SMOKE_SOURCE="$REPOSITORY_ROOT/Rust/DeviceHubFFI/tests/ffi_smoke.c"
readonly XCFRAMEWORK="${1:-$REPOSITORY_ROOT/Rust/Artifacts/DeviceHubFFI.xcframework}"
readonly DEVICE_SLICE="$XCFRAMEWORK/ios-arm64"
readonly SIMULATOR_SLICE="$XCFRAMEWORK/ios-arm64-simulator"
readonly LIBRARY_NAME="libdevice_hub_ffi.a"
readonly EXPECTED_MINIMUM="27.0"

if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "error: XCFramework does not exist: $XCFRAMEWORK" >&2
  exit 1
fi
if ! /usr/bin/plutil -lint "$XCFRAMEWORK/Info.plist" >/dev/null; then
  echo "error: invalid XCFramework Info.plist" >&2
  exit 1
fi

for slice in "$DEVICE_SLICE" "$SIMULATOR_SLICE"; do
  if [[ ! -s "$slice/$LIBRARY_NAME" ]]; then
    echo "error: missing static library: $slice/$LIBRARY_NAME" >&2
    exit 1
  fi
  for header in device_hub_ffi.h module.modulemap; do
    if ! cmp -s "$SOURCE_HEADERS/$header" "$slice/Headers/$header"; then
      echo "error: packaged $header does not match the reviewed source" >&2
      exit 1
    fi
  done
done

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

verify_slice() {
  local sdk="$1"
  local minimum_flag="$2"
  local expected_platform="$3"
  local library="$4"
  local executable="$temporary_directory/smoke-$sdk"

  /usr/bin/xcrun --sdk "$sdk" clang \
    -arch arm64 \
    "$minimum_flag$EXPECTED_MINIMUM" \
    -Wall \
    -Wextra \
    -Werror \
    -I "$SOURCE_HEADERS" \
    "$SMOKE_SOURCE" \
    "$library" \
    -o "$executable"

  if ! file "$executable" | rg -q 'Mach-O 64-bit executable arm64'; then
    echo "error: $sdk smoke executable is not arm64 Mach-O" >&2
    exit 1
  fi

  local build_commands
  local platform
  local minimum
  build_commands="$(/usr/bin/otool -l "$executable")"
  platform="$(awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { found = 1; next }
    found && $1 == "platform" { print $2; exit }
  ' <<<"$build_commands")"
  minimum="$(awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { found = 1; next }
    found && $1 == "minos" { print $2; exit }
  ' <<<"$build_commands")"

  if [[ "$platform" != "$expected_platform" || "$minimum" != "$EXPECTED_MINIMUM" ]]; then
    echo "error: $sdk slice has platform=$platform minos=$minimum" >&2
    exit 1
  fi
}

verify_slice \
  iphoneos \
  -miphoneos-version-min= \
  2 \
  "$DEVICE_SLICE/$LIBRARY_NAME"
verify_slice \
  iphonesimulator \
  -mios-simulator-version-min= \
  7 \
  "$SIMULATOR_SLICE/$LIBRARY_NAME"

/usr/bin/xcrun --sdk iphonesimulator clang \
  -arch arm64 \
  -mios-simulator-version-min="$EXPECTED_MINIMUM" \
  -Wall \
  -Wextra \
  -Werror \
  -fsyntax-only \
  -I "$SOURCE_HEADERS" \
  "$SMOKE_SOURCE"

echo "Verified Device Hub XCFramework: arm64 iOS 27 + arm64 Simulator 27."
