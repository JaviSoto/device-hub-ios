#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard full-ci 3600 "$0" "$@"

RELEASE_DERIVED_DATA_PATH="$(
  mktemp -d "${TMPDIR:-/private/tmp}/device-hub-release.XXXXXX"
)"
cleanup() {
  rm -rf "$RELEASE_DERIVED_DATA_PATH"
}
trap cleanup EXIT

cd "$ROOT"

if [[ -z "${CI:-}" && "${DEVICE_HUB_FULL_CI:-0}" != "1" ]]; then
  CI_SCOPE="$(python3 BuildSupport/ci_scope.py --repository "$ROOT")"
  if [[ "$CI_SCOPE" == "documentation" ]]; then
    git diff --check
    printf 'Device Hub documentation checks passed. Set DEVICE_HUB_FULL_CI=1 to run every gate.\n'
    exit 0
  fi
fi

mise run test
mise run protocol:verify
mise run lint
mise run previews

CONFIGURATION=Release \
CODE_SIGNING_ALLOWED=NO \
DERIVED_DATA_PATH="$RELEASE_DERIVED_DATA_PATH" \
  mise run build

printf 'Device Hub CI passed.\n'
