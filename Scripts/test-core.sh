#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
# shellcheck source=BuildSupport/check_xcode_toolchain.sh
source "$ROOT/BuildSupport/check_xcode_toolchain.sh"
devicehub_require_guard test-core 900 "$0" "$@"

SHARED_IOS_SUPPORT_DIR="${SHARED_IOS_SUPPORT_DIR:-$HOME/code/ios-build-support}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/DeviceHub}"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
if [[ ! -r "$SHARED_IOS_SUPPORT_DIR/scripts/run_logged.py" ]]; then
  echo "Missing shared build logger: $SHARED_IOS_SUPPORT_DIR/scripts/run_logged.py" >&2
  exit 1
fi
export DEVELOPER_DIR
devicehub_check_xcode_toolchain

SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-$DERIVED_DATA_PATH/SwiftPM/DeviceHubKit}"
TEST_ARGUMENTS=(--package-path "$ROOT/Packages/DeviceHubKit")
TEST_ARGUMENTS+=(--scratch-path "$SCRATCH_PATH")

OUTPUT_ROOT="$DERIVED_DATA_PATH/RunOutputs"
mkdir -p "$OUTPUT_ROOT"
RUN_DIRECTORY="$(mktemp -d "$OUTPUT_ROOT/devicehub-core-test.XXXXXXXX")"
TEST_LOG="$RUN_DIRECTORY/swift-test.log"
if python3 "$SHARED_IOS_SUPPORT_DIR/scripts/run_logged.py" \
  --log "$TEST_LOG" \
  --label devicehub-core-tests \
  --timeout 840 \
  -- swift test "${TEST_ARGUMENTS[@]}"; then
  printf 'Swift test log: %s\n' "$TEST_LOG"
else
  status=$?
  printf 'Swift tests failed; log: %s\n' "$TEST_LOG" >&2
  exit "$status"
fi
