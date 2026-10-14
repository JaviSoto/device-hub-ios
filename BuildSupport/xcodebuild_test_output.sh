#!/usr/bin/env bash

# Run one native XCTest command with a live summary and retained raw evidence.
devicehub_run_xcodebuild_test() {
  if (( $# < 6 )); then
    printf 'xcodebuild test output requires action, raw log, result bundle, formatter, and command.\n' >&2
    return 2
  fi

  local action="$1"
  local raw_log="$2"
  local result_bundle="$3"
  local formatter="$4"
  local xcodebuild_command="$5"
  local xcodebuild_action="$6"
  shift 6

  if ! command -v "$formatter" >/dev/null 2>&1; then
    printf 'Required test formatter is unavailable: %s\n' "$formatter" >&2
    return 127
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

  local -a statuses
  if "$xcodebuild_command" "$xcodebuild_action" \
    -resultBundlePath "$result_bundle" "$@" 2>&1 \
    | tee "$raw_log" \
    | "$formatter" --is-ci --disable-logging; then
    statuses=("${PIPESTATUS[@]}")
  else
    statuses=("${PIPESTATUS[@]}")
  fi

  if (( statuses[0] != 0 )); then
    printf 'XCODEBUILD_FAILED action=%s xcodebuild_exit=%s tee_exit=%s formatter_exit=%s raw_log=%s result_bundle=%s\n' \
      "$action" "${statuses[0]}" "${statuses[1]}" "${statuses[2]}" \
      "$raw_log" "$result_bundle" >&2
    return "${statuses[0]}"
  fi
  if (( statuses[1] != 0 )); then
    printf 'XCODEBUILD_OUTPUT_FAILED action=%s tee_exit=%s raw_log=%s result_bundle=%s\n' \
      "$action" "${statuses[1]}" "$raw_log" "$result_bundle" >&2
    return "${statuses[1]}"
  fi
  if (( statuses[2] != 0 )); then
    printf 'XCODEBUILD_FORMAT_FAILED action=%s formatter_exit=%s raw_log=%s result_bundle=%s\n' \
      "$action" "${statuses[2]}" "$raw_log" "$result_bundle" >&2
    return "${statuses[2]}"
  fi
  if [[ ! -d "$result_bundle" ]]; then
    printf 'XCODEBUILD_RESULT_MISSING action=%s raw_log=%s result_bundle=%s\n' \
      "$action" "$raw_log" "$result_bundle" >&2
    return 1
  fi

  printf 'XCODEBUILD_OK action=%s raw_log=%s result_bundle=%s\n' \
    "$action" "$raw_log" "$result_bundle" >&2
}
