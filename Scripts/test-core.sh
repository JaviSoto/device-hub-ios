#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard test-core 900 "$0" "$@"

SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-}"
TEST_ARGUMENTS=(--package-path "$ROOT/Packages/DeviceHubKit")

if [[ -n "$SCRATCH_PATH" ]]; then
  TEST_ARGUMENTS+=(--scratch-path "$SCRATCH_PATH")
fi

swift test "${TEST_ARGUMENTS[@]}"
