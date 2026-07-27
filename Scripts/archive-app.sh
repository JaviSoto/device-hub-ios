#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard archive-app 1800 "$0" "$@"

ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/DeviceHub.xcarchive}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"
XCODEGEN_COMMAND="${XCODEGEN_COMMAND:-xcodegen}"
XCODEBUILD_COMMAND="${XCODEBUILD_COMMAND:-/usr/bin/xcodebuild}"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
export DEVELOPER_DIR

XCODEBUILD_ARGS=(
  -quiet
  -project "$ROOT/DeviceHub.xcodeproj"
  -scheme DeviceHub
  -configuration Release
  -destination generic/platform=iOS
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -skipMacroValidation
  CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED"
)

if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  XCODEBUILD_ARGS+=(-allowProvisioningUpdates)
fi

cd "$ROOT"
"$XCODEGEN_COMMAND" generate
mkdir -p "$(dirname "$ARCHIVE_PATH")"
"$XCODEBUILD_COMMAND" archive "${XCODEBUILD_ARGS[@]}"

printf 'Created %s\n' "$ARCHIVE_PATH"
