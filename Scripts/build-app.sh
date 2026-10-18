#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
# shellcheck source=BuildSupport/check_xcode_toolchain.sh
source "$ROOT/BuildSupport/check_xcode_toolchain.sh"
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
SHARED_IOS_SUPPORT_DIR="${SHARED_IOS_SUPPORT_DIR:-$HOME/code/ios-build-support}"
DEVICE_HUB_BUNDLE_IDENTIFIER="${DEVICE_HUB_BUNDLE_IDENTIFIER:-es.javisoto.DeviceHub}"

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
export DEVELOPER_DIR
devicehub_check_xcode_toolchain

if [[ ! -r "$SHARED_IOS_SUPPORT_DIR/scripts/run_logged.py" ]]; then
  echo "Missing shared build logger: $SHARED_IOS_SUPPORT_DIR/scripts/run_logged.py" >&2
  exit 1
fi
BUILD_OUTPUT_ROOT="$DERIVED_DATA_PATH/RunOutputs"
mkdir -p "$BUILD_OUTPUT_ROOT"
BUILD_RUN_DIRECTORY="$(mktemp -d "$BUILD_OUTPUT_ROOT/devicehub-build.XXXXXXXX")"
BUILD_RESULT_BUNDLE="$BUILD_RUN_DIRECTORY/build.xcresult"

XCODEBUILD_ARGS=(
  -quiet
  -project "$ROOT/DeviceHub.xcodeproj"
  -scheme DeviceHub
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -resultBundlePath "$BUILD_RESULT_BUNDLE"
  -skipMacroValidation
  CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED"
)

XCODEBUILD_ARGS+=("DEVICE_HUB_BUNDLE_IDENTIFIER=$DEVICE_HUB_BUNDLE_IDENTIFIER")

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
if python3 "$SHARED_IOS_SUPPORT_DIR/scripts/run_logged.py" \
  --log "$BUILD_RUN_DIRECTORY/build.log" \
  --label devicehub-app-build \
  --timeout 1200 \
  -- "$XCODEBUILD_COMMAND" build "${XCODEBUILD_ARGS[@]}"; then
  printf 'Build result: %s\n' "$BUILD_RESULT_BUNDLE"
else
  status=$?
  printf 'Build failed; logs and result bundle: %s\n' "$BUILD_RUN_DIRECTORY" >&2
  exit "$status"
fi
