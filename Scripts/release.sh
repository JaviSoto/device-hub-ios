#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

if [[ -z "$RELEASE_NOTES_FILE" ]]; then
  echo "Usage: $0 --release-notes-file /absolute/path/release-notes.md" >&2
  exit 64
fi
if [[ ! -r "$RELEASE_NOTES_FILE" ]]; then
  echo "Release notes file is missing or unreadable: $RELEASE_NOTES_FILE" >&2
  exit 1
fi

IPA_PATH="$("$ROOT/Scripts/build-device-ipa.sh")"
"$ROOT/Scripts/publish-builds-lan.sh" \
  "$IPA_PATH" \
  --release-notes-file "$RELEASE_NOTES_FILE"
