#!/usr/bin/env bash
set -euo pipefail

# Keep build logs on stderr. The only stdout value is the verified IPA path so
# release.sh can pass the exact artifact to the one canonical publisher.
exec 3>&1
exec 1>&2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_IOS_SUPPORT_DIR="${SHARED_IOS_SUPPORT_DIR:-/Users/javi/code/ios-build-support}"
DEVELOPER_DIR="${DEVELOPER_DIR:-}"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
APPLE_API_KEY_JSON="${APPLE_API_KEY_JSON:-}"
TEAM_ID="${TEAM_ID:-6V6XY979JQ}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-es.javisoto.DeviceHub}"
CERTIFICATE="${CERTIFICATE:-Apple Distribution: Javier Soto Bustos (6V6XY979JQ)}"
TARGET_DEVICE_UDIDS="${TARGET_DEVICE_UDIDS:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_ROOT="${DEVICE_HUB_BUILD_ROOT:-$ROOT/build/device/$STAMP}"
LATEST_ROOT="${DEVICE_HUB_LATEST_ROOT:-$ROOT/build/device/latest}"
ARCHIVE_PATH="$BUILD_ROOT/DeviceHub.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export"
EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions.generated.plist"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData}"
DERIVED_DATA_EXTERNAL_ROOT="/Volumes/RunnerCache/DerivedData/javi"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Device Hub releases must run on macOS." >&2
  exit 1
fi
if [[ -z "$DEVELOPER_DIR" ]]; then
  if ! DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"; then
    echo "Unable to resolve the currently selected Xcode developer directory." >&2
    exit 1
  fi
fi
if [[ ! -d "$SHARED_IOS_SUPPORT_DIR" ]]; then
  echo "Missing shared iOS build support: $SHARED_IOS_SUPPORT_DIR" >&2
  exit 1
fi
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
if [[ -n "$APPLE_API_KEY_JSON" && ! -f "$APPLE_API_KEY_JSON" ]]; then
  echo "App Store Connect API key JSON is missing: $APPLE_API_KEY_JSON" >&2
  exit 1
fi
if [[ ! -d /Volumes/RunnerCache ]]; then
  echo "RunnerCache must be mounted before a Device Hub release." >&2
  exit 1
fi
RUNNERCACHE_MOUNT="$(df -P /Volumes/RunnerCache | awk 'NR == 2 {print $NF}')"
if [[ "$RUNNERCACHE_MOUNT" != "/Volumes/RunnerCache" ]]; then
  echo "RunnerCache is not mounted at /Volumes/RunnerCache." >&2
  exit 1
fi
case "$DERIVED_DATA_PATH" in
  "$HOME/Library/Developer/Xcode/DerivedData"|\
  "$HOME/Library/Developer/Xcode/DerivedData/"*|\
  "$DERIVED_DATA_EXTERNAL_ROOT"|\
  "$DERIVED_DATA_EXTERNAL_ROOT/"*) ;;
  *)
    echo "DerivedData must use the native Xcode path or RunnerCache: $DERIVED_DATA_PATH" >&2
    exit 1
    ;;
esac
if [[ ! -d "$DERIVED_DATA_PATH" ]]; then
  mkdir -p "$DERIVED_DATA_PATH"
fi
DERIVED_DATA_REALPATH="$(cd "$DERIVED_DATA_PATH" && pwd -P)"
case "$DERIVED_DATA_REALPATH" in
  "$DERIVED_DATA_EXTERNAL_ROOT"|"$DERIVED_DATA_EXTERNAL_ROOT/"*) ;;
  *)
    echo "DerivedData must resolve to RunnerCache: $DERIVED_DATA_REALPATH" >&2
    exit 1
    ;;
esac
DERIVED_DATA_MOUNT="$(df -P "$DERIVED_DATA_REALPATH" | awk 'NR == 2 {print $NF}')"
if [[ "$DERIVED_DATA_MOUNT" != "/Volumes/RunnerCache" ]]; then
  echo "DerivedData is not on RunnerCache: $DERIVED_DATA_REALPATH" >&2
  exit 1
fi
EVIDENCE_ROOT="$DERIVED_DATA_REALPATH/DeviceHubRelease/$STAMP"
ARCHIVE_LOG="$EVIDENCE_ROOT/archive.log"
ARCHIVE_RESULT_BUNDLE="$EVIDENCE_ROOT/archive.xcresult"
EXPORT_LOG="$EVIDENCE_ROOT/export.log"

