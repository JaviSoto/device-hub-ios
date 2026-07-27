#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard test-live-ios 1200 "$0" "$@"

DESTINATION="${DESTINATION:-}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedDataLiveTests}"
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

cd "$ROOT"
"$XCODEGEN_COMMAND" generate
set +e
"$XCODEBUILD_COMMAND" test \
  -quiet \
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
