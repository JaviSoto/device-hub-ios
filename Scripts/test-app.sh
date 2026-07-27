#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard test-app 1800 "$0" "$@"

RUN_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/device-hub-app-tests.XXXXXX")"
DERIVED_DATA_PATH="$RUN_ROOT/DerivedData"
SNAPSHOT_DERIVED_DATA_PATH="$RUN_ROOT/SnapshotDerivedData"
ACCESSIBILITY_JSON="$RUN_ROOT/accessibility.json"
SIMULATOR_UDID="${CI_SIMULATOR_UDID:-}"
CREATED_SIMULATOR=0
RECORD_SNAPSHOTS="${DEVICE_HUB_RECORD_SNAPSHOTS:-0}"

# Invoked by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  local status=$?
  if [[ "$CREATED_SIMULATOR" == "1" && -n "$SIMULATOR_UDID" ]]; then
    xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  fi
  rm -rf "$RUN_ROOT"
  return "$status"
}
trap cleanup EXIT

latest_ios_runtime() {
  xcrun simctl list runtimes --json | python3 -c '
import json
import sys

runtimes = json.load(sys.stdin).get("runtimes", [])
candidates = [
    runtime
    for runtime in runtimes
    if runtime.get("isAvailable")
    and str(runtime.get("identifier", "")).startswith(
        "com.apple.CoreSimulator.SimRuntime.iOS-27-"
    )
]
if not candidates:
    raise SystemExit("No available iOS 27 simulator runtime")
print(sorted(candidates, key=lambda runtime: runtime["identifier"])[-1]["identifier"])
'
}

preferred_iphone_type() {
  xcrun simctl list devicetypes --json | python3 -c '
import json
import sys

devices = json.load(sys.stdin).get("devicetypes", [])
iphones = [device for device in devices if str(device.get("name", "")).startswith("iPhone ")]
preferred = next(
    (device for device in iphones if device.get("name") == "iPhone 17 Pro"),
    None,
)
selected = preferred or (iphones[-1] if iphones else None)
if selected is None:
    raise SystemExit("No iPhone simulator device type")
print(selected["identifier"])
'
}

if [[ -z "$SIMULATOR_UDID" ]]; then
  SIMULATOR_UDID="$(
    xcrun simctl create \
      "Device Hub Tests $$" \
      "$(preferred_iphone_type)" \
      "$(latest_ios_runtime)"
  )"
  CREATED_SIMULATOR=1
fi

xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

cd "$ROOT"
CI_SIMULATOR_UDID="$SIMULATOR_UDID" \
  Sources/DeviceHubPrivateMedia/Tests/run-tests.sh

DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID" \
DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
  Scripts/test-live-ios.sh

run_ui_snapshot_tests() {
  local record_mode="${1:?record mode required}"
  local compilation_conditions
  # Xcode expands this build-setting token; the shell must preserve it.
  # shellcheck disable=SC2016
  compilation_conditions='$(inherited)'
  if [[ "$record_mode" == "1" ]]; then
    compilation_conditions+=" DEVICE_HUB_RECORD_SNAPSHOTS"
  fi
  (
    cd "$ROOT/Packages/DeviceHubKit"
    set +e
    /usr/bin/xcodebuild test \
        -quiet \
        -scheme DeviceHubKit-Package \
        -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
        -derivedDataPath "$SNAPSHOT_DERIVED_DATA_PATH" \
        -only-testing:DeviceHubUITests/DeviceHubVisualSnapshotTests \
        -parallel-testing-enabled NO \
        -collect-test-diagnostics never \
        -skipMacroValidation \
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$compilation_conditions" \
        CODE_SIGNING_ALLOWED=NO
    local test_status=$?
    set -e
    if ! python3 "$ROOT/BuildSupport/guarded_process.py" \
      --cleanup-selected-xcode-test-service-hub \
      --developer-dir "$(xcode-select -p)"; then
      printf 'Could not clean up Xcode test services.\n' >&2
      return 126
    fi
    return "$test_status"
  )
}

if [[ "$RECORD_SNAPSHOTS" == "1" ]]; then
  set +e
  run_ui_snapshot_tests 1
  record_status=$?
  set -e
  printf 'Snapshot recording pass exited %d; verifying references.\n' \
    "$record_status"
elif [[ "$RECORD_SNAPSHOTS" != "0" ]]; then
  printf 'DEVICE_HUB_RECORD_SNAPSHOTS must be 0 or 1.\n' >&2
  exit 2
fi
run_ui_snapshot_tests 0

DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID" \
CODE_SIGNING_ALLOWED=YES \
DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
  Scripts/build-app.sh

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/DeviceHub.app"
if [[ ! -d "$APP_PATH" ]]; then
  printf 'Simulator build did not produce %s\n' "$APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
BUNDLE_IDENTIFIER="$(
  plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist"
)"
xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_IDENTIFIER" >/dev/null

accessibility_matches() {
  local screen="$1"
  axe describe-ui --udid "$SIMULATOR_UDID" >"$ACCESSIBILITY_JSON" 2>/dev/null &&
    python3 BuildSupport/accessibility_contract.py \
      --probe \
      --screen "$screen" \
      "$ACCESSIBILITY_JSON"
}

INITIAL_SCREEN=""
for _attempt in {1..60}; do
  if accessibility_matches naming; then
    INITIAL_SCREEN="naming"
    break
  fi
  if accessibility_matches post-bootstrap; then
    INITIAL_SCREEN="post-bootstrap"
    break
  fi
  sleep 0.5
done

if [[ -z "$INITIAL_SCREEN" ]]; then
  printf 'The launched app never reached a known accessibility screen.\n' >&2
  exit 1
fi

if [[ "$INITIAL_SCREEN" == "naming" ]]; then
  axe tap \
    --id advertised-device-name-field \
    --element-type TextField \
    --wait-timeout 10 \
    --post-delay 1 \
    --udid "$SIMULATOR_UDID"
  axe type "Test Controller" --udid "$SIMULATOR_UDID"
  axe tap \
    --label Continue \
    --element-type Button \
    --wait-timeout 10 \
    --post-delay 0.5 \
    --udid "$SIMULATOR_UDID"
fi

for _attempt in {1..60}; do
  if accessibility_matches post-bootstrap; then
    printf 'App integration and accessibility tests passed.\n'
    exit 0
  fi
  sleep 0.5
done

python3 BuildSupport/accessibility_contract.py \
  --screen post-bootstrap \
  "$ACCESSIBILITY_JSON" || true
printf 'The app did not reach its post-bootstrap accessibility contract.\n' >&2
exit 1
