#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPA="${1:-}"
shift || true
RELEASE_NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-notes-file)
      [[ $# -ge 2 ]] || { echo "--release-notes-file requires a path" >&2; exit 64; }
      RELEASE_NOTES_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

API_BASE_URL="https://api.builds.lan"
UPLOAD_CLIENT="${BUILDS_LAN_UPLOAD_CLIENT:-/Volumes/RunnerCache/code/builds-native/Scripts/upload-builds-lan-api.py}"
UPLOAD_TOKEN_FILE="${BUILDS_LAN_UPLOAD_TOKEN_FILE:-}"
CODEX_SECRET_BIN="${CODEX_SECRET_BIN:-$HOME/.local/bin/codex-secret}"
MANIFEST="${MANIFEST:-}"

if [[ -z "$IPA" || ! -f "$IPA" ]]; then
  echo "Usage: $0 /absolute/path/DeviceHub.ipa --release-notes-file /absolute/path/notes.md" >&2
  exit 64
fi
if [[ -z "$RELEASE_NOTES_FILE" || ! -r "$RELEASE_NOTES_FILE" ]]; then
  echo "Release notes file is missing or unreadable: $RELEASE_NOTES_FILE" >&2
  exit 1
fi
if ! LC_ALL=C grep -q '[^[:space:]]' "$RELEASE_NOTES_FILE"; then
  echo "Release notes must contain non-whitespace text." >&2
  exit 1
fi
if [[ ! -r "$UPLOAD_CLIENT" ]]; then
  echo "Canonical Builds.lan upload client is missing: $UPLOAD_CLIENT" >&2
  exit 1
fi
if [[ -n "$UPLOAD_TOKEN_FILE" ]]; then
  if [[ ! -f "$UPLOAD_TOKEN_FILE" || "$(stat -f '%Lp' "$UPLOAD_TOKEN_FILE")" != 600 ]]; then
    echo "Builds.lan upload token must be a mode-0600 file: $UPLOAD_TOKEN_FILE" >&2
    exit 1
  fi
elif [[ ! -x "$CODEX_SECRET_BIN" ]]; then
  echo "The codex-secret runner is missing or not executable: $CODEX_SECRET_BIN" >&2
  exit 1
fi

IPA="$(cd "$(dirname "$IPA")" && printf '%s/%s\n' "$PWD" "$(basename "$IPA")")"
IPA_DIR="$(dirname "$IPA")"
MANIFEST="${MANIFEST:-$IPA_DIR/manifest.plist}"
if [[ ! -f "$MANIFEST" ]]; then
  echo "iOS publication requires an export manifest beside the IPA: $MANIFEST" >&2
  exit 1
fi
if [[ ! -s "$IPA_DIR/version.txt" || ! -s "$IPA_DIR/source-revision.txt" ]]; then
  echo "IPA provenance files are missing beside $IPA." >&2
  exit 1
fi

cd "$ROOT"
if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "Builds.lan publication requires a clean Git worktree." >&2
  git status --short >&2
  exit 2
fi
CURRENT_REVISION="$(git rev-parse --verify HEAD)"
ARTIFACT_REVISION="$(tr -d '\r\n' < "$IPA_DIR/source-revision.txt")"
if [[ "$ARTIFACT_REVISION" != "$CURRENT_REVISION" ]]; then
  echo "IPA source revision does not match the current commit." >&2
  exit 2
fi

python3 - "$IPA" "$IPA_DIR/version.txt" "$ARTIFACT_REVISION" <<'PY'
from __future__ import annotations

import plistlib
import sys
from pathlib import Path
from zipfile import ZipFile

ipa = Path(sys.argv[1])
version_file = Path(sys.argv[2])
source_revision = sys.argv[3]
version, build = version_file.read_text(encoding="utf-8").splitlines()
with ZipFile(ipa) as archive:
    info_name = next(
        name for name in archive.namelist() if name.endswith(".app/Info.plist")
    )
    info = plistlib.loads(archive.read(info_name))
expected = {
    "CFBundleIdentifier": "es.javisoto.DeviceHub",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "CFBundleSourceRevision": source_revision,
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"IPA metadata mismatch for {key}: {info.get(key)!r}")
PY

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/device-hub-publication.XXXXXX")"
cleanup() { rm -rf "$VERIFY_DIR"; }
trap cleanup EXIT

UPLOAD_ARGUMENTS=(
  --api-url "$API_BASE_URL" \
  --platform ios \
  --artifact "$IPA" \
  --manifest "$MANIFEST" \
  --release-notes-file "$RELEASE_NOTES_FILE" \
  --app-name "Device Hub" \
  --title "Device Hub for iPhone and iPad" \
  --channel adhoc
)
if [[ -n "$UPLOAD_TOKEN_FILE" ]]; then
  python3 "$UPLOAD_CLIENT" \
    "${UPLOAD_ARGUMENTS[@]}" \
    --token-file "$UPLOAD_TOKEN_FILE" \
    > "$VERIFY_DIR/api-response.json"
else
  CODEX_AGENT=1 "$CODEX_SECRET_BIN" run builds_lan_upload_access -- \
    python3 "$UPLOAD_CLIENT" \
    "${UPLOAD_ARGUMENTS[@]}" \
    > "$VERIFY_DIR/api-response.json"
fi

python3 - "$VERIFY_DIR/api-response.json" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

publication = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(publication, dict):
    raise SystemExit("Builds.lan uploader returned no publication object")
if publication.get("platform") != "ios":
    raise SystemExit("Builds.lan uploader returned a non-iOS publication")
if publication.get("bundle_id") != "es.javisoto.DeviceHub":
    raise SystemExit("Builds.lan uploader returned a different app")
build = publication.get("build")
if not isinstance(build, dict) or not publication.get("icon_url"):
    raise SystemExit("Builds.lan publication is missing build or icon metadata")
for key in ("ipa_url", "manifest_url"):
    if not isinstance(build.get(key), str) or not build[key].startswith("https://builds.lan/"):
        raise SystemExit(f"Builds.lan publication has an invalid {key}")
if not publication["icon_url"].startswith("https://builds.lan/"):
    raise SystemExit("Builds.lan publication has an invalid icon URL")
Path(sys.argv[1]).replace(Path(sys.argv[1]).with_name("publication.json"))
PY

# The API is the catalog source for both the website and native clients. Read
# that exact endpoint after upload and prove the publication is visible there.
curl --fail --silent --show-error --output "$VERIFY_DIR/catalog.json" \
  "$API_BASE_URL/v1/catalog"
python3 - "$VERIFY_DIR/publication.json" "$VERIFY_DIR/catalog.json" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

publication = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
catalog = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
expected = publication.get("build") or {}
for app in catalog.get("apps", []):
    if not isinstance(app, dict) or app.get("bundle_id") != publication.get("bundle_id"):
        continue
    for build in app.get("builds", []):
        if isinstance(build, dict) and build.get("sha256") == expected.get("sha256"):
            print("Builds.lan catalog contains the published Device Hub build")
            raise SystemExit(0)
raise SystemExit("published Device Hub build is missing from the canonical catalog")
PY

printf '%s\n' "$API_BASE_URL/v1/catalog"
