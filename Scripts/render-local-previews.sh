#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard render-local-previews 1200 "$0" "$@"

RENDERER_PACKAGE="$ROOT/Tools/DeviceHubPreviewRenderer"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$ROOT/PreviewArtifacts/local-$STAMP}"
RENDERER_PRODUCT="${PREVIEW_RENDERER_PRODUCT:-DeviceHubPreviewRenderer}"
RUN_STARTED_AT="$(python3 -c 'from datetime import datetime; print(datetime.now().astimezone().isoformat(timespec="seconds"))')"

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
export DEVELOPER_DIR

source_digest() {
  python3 - "$ROOT" <<'PY'
from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
inputs = [
    root / "Packages/DeviceHubKit/Package.swift",
    root / "Packages/DeviceHubKit/Package.resolved",
    root / "Packages/DeviceHubKit/Sources",
    root / "Tools/DeviceHubPreviewRenderer/Package.swift",
    root / "Tools/DeviceHubPreviewRenderer/Package.resolved",
    root / "Tools/DeviceHubPreviewRenderer/Sources",
    root / "Tools/DeviceHubPreviewRenderer/Tests",
    root / "Scripts/render-local-previews.sh",
]
files: list[Path] = []
for item in inputs:
    if item.is_dir():
        files.extend(path for path in item.rglob("*") if path.is_file() or path.is_symlink())
    elif item.exists() or item.is_symlink():
        files.append(item)

digest = hashlib.sha256()
for path in sorted(files):
    relative = path.relative_to(root)
    digest.update(os.fsencode(str(relative)))
    digest.update(b"\0")
    if path.is_symlink():
        digest.update(b"symlink\0")
        digest.update(os.fsencode(os.readlink(path)))
    else:
        digest.update(f"{path.stat().st_mode & 0o777:o}".encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
    digest.update(b"\0")
print(digest.hexdigest())
PY
}

SOURCE_HEAD="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || printf 'unborn')"
SOURCE_DIGEST="$(source_digest)"

if [[ "$OUT_DIR" != /* ]]; then
  OUT_DIR="$ROOT/$OUT_DIR"
fi

OUT_PARENT="$(dirname "$OUT_DIR")"
OUT_NAME="$(basename "$OUT_DIR")"
mkdir -p "$OUT_PARENT"
STAGING_DIR="$(mktemp -d "$OUT_PARENT/.${OUT_NAME}.staging.XXXXXX")"
PREVIOUS_DIR="$OUT_PARENT/.${OUT_NAME}.previous.$$"

cleanup() {
  if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR"
  fi
  if [[ -d "$PREVIOUS_DIR" && ! -e "$OUT_DIR" ]]; then
    mv "$PREVIOUS_DIR" "$OUT_DIR"
  fi
}
trap cleanup EXIT

SWIFT_RUN_ARGUMENTS=(
  --package-path "$RENDERER_PACKAGE"
  --disable-prefetching
  --force-resolved-versions
)
if [[ -n "${PREVIEW_SCRATCH_PATH:-}" ]]; then
  SWIFT_RUN_ARGUMENTS+=(--scratch-path "$PREVIEW_SCRATCH_PATH")
fi

swift test "${SWIFT_RUN_ARGUMENTS[@]}"
swift run "${SWIFT_RUN_ARGUMENTS[@]}" \
  "$RENDERER_PRODUCT" \
  --output "$STAGING_DIR"
swift run "${SWIFT_RUN_ARGUMENTS[@]}" \
  "$RENDERER_PRODUCT" \
  --list-json \
  --output "$STAGING_DIR" > "$STAGING_DIR/renderer-catalog.json"

python3 - "$STAGING_DIR" "$RUN_STARTED_AT" "$SOURCE_HEAD" "$SOURCE_DIGEST" <<'PY'
from __future__ import annotations

import hashlib
import json
import struct
import sys
from pathlib import Path

output = Path(sys.argv[1])
catalog_path = output / "renderer-catalog.json"
catalog = json.loads(catalog_path.read_text())
if not isinstance(catalog, list) or not catalog:
    raise SystemExit("Preview renderer catalog must be a non-empty JSON array")

required_fields = {
    "byte_count",
    "device_class",
    "dynamic_type",
    "layout",
    "orientation",
    "path",
    "pixel_height",
    "pixel_width",
    "png_sha256",
    "remote_screen",
    "scale",
    "state",
    "surface",
    "theme",
    "viewport_height",
    "viewport_width",
}
paths = [str(item["path"]) for item in catalog]
if len(paths) != len(set(paths)):
    raise SystemExit("Preview renderer catalog contains duplicate paths")
if any(Path(path).name != path or not path.endswith(".png") for path in paths):
    raise SystemExit("Preview renderer paths must be plain PNG filenames")

expected = set(paths)
actual = {path.name for path in output.glob("*.png")}
if actual != expected:
    raise SystemExit(
        f"Preview membership mismatch: missing={sorted(expected - actual)}, "
        f"unexpected={sorted(actual - expected)}"
    )

hashes: set[str] = set()
for item in catalog:
    missing_fields = required_fields - set(item)
    if missing_fields:
        raise SystemExit(
            f"{item.get('path', '<unknown>')}: missing fields {sorted(missing_fields)}"
        )
    path = output / str(item["path"])
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) < 24:
        raise SystemExit(f"{path.name}: invalid PNG signature")
    width, height = struct.unpack(">II", data[16:24])
    expected_width = int(item["viewport_width"]) * int(item["scale"])
    expected_height = int(item["viewport_height"]) * int(item["scale"])
    if (int(item["pixel_width"]), int(item["pixel_height"])) != (
        expected_width,
        expected_height,
    ):
        raise SystemExit(f"{path.name}: inconsistent catalog dimensions")
    if (width, height) != (expected_width, expected_height):
        raise SystemExit(
            f"{path.name}: PNG dimensions {(width, height)} != "
            f"{(expected_width, expected_height)}"
        )
    if int(item["byte_count"]) != len(data):
        raise SystemExit(f"{path.name}: byte count does not match the PNG")
    digest = hashlib.sha256(data).hexdigest()
    if item["png_sha256"] != digest:
        raise SystemExit(f"{path.name}: SHA-256 does not match the PNG")
    if digest in hashes:
        raise SystemExit(f"{path.name}: duplicates another rendered artifact")
    hashes.add(digest)

states = {str(item["state"]) for item in catalog}
required_states = {
    "actionable-failure",
    "available-idle",
    "connecting",
    "live-fresh-frame",
    "pairing",
}
if not required_states.issubset(states):
    raise SystemExit(
        f"Preview renderer states are incomplete: {sorted(required_states - states)}"
    )
if {str(item["theme"]) for item in catalog} != {"dark", "light"}:
    raise SystemExit("Preview renderer must cover light and dark themes")
if {str(item["device_class"]) for item in catalog} != {"iPad", "iPhone"}:
    raise SystemExit("Preview renderer must cover iPhone and iPad")
if not any(
    item["device_class"] == "iPad"
    and item["orientation"] == "landscape"
    and item["layout"] == "two-column"
    for item in catalog
):
    raise SystemExit("Preview renderer is missing the iPad two-column surface")
if not any(item["dynamic_type"] == "accessibility3" for item in catalog):
    raise SystemExit("Preview renderer is missing accessibility Dynamic Type")
artifacts = []
surfaces = []
for item in catalog:
    artifact_id = Path(str(item["path"])).stem
    surfaces.append(
        {
            "id": artifact_id,
            "surface": item["surface"],
            "state": item["state"],
            "theme": item["theme"],
        }
    )
    artifact = dict(item)
    artifact.update(
        {
            "id": artifact_id,
            "viewport": (
                f"{item['viewport_width']}x{item['viewport_height']} "
                f"@{item['scale']}x"
            ),
            "expected_width": item["pixel_width"],
            "expected_height": item["pixel_height"],
            "bounded_component_audit": False,
            "notes": (
                f"{item['device_class']} {item['orientation']}, "
                f"{item['layout']}, Dynamic Type {item['dynamic_type']}"
            ),
        }
    )
    artifacts.append(artifact)

manifest = {
    "version": 1,
    "schema_version": 1,
    "run_started_at": sys.argv[2],
    "git_sha": sys.argv[3],
    "source": {
        "head": sys.argv[3],
        "worktree_sha256": sys.argv[4],
    },
    "renderer_catalog_sha256": hashlib.sha256(catalog_path.read_bytes()).hexdigest(),
    "surfaces": surfaces,
    "artifacts": artifacts,
}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

CURRENT_HEAD="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || printf 'unborn')"
CURRENT_DIGEST="$(source_digest)"
if [[ "$CURRENT_HEAD" != "$SOURCE_HEAD" ||
      "$CURRENT_DIGEST" != "$SOURCE_DIGEST" ]]; then
  echo "Source identity changed while previews rendered; refusing stale promotion." >&2
  exit 2
fi

if [[ -e "$OUT_DIR" ]]; then
  mv "$OUT_DIR" "$PREVIOUS_DIR"
fi
mv "$STAGING_DIR" "$OUT_DIR"
STAGING_DIR=""
rm -rf "$PREVIOUS_DIR"
trap - EXIT

printf 'Rendered deterministic previews: %s\n' "$OUT_DIR"
