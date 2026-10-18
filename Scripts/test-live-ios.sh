#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard test-live-ios 1200 "$0" "$@"
# shellcheck source=BuildSupport/check_xcode_toolchain.sh
source "$ROOT/BuildSupport/check_xcode_toolchain.sh"

# shellcheck source=BuildSupport/xcodebuild_test_output.sh
source "$ROOT/BuildSupport/xcodebuild_test_output.sh"

DESTINATION="${DESTINATION:-}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/DeviceHub}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
EVIDENCE_ROOT="${DEVICE_HUB_TEST_EVIDENCE_DIR:-$DERIVED_DATA_PATH/TestEvidence/DeviceHub/$RUN_ID}"
XCODEGEN_COMMAND="${XCODEGEN_COMMAND:-xcodegen}"
XCODEBUILD_COMMAND="${XCODEBUILD_COMMAND:-/usr/bin/xcodebuild}"

case "$DESTINATION" in
  "platform=iOS Simulator,"*) ;;
  *)
    echo "DESTINATION must identify an iOS Simulator, not a physical device." >&2
    exit 2
    ;;
esac

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
export DEVELOPER_DIR
devicehub_check_xcode_toolchain

cd "$ROOT"
REPOSITORY_ROOT="$(cd "$ROOT" && pwd -P)"
if [[ "$EVIDENCE_ROOT" != /* ]]; then
  printf 'Test evidence path must be absolute: %s\n' "$EVIDENCE_ROOT" >&2
  exit 2
fi
case "$EVIDENCE_ROOT/" in
  "$REPOSITORY_ROOT/"*)
    printf 'Test evidence must be outside the repository: %s\n' "$EVIDENCE_ROOT" >&2
    exit 2
    ;;
esac
mkdir -p "$EVIDENCE_ROOT"
EVIDENCE_ROOT="$(cd "$EVIDENCE_ROOT" && pwd -P)"
case "$EVIDENCE_ROOT/" in
  "$REPOSITORY_ROOT/"*)
    printf 'Test evidence must be outside the repository: %s\n' "$EVIDENCE_ROOT" >&2
    exit 2
    ;;
esac
RAW_LOG="$EVIDENCE_ROOT/devicehub-live-tests-$RUN_ID.log"
RESULT_BUNDLE="$EVIDENCE_ROOT/devicehub-live-tests-$RUN_ID.xcresult"
printf 'Test evidence: %s\n' "$EVIDENCE_ROOT"

"$XCODEGEN_COMMAND" generate
set +e
devicehub_run_xcodebuild \
  devicehub-live-tests \
  "$RAW_LOG" \
  "$RESULT_BUNDLE" \
  1080 \
  "$XCODEBUILD_COMMAND" \
  test \
  -project "$ROOT/DeviceHub.xcodeproj" \
  -scheme DeviceHub \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:DeviceHubLiveTests \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO
TEST_STATUS=$?
set -e

if ! python3 "$ROOT/BuildSupport/guarded_process.py" \
  --cleanup-selected-xcode-test-service-hub \
  --developer-dir "$DEVELOPER_DIR"; then
  echo "Could not clean up Xcode's detached test service." >&2
  exit 126
fi

exit "$TEST_STATUS"
