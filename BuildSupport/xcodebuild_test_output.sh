#!/usr/bin/env bash

# Run one Xcode command with private logs and concise status.
devicehub_run_xcodebuild() {
  if (( $# < 6 )); then
    printf 'xcodebuild output requires action, raw log, result bundle, timeout, and command.\n' >&2
    return 2
  fi

  local action="$1"
  local raw_log="$2"
  local result_bundle="$3"
  local timeout="$4"
  local xcodebuild_command="$5"
  local xcodebuild_action="$6"
  shift 6

  local shared_support="${SHARED_IOS_SUPPORT_DIR:-$HOME/code/ios-build-support}"
  local logged_runner="$shared_support/scripts/run_logged.py"
  if [[ ! -r "$logged_runner" ]]; then
    printf 'Missing shared build logger: %s\n' "$logged_runner" >&2
    return 1
  fi
  if [[ -e "$raw_log" || -e "$result_bundle" ]]; then
    printf 'Refusing to overwrite existing test evidence: raw_log=%s result_bundle=%s\n' \
      "$raw_log" "$result_bundle" >&2
    return 2
  fi
  if ! mkdir -p "$(dirname "$raw_log")" "$(dirname "$result_bundle")"; then
    printf 'Could not create test evidence directories: raw_log=%s result_bundle=%s\n' \
      "$raw_log" "$result_bundle" >&2
    return 1
  fi

  local status
  if python3 "$logged_runner" \
    --log "$raw_log" \
    --label "devicehub-$action" \
    --timeout "$timeout" \
    -- "$xcodebuild_command" "$xcodebuild_action" \
    -resultBundlePath "$result_bundle" "$@"; then
    status=0
  else
    status=$?
  fi

  if (( status != 0 )); then
    printf 'XCODEBUILD_FAILED action=%s xcodebuild_exit=%s raw_log=%s result_bundle=%s\n' \
      "$action" "$status" "$raw_log" "$result_bundle" >&2
    return "$status"
  fi
  if [[ ! -d "$result_bundle" ]]; then
    printf 'XCODEBUILD_RESULT_MISSING action=%s raw_log=%s result_bundle=%s\n' \
      "$action" "$raw_log" "$result_bundle" >&2
    return 1
  fi

  printf 'XCODEBUILD_OK action=%s raw_log=%s result_bundle=%s\n' \
    "$action" "$raw_log" "$result_bundle" >&2
}
