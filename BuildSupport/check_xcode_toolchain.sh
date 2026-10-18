#!/usr/bin/env bash

devicehub_check_xcode_toolchain() {
  local shared_support="${SHARED_IOS_SUPPORT_DIR:-$HOME/code/ios-build-support}"
  local checker="$shared_support/scripts/check_xcode_toolchain.py"
  if [[ ! -r "$checker" ]]; then
    printf 'Missing shared Xcode toolchain check: %s\n' "$checker" >&2
    return 1
  fi
  python3 "$checker" --minimum-xcode 27.1 --minimum-ios-sdk 27.1
}

is_ios_271_or_later() {
  if (( $# != 1 )) || [[ ! "$1" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)*$ ]]; then
    return 1
  fi

  local major=$((10#${BASH_REMATCH[1]}))
  local minor=$((10#${BASH_REMATCH[2]}))
  (( major > 27 || (major == 27 && minor >= 1) ))
}
