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
export CARGO_TARGET_DIR="$REPOSITORY_ROOT/Rust/.build/tests"
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
"${CARGO[@]}" test \
  --manifest-path "$IDEVICE_MANIFEST" \
  --package idevice \
  --no-default-features \
  --features ring,remote_pairing,tunnel_tcp_stack,display_stream,mobile_image_mounter \
  --lib \
  --locked
"${CARGO[@]}" clippy \
  --manifest-path "$IDEVICE_MANIFEST" \
  --package idevice \
  --no-default-features \
  --features ring,remote_pairing,tunnel_tcp_stack,display_stream,mobile_image_mounter \
  --lib \
  --tests \
  --locked \
  -- \
  -D warnings
"${CARGO[@]}" check \
  --manifest-path "$IDEVICE_MANIFEST" \
  --package idevice \
  --features full \
  --locked
"${CARGO[@]}" test \
  --manifest-path "$MANIFEST" \
  --package device-hub-ffi \
  --locked
"${CARGO[@]}" clippy \
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
