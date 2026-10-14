#!/usr/bin/env bash

# Validate the existing macOS login keychain without handling its password or
# changing lock, timeout, default, search-list, or item-access policy.
devicehub_validate_signing_keychain() {
  local keychain_path="${1:?keychain path required}"
  local identity_output

  if [[ "$keychain_path" != "$HOME/Library/Keychains/login.keychain-db" ]]; then
    echo "Signing helpers only use the existing login keychain: $keychain_path" >&2
    return 1
  fi

  if [[ ! -f "$keychain_path" ]]; then
    echo "Signing keychain does not exist: $keychain_path" >&2
    return 1
  fi
  if ! identity_output="$(/usr/bin/security find-identity -v -p codesigning "$keychain_path")"; then
    echo "Unable to read signing identities from $keychain_path" >&2
    return 1
  fi

  if ! grep -Eq '[[:space:]][1-9][0-9]* valid identities found$' <<<"$identity_output"; then
    echo "No usable code-signing identity found in $keychain_path" >&2
    printf '%s\n' "$identity_output" >&2
    return 1
  fi
}
