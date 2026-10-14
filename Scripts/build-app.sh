#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
# shellcheck source=BuildSupport/signing_keychain.sh
source "$ROOT/BuildSupport/signing_keychain.sh"
devicehub_require_guard build-app 1200 "$0" "$@"

DESTINATION="${DESTINATION:-generic/platform=iOS}"
CONFIGURATION="${CONFIGURATION:-Debug}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
SIGNING_KEYCHAIN_PATH="${SIGNING_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData}"
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
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -skipMacroValidation
  CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED"
)

if [[ "$CODE_SIGNING_ALLOWED" == "YES" && "$DESTINATION" != *"Simulator"* ]]; then
  devicehub_validate_signing_keychain "$SIGNING_KEYCHAIN_PATH"
  XCODEBUILD_ARGS+=(
    CODE_SIGN_KEYCHAIN="$SIGNING_KEYCHAIN_PATH"
    OTHER_CODE_SIGN_FLAGS="--keychain $SIGNING_KEYCHAIN_PATH"
  )
fi

if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  XCODEBUILD_ARGS+=(-allowProvisioningUpdates)
fi

cd "$ROOT"
"$XCODEBUILD_COMMAND" build "${XCODEBUILD_ARGS[@]}"
