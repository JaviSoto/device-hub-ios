#!/usr/bin/env bash

# Re-execute a heavyweight repository entry point under the shared process
# guard. Nested scripts must prove ownership through the inherited locked file
# descriptor rather than trusting a forgeable environment bit.
devicehub_require_guard() {
  local operation_name="${1:?operation name required}"
  local timeout_seconds="${2:?timeout required}"
  local script_path="${3:?script path required}"
  shift 3

  local support_directory
  local guard_directory
  local repository_root
  local lock_path
  support_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repository_root="$(cd "$support_directory/.." && pwd)"
  guard_directory="${TMPDIR:-/tmp}"
  lock_path="${DEVICE_HUB_GUARD_LOCK_PATH:-${guard_directory%/}/device-hub-ios-process-guard.lock}"

  if [[ "${DEVICE_HUB_GUARD_HELD:-0}" == "1" ]] \
    && python3 "$repository_root/BuildSupport/guarded_process.py" \
      --validate-inherited-lock \
      --lock-path "$lock_path" >/dev/null 2>&1; then
    return 0
  fi

  exec "$repository_root/Scripts/guarded-run.sh" \
    --name "$operation_name" \
    --timeout-seconds "$timeout_seconds" \
    -- \
    bash "$script_path" "$@"
}
