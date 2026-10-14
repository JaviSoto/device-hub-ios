#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard full-ci 3600 "$0" "$@"

RELEASE_DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/DeviceHub}"

cd "$ROOT"

if [[ -z "${CI:-}" && "${DEVICE_HUB_FULL_CI:-0}" != "1" ]]; then
  CI_SCOPE="$(python3 BuildSupport/ci_scope.py --repository "$ROOT")"
  if [[ "$CI_SCOPE" == "documentation" ]]; then
    git diff --check
    printf 'Device Hub documentation checks passed. Set DEVICE_HUB_FULL_CI=1 to run every gate.\n'
    exit 0
  fi
fi

export DERIVED_DATA_PATH="$RELEASE_DERIVED_DATA_PATH"

# mise closes inherited file descriptors before it starts a task. Keep the
# outer full-CI guard, but make each nested guarded task acquire a separate
# lock instead of trusting the descriptor that mise cannot preserve.
NESTED_GUARD_LOCK_PATH="${TMPDIR:-/private/tmp}/device-hub-ios-full-ci-nested.$$.lock"
trap 'rm -f "$NESTED_GUARD_LOCK_PATH"' EXIT
run_ci_task() {
  DEVICE_HUB_GUARD_HELD=0 \
    DEVICE_HUB_GUARD_FD='' \
    DEVICE_HUB_GUARD_LOCK_PATH="$NESTED_GUARD_LOCK_PATH" \
    mise run "$@"
}

run_ci_task test
run_ci_task protocol:verify
run_ci_task lint
run_ci_task previews

CONFIGURATION=Release \
CODE_SIGNING_ALLOWED=NO \
DERIVED_DATA_PATH="$RELEASE_DERIVED_DATA_PATH" \
  run_ci_task build

printf 'Device Hub CI passed.\n'
