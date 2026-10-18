#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard lint-dead-code 1800 "$0" "$@"
# shellcheck source=BuildSupport/check_xcode_toolchain.sh
source "$ROOT/BuildSupport/check_xcode_toolchain.sh"

# shellcheck source=BuildSupport/xcodebuild_test_output.sh
source "$ROOT/BuildSupport/xcodebuild_test_output.sh"

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/DeviceHub}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
INDEXSTORE_LIBRARY_DIR="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib"
export DEVELOPER_DIR
devicehub_check_xcode_toolchain
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"
if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
  export DYLD_LIBRARY_PATH="$INDEXSTORE_LIBRARY_DIR:$DYLD_LIBRARY_PATH"
else
  export DYLD_LIBRARY_PATH="$INDEXSTORE_LIBRARY_DIR"
fi

cd "$ROOT"
if [[ ! -d DeviceHub.xcodeproj ]]; then
  echo "DeviceHub.xcodeproj is missing; run 'mise run generate' first." >&2
  exit 1
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
APP_EVIDENCE_ROOT="$DERIVED_DATA_PATH/TestEvidence/Periphery"
# Periphery always supplies its own -derivedDataPath when it builds. Build the
# index explicitly so both the compiler cache and evidence keep their owner.
devicehub_run_xcodebuild \
  devicehub-app-index \
  "$APP_EVIDENCE_ROOT/devicehub-app-index-$RUN_ID.log" \
  "$APP_EVIDENCE_ROOT/devicehub-app-index-$RUN_ID.xcresult" \
  1680 \
  /usr/bin/xcodebuild build-for-testing \
  -project "$ROOT/DeviceHub.xcodeproj" \
  -scheme DeviceHub \
  -destination generic/platform=iOS \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=YES \
  INDEX_ENABLE_DATA_STORE=YES

periphery scan \
  --project "$ROOT/DeviceHub.xcodeproj" \
  --schemes DeviceHub \
  --report-include "Sources/DeviceHubApp/**/*.swift" \
  --retain-public \
  --retain-swift-ui-previews \
  --disable-update-check \
  --relative-results \
  --strict \
  --format xcode \
  --skip-build \
  --index-store-path "$DERIVED_DATA_PATH/Index.noindex/DataStore"

PACKAGE_ROOT="$ROOT/Packages/DeviceHubKit"
PACKAGE_DERIVED_DATA="$DERIVED_DATA_PATH/Periphery/DeviceHubKit"
PACKAGE_BUILD_LOG="$DERIVED_DATA_PATH/TestEvidence/Periphery/devicehub-kit-build-for-testing-$RUN_ID.log"
PACKAGE_BUILD_RESULT_BUNDLE="${PACKAGE_BUILD_LOG%.log}.xcresult"
mkdir -p "$PACKAGE_DERIVED_DATA" "$(dirname "$PACKAGE_BUILD_LOG")"

(
  cd "$PACKAGE_ROOT"
  devicehub_run_xcodebuild \
    devicehub-kit-index \
    "$PACKAGE_BUILD_LOG" \
    "$PACKAGE_BUILD_RESULT_BUNDLE" \
    1680 \
    /usr/bin/xcodebuild build-for-testing \
    -jobs 4 \
    -scheme DeviceHubKit-Package \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$PACKAGE_DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$PACKAGE_DERIVED_DATA/SourcePackages" \
    -skipMacroValidation \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO
)
PACKAGE_INDEX_STORE="$PACKAGE_DERIVED_DATA/Index.noindex/DataStore"
periphery scan \
  --project-root "$PACKAGE_ROOT" \
  --index-store-path "$PACKAGE_INDEX_STORE" \
  --index-exclude "$PACKAGE_DERIVED_DATA/SourcePackages/checkouts/**" \
  --report-include "Sources/**/*.swift" \
  --report-include "Tests/**/*.swift" \
  --skip-build \
  --retain-public \
  --retain-codable-properties \
  --retain-swift-ui-previews \
  --disable-update-check \
  --relative-results \
  --strict \
  --format xcode
