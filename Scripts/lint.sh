#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard lint 1800 "$0" "$@"

require_command() {
  local command_name="${1:?command name required}"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required validation tool: $command_name" >&2
    return 1
  fi
}

for command_name in swiftformat swiftlint jscpd xcodegen periphery; do
  require_command "$command_name"
done

cd "$ROOT"
"$ROOT/Scripts/lint-source.sh"

xcodegen generate
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
INDEXSTORE_LIBRARY_DIR="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib"
export DEVELOPER_DIR
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"
if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
  export DYLD_LIBRARY_PATH="$INDEXSTORE_LIBRARY_DIR:$DYLD_LIBRARY_PATH"
else
  export DYLD_LIBRARY_PATH="$INDEXSTORE_LIBRARY_DIR"
fi

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
  -- \
  -destination generic/platform=iOS \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO

PACKAGE_ROOT="$ROOT/Packages/DeviceHubKit"
PACKAGE_DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/device-hub-periphery.XXXXXX")"
trap 'rm -rf "$PACKAGE_DERIVED_DATA"' EXIT
(
  cd "$PACKAGE_ROOT"
  /usr/bin/xcodebuild \
    -quiet \
    -jobs 4 \
    -scheme DeviceHubKit-Package \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$PACKAGE_DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$PACKAGE_DERIVED_DATA/SourcePackages" \
    -skipMacroValidation \
    build-for-testing \
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