# shellcheck source=/dev/null
source "$SHARED_IOS_SUPPORT_DIR/scripts/release_build_settings.sh"
# shellcheck source=/dev/null
source "$SHARED_IOS_SUPPORT_DIR/scripts/adhoc_signing.sh"
export DEVELOPER_DIR
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ios_require_command xcbeautify
XCBEAUTIFY_BIN="$(ios_resolve_command xcbeautify)"

run_xcodebuild() {
  local action="${1:?action required}"
  local raw_log="${2:?raw log path required}"
  local result_bundle="${3:-}"
  shift 3

  local -a statuses
  if "$@" 2>&1 | tee "$raw_log" | "$XCBEAUTIFY_BIN" --is-ci --disable-logging; then
    statuses=("${PIPESTATUS[@]}")
  else
    statuses=("${PIPESTATUS[@]}")
  fi

  if (( statuses[0] != 0 )); then
    printf 'XCODEBUILD_FAILED action=%s xcodebuild_exit=%s tee_exit=%s formatter_exit=%s raw_log=%s' \
      "$action" "${statuses[0]}" "${statuses[1]}" "${statuses[2]}" "$raw_log" >&2
    if [[ -n "$result_bundle" ]]; then
      printf ' result_bundle=%s' "$result_bundle" >&2
    fi
    printf '\n' >&2
    return "${statuses[0]}"
  fi
  if (( statuses[1] != 0 )); then
    printf 'XCODEBUILD_OUTPUT_FAILED action=%s tee_exit=%s raw_log=%s' \
      "$action" "${statuses[1]}" "$raw_log" >&2
    if [[ -n "$result_bundle" ]]; then
      printf ' result_bundle=%s' "$result_bundle" >&2
    fi
    printf '\n' >&2
    return "${statuses[1]}"
  fi
  if (( statuses[2] != 0 )); then
    printf 'XCODEBUILD_FORMAT_FAILED action=%s formatter_exit=%s raw_log=%s' \
      "$action" "${statuses[2]}" "$raw_log" >&2
    if [[ -n "$result_bundle" ]]; then
      printf ' result_bundle=%s' "$result_bundle" >&2
    fi
    printf '\n' >&2
    return "${statuses[2]}"
  fi
  if [[ -n "$result_bundle" && ! -d "$result_bundle" ]]; then
    printf 'XCODEBUILD_RESULT_MISSING action=%s result_bundle=%s raw_log=%s\n' \
      "$action" "$result_bundle" "$raw_log" >&2
    return 1
  fi

  printf 'XCODEBUILD_OK action=%s raw_log=%s' "$action" "$raw_log" >&2
  if [[ -n "$result_bundle" ]]; then
    printf ' result_bundle=%s' "$result_bundle" >&2
  fi
  printf '\n' >&2
}

cd "$ROOT"
if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "Device Hub release builds require a clean Git worktree." >&2
  git status --short >&2
  exit 2
fi

ios_require_command xcodegen
ios_validate_signing_keychain "$KEYCHAIN_PATH"
SOURCE_REVISION="$(git rev-parse --verify HEAD)"
DEFAULT_BUILD_NUMBER="$("$SHARED_IOS_SUPPORT_DIR/scripts/ios_build_number.sh")"
PROJECT_MARKETING_VERSION="$(yq '.settings.base.MARKETING_VERSION' "$ROOT/project.yml")"
ios_prepare_build_version_overrides "$PROJECT_MARKETING_VERSION" "$DEFAULT_BUILD_NUMBER"

# Build the protocol artifact before generating the project. This is the same
# source-controlled protocol boundary used by the normal app build.
"$ROOT/Scripts/build-protocol-xcframework.sh"
xcodegen generate --spec "$ROOT/project.yml"

mkdir -p "$BUILD_ROOT" "$EXPORT_PATH" "$LATEST_ROOT" "$EVIDENCE_ROOT"
if [[ -z "$TARGET_DEVICE_UDIDS" ]]; then
  TARGET_DEVICE_UDIDS="$(ios_fetch_enabled_ios_device_udids "$APPLE_API_KEY_JSON")"
