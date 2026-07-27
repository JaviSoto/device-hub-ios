#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_ROOT
readonly PROCESS_GUARD="$REPOSITORY_ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard build-protocol-xcframework 1800 "$0" "$@"

readonly MANIFEST="$REPOSITORY_ROOT/Rust/Cargo.toml"
readonly HEADER_DIRECTORY="$REPOSITORY_ROOT/Rust/DeviceHubFFI/include"
readonly BUILD_ROOT="$REPOSITORY_ROOT/Rust/.build/cargo"
readonly ARTIFACT_ROOT="$REPOSITORY_ROOT/Rust/Artifacts"
readonly OUTPUT="$ARTIFACT_ROOT/DeviceHubFFI.xcframework"
readonly DEPLOYMENT_TARGET="27.0"
readonly DEVICE_TARGET="aarch64-apple-ios"
readonly SIMULATOR_TARGET="aarch64-apple-ios-sim"
readonly RUST_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.95.0}"

if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required to build Apple Rust targets" >&2
  exit 1
fi
if [[ ! -x /usr/bin/xcodebuild || ! -x /usr/bin/xcrun ]]; then
  echo "error: the Xcode command-line tools are required" >&2
  exit 1
fi
xcode_version="$(/usr/bin/xcodebuild -version)"
if ! rg -q '^Xcode 27(\.|$)' <<<"$xcode_version"; then
  echo "error: Device Hub requires Xcode 27; selected toolchain is:" >&2
  echo "$xcode_version" >&2
  exit 1
fi

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
  "${CARGO[@]}" build \
  --manifest-path "$MANIFEST" \
  --package device-hub-ffi \
  --release \
  --locked \
  --target "$DEVICE_TARGET"

SDKROOT="$(/usr/bin/xcrun --sdk iphonesimulator --show-sdk-path)" \
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

/usr/bin/xcodebuild -create-xcframework \
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

echo "Created $OUTPUT"
