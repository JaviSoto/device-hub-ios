#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_ROOT
readonly PROCESS_GUARD="$REPOSITORY_ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard test-rust 1800 "$0" "$@"

readonly SHARED_IOS_SUPPORT_DIR="${SHARED_IOS_SUPPORT_DIR:-$HOME/code/ios-build-support}"
readonly DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/DeviceHub}"
readonly LOGGED_RUNNER="$SHARED_IOS_SUPPORT_DIR/scripts/run_logged.py"
if [[ ! -r "$LOGGED_RUNNER" ]]; then
  echo "error: missing shared build logger: $LOGGED_RUNNER" >&2
  exit 1
fi
readonly OUTPUT_ROOT="$DERIVED_DATA_PATH/RunOutputs"
mkdir -p "$OUTPUT_ROOT"
RUN_DIRECTORY="$(mktemp -d "$OUTPUT_ROOT/devicehub-rust-test.XXXXXXXX")"
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
    printf 'Rust step %s failed; log: %s\n' "$label" "$log_path" >&2
    return "$status"
  fi
}

readonly MANIFEST="$REPOSITORY_ROOT/Rust/Cargo.toml"
readonly IDEVICE_MANIFEST="$REPOSITORY_ROOT/Vendor/idevice/Cargo.toml"
readonly IDEVICE_REVISION="a64b8867815b3da17b5c927531bdba877e8456ef"
readonly RUST_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.95.0}"

if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required so Cargo and rustc use the same pinned toolchain" >&2
  exit 1
fi

python3 "$REPOSITORY_ROOT/BuildSupport/bootstrap_idevice.py"

RUST_TOOLCHAIN_BIN="$(dirname "$(rustup which rustc --toolchain "$RUST_TOOLCHAIN")")"
readonly RUST_TOOLCHAIN_BIN
export PATH="$RUST_TOOLCHAIN_BIN:$PATH"
export RUSTC="$RUST_TOOLCHAIN_BIN/rustc"
export RUSTDOC="$RUST_TOOLCHAIN_BIN/rustdoc"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$DERIVED_DATA_PATH/Rust/.build/tests}"
readonly CARGO=(rustup run "$RUST_TOOLCHAIN" cargo)

if ! rg -Fq "idevice-revision = \"$IDEVICE_REVISION\"" \
  "$REPOSITORY_ROOT/Rust/DeviceHubFFI/Cargo.toml"; then
  echo "error: DeviceHubFFI metadata does not pin the reviewed idevice revision" >&2
  exit 1
fi
"${CARGO[@]}" fmt --manifest-path "$MANIFEST" -- --check
"${CARGO[@]}" fmt \
  --manifest-path "$IDEVICE_MANIFEST" \
  --package idevice \
  -- \
  --check
run_logged test-idevice 1740 "${CARGO[@]}" test \
  --manifest-path "$IDEVICE_MANIFEST" \
  --package idevice \
  --no-default-features \
  --features ring,remote_pairing,tunnel_tcp_stack,display_stream,mobile_image_mounter \
  --lib \
  --locked
run_logged clippy-idevice 1740 "${CARGO[@]}" clippy \
  --manifest-path "$IDEVICE_MANIFEST" \
  --package idevice \
  --no-default-features \
  --features ring,remote_pairing,tunnel_tcp_stack,display_stream,mobile_image_mounter \
  --lib \
  --tests \
  --locked \
  -- \
  -D warnings
run_logged check-idevice-full 1740 "${CARGO[@]}" check \
  --manifest-path "$IDEVICE_MANIFEST" \
  --package idevice \
  --features full \
  --locked
run_logged test-device-hub-ffi 1740 "${CARGO[@]}" test \
  --manifest-path "$MANIFEST" \
  --package device-hub-ffi \
  --locked
run_logged clippy-device-hub-ffi 1740 "${CARGO[@]}" clippy \
  --manifest-path "$MANIFEST" \
  --package device-hub-ffi \
  --all-targets \
  --locked \
  -- \
  -D warnings

feature_tree="$("${CARGO[@]}" tree \
  --manifest-path "$MANIFEST" \
  --package device-hub-ffi \
  --locked \
  --edges features \
  --invert idevice)"
for feature in ring remote_pairing tunnel_tcp_stack display_stream mobile_image_mounter; do
  if ! rg -q "idevice feature \"$feature\"" <<<"$feature_tree"; then
    echo "error: expected idevice feature is not enabled: $feature" >&2
    exit 1
  fi
done

echo "Rust boundary tests and dependency checks passed."
printf 'Rust test logs: %s\n' "$RUN_DIRECTORY"
