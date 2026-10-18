#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_ROOT
readonly PROCESS_GUARD="$REPOSITORY_ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
# shellcheck source=BuildSupport/check_xcode_toolchain.sh
source "$REPOSITORY_ROOT/BuildSupport/check_xcode_toolchain.sh"
devicehub_require_guard build-protocol-xcframework 1800 "$0" "$@"

readonly MANIFEST="$REPOSITORY_ROOT/Rust/Cargo.toml"
readonly HEADER_DIRECTORY="$REPOSITORY_ROOT/Rust/DeviceHubFFI/include"
readonly ARTIFACT_ROOT="$REPOSITORY_ROOT/Rust/Artifacts"
readonly OUTPUT="$ARTIFACT_ROOT/DeviceHubFFI.xcframework"
readonly DEPLOYMENT_TARGET="27.0"
readonly BUILD_ROOT="$REPOSITORY_ROOT/Rust/.build/cargo-ios-$DEPLOYMENT_TARGET"
readonly DEVICE_TARGET="aarch64-apple-ios"
readonly SIMULATOR_TARGET="aarch64-apple-ios-sim"
readonly RUST_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.95.0}"
readonly SHARED_IOS_SUPPORT_DIR="${SHARED_IOS_SUPPORT_DIR:-$HOME/code/ios-build-support}"
readonly DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/DeviceHub}"
readonly LOGGED_RUNNER="$SHARED_IOS_SUPPORT_DIR/scripts/run_logged.py"

if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required to build Apple Rust targets" >&2
  exit 1
fi
DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
export DEVELOPER_DIR
devicehub_check_xcode_toolchain

if [[ ! -r "$LOGGED_RUNNER" ]]; then
  echo "error: missing shared build logger: $LOGGED_RUNNER" >&2
  exit 1
fi
readonly OUTPUT_ROOT="$DERIVED_DATA_PATH/RunOutputs"
mkdir -p "$OUTPUT_ROOT"
RUN_DIRECTORY="$(mktemp -d "$OUTPUT_ROOT/devicehub-protocol-build.XXXXXXXX")"
readonly RUN_DIRECTORY

run_logged() {
  local label="${1:?label required}"
  local timeout="${2:?timeout required}"
  shift 2

  local log_path="$RUN_DIRECTORY/$label.log"
  if python3 "$LOGGED_RUNNER" \
    --log "$log_path" \
    --label "devicehub-$label" \
    --timeout "$timeout" \
    -- "$@"; then
    return 0
  else
    local status=$?
    printf 'Protocol step %s failed; log: %s\n' "$label" "$log_path" >&2
    return "$status"
  fi
}

python3 "$REPOSITORY_ROOT/BuildSupport/bootstrap_idevice.py"

installed_targets="$(rustup target list --installed --toolchain "$RUST_TOOLCHAIN")"
for target in "$DEVICE_TARGET" "$SIMULATOR_TARGET"; do
  if ! rg -qx "$target" <<<"$installed_targets"; then
    echo "error: missing Rust target $target" >&2
    echo "install it with: rustup target add --toolchain $RUST_TOOLCHAIN $target" >&2
    exit 1
  fi
done

export CARGO_TARGET_DIR="$BUILD_ROOT"
export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export RUSTC
export RUSTDOC
RUSTC="$(rustup which rustc --toolchain "$RUST_TOOLCHAIN")"
RUSTDOC="$(rustup which rustdoc --toolchain "$RUST_TOOLCHAIN")"
readonly CARGO=(rustup run "$RUST_TOOLCHAIN" cargo)

SDKROOT="$(/usr/bin/xcrun --sdk iphoneos --show-sdk-path)" \
  run_logged build-iphoneos 1740 \
  "${CARGO[@]}" build \
  --manifest-path "$MANIFEST" \
  --package device-hub-ffi \
  --release \
  --locked \
  --target "$DEVICE_TARGET"

SDKROOT="$(/usr/bin/xcrun --sdk iphonesimulator --show-sdk-path)" \
  run_logged build-iphonesimulator 1740 \
  "${CARGO[@]}" build \
  --manifest-path "$MANIFEST" \
  --package device-hub-ffi \
  --release \
  --locked \
  --target "$SIMULATOR_TARGET"

readonly DEVICE_LIBRARY="$BUILD_ROOT/$DEVICE_TARGET/release/libdevice_hub_ffi.a"
readonly SIMULATOR_LIBRARY="$BUILD_ROOT/$SIMULATOR_TARGET/release/libdevice_hub_ffi.a"
if [[ ! -s "$DEVICE_LIBRARY" || ! -s "$SIMULATOR_LIBRARY" ]]; then
  echo "error: Cargo did not produce both expected static libraries" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_ROOT"
staging_directory="$(mktemp -d "$ARTIFACT_ROOT/.xcframework.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
readonly STAGED_OUTPUT="$staging_directory/DeviceHubFFI.xcframework"

run_logged create-xcframework 300 /usr/bin/xcodebuild -create-xcframework \
  -library "$DEVICE_LIBRARY" \
  -headers "$HEADER_DIRECTORY" \
  -library "$SIMULATOR_LIBRARY" \
  -headers "$HEADER_DIRECTORY" \
  -output "$STAGED_OUTPUT"

"$SCRIPT_DIR/verify-protocol-xcframework.sh" "$STAGED_OUTPUT"

previous_output="$staging_directory/previous.xcframework"
if [[ -e "$OUTPUT" ]]; then
  mv "$OUTPUT" "$previous_output"
fi
if ! mv "$STAGED_OUTPUT" "$OUTPUT"; then
  if [[ -e "$previous_output" ]]; then
    mv "$previous_output" "$OUTPUT"
  fi
  echo "error: unable to install the verified XCFramework" >&2
  exit 1
fi
if [[ -e "$previous_output" ]]; then
  rm -rf "$previous_output"
fi

printf 'Created %s\nProtocol build logs: %s\n' "$OUTPUT" "$RUN_DIRECTORY"
