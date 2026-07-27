#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"
shell_files=()
while IFS= read -r shell_file; do
  shell_files+=("$shell_file")
done < <(rg --files -g '*.sh' | sort)
if (( ${#shell_files[@]} == 0 )); then
  printf 'No shell scripts found.\n'
  exit 0
fi

bash -n "${shell_files[@]}"
shellcheck -x "${shell_files[@]}"
