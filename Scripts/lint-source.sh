#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard lint-source 900 "$0" "$@"

cd "$ROOT"
swiftformat Packages Sources Tools --config .swiftformat --lint
swiftlint lint --config .swiftlint.yml --strict
jscpd --config jscpd.json \
  Packages/DeviceHubKit/Sources \
  Sources \
  Tools/DeviceHubPreviewRenderer/Sources
xcodegen generate
