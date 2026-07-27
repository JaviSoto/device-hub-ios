#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_DIRECTORY="${TMPDIR:-/tmp}"
LOCK_PATH="${DEVICE_HUB_GUARD_LOCK_PATH:-${GUARD_DIRECTORY%/}/device-hub-ios-process-guard.lock}"

exec python3 "$ROOT/BuildSupport/guarded_process.py" \
  --lock-path "$LOCK_PATH" \
  "$@"