fi
PROFILE_UUID="$(ios_ensure_profile_uuid \
  "$APP_BUNDLE_ID" \
  "${PROFILE_UUID:-}" \
  "$TARGET_DEVICE_UDIDS" \
  'Device Hub AdHoc' \
  "$APPLE_API_KEY_JSON" \
  "$SHARED_IOS_SUPPORT_DIR/scripts/ensure_adhoc_profile.py" \
  "$TEAM_ID" \
  "$CERTIFICATE")"

ios_write_adhoc_export_options_plist \
  "$EXPORT_OPTIONS" \
  "$TEAM_ID" \
  manual \
  "$CERTIFICATE" \
  "$APP_BUNDLE_ID=$PROFILE_UUID"

run_xcodebuild archive "$ARCHIVE_LOG" "$ARCHIVE_RESULT_BUNDLE" \
  /usr/bin/xcodebuild archive \
  -project "$ROOT/DeviceHub.xcodeproj" \
  -scheme DeviceHub \
  -configuration Release \
  -destination generic/platform=iOS \
  -archivePath "$ARCHIVE_PATH" \
  -resultBundlePath "$ARCHIVE_RESULT_BUNDLE" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$CERTIFICATE" \
  CODE_SIGN_KEYCHAIN="$KEYCHAIN_PATH" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH" \
  DEVICE_HUB_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" \
  DEVICE_HUB_DEVELOPMENT_TEAM="$TEAM_ID" \
  DEVICE_HUB_CODE_SIGN_STYLE=Manual \
  DEVICE_HUB_PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" \
  DEVICE_HUB_SOURCE_REVISION="$SOURCE_REVISION" \
  "${BUILD_SETTING_OVERRIDES[@]}"

run_xcodebuild export "$EXPORT_LOG" "" \
  /usr/bin/xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

shopt -s nullglob
EXPORTED_IPAS=("$EXPORT_PATH"/*.ipa)
shopt -u nullglob
if (( ${#EXPORTED_IPAS[@]} != 1 )); then
  echo "Expected one exported Device Hub IPA, found ${#EXPORTED_IPAS[@]}." >&2
  exit 1
fi
if [[ ! -f "$EXPORT_PATH/manifest.plist" ]]; then
  echo "The archive export did not produce an install manifest." >&2
  exit 1
fi

IPA_PATH="$LATEST_ROOT/DeviceHub.ipa"
MANIFEST_PATH="$LATEST_ROOT/manifest.plist"
cp "${EXPORTED_IPAS[0]}" "$IPA_PATH"
cp "$EXPORT_PATH/manifest.plist" "$MANIFEST_PATH"
printf '%s\n%s\n' "$FINAL_IOS_MARKETING_VERSION" "$FINAL_IOS_BUILD_NUMBER" \
  > "$LATEST_ROOT/version.txt"
printf '%s\n' "$SOURCE_REVISION" > "$LATEST_ROOT/source-revision.txt"

python3 - "$IPA_PATH" "$APP_BUNDLE_ID" "$FINAL_IOS_MARKETING_VERSION" \
  "$FINAL_IOS_BUILD_NUMBER" "$SOURCE_REVISION" <<'PY'
from __future__ import annotations

import plistlib
import sys
from pathlib import Path
from zipfile import ZipFile

ipa, expected_bundle, expected_version, expected_build, expected_revision = map(
    str, sys.argv[1:]
)
with ZipFile(Path(ipa)) as archive:
    info_name = next(
        name for name in archive.namelist() if name.endswith(".app/Info.plist")
    )
    info = plistlib.loads(archive.read(info_name))

checks = {
    "CFBundleIdentifier": expected_bundle,
    "CFBundleShortVersionString": expected_version,
    "CFBundleVersion": expected_build,
    "CFBundleSourceRevision": expected_revision,
}
for key, expected in checks.items():
    if info.get(key) != expected:
        raise SystemExit(f"IPA metadata mismatch for {key}: {info.get(key)!r}")
print(f"Verified Device Hub IPA {expected_version} ({expected_build})")
PY

VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/device-hub-ipa-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_ROOT"' EXIT
/usr/bin/ditto -x -k "$IPA_PATH" "$VERIFY_ROOT"
/usr/bin/codesign --verify --deep --strict "$VERIFY_ROOT/Payload/DeviceHub.app"
printf '%s\n' "$IPA_PATH" >&3
