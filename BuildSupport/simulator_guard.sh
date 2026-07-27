#!/usr/bin/env bash

# Route local agent work through the host-wide simulator supervisor. Isolated
# environments without that supervisor use one stable, exact simulator name
# and verified teardown instead of accumulating per-process devices.
devicehub_require_simulator() {
  local lease_name="${1:?lease name required}"
  local timeout_seconds="${2:?timeout required}"
  local script_path="${3:?script path required}"
  shift 3

  if [[ -n "${DEVICE_HUB_SIMULATOR_UDID:-}" ]]; then
    DEVICE_HUB_SIMULATOR_CLEANUP_REQUIRED=0
    case "${DEVICE_HUB_SIMULATOR_SETUP_MODE:-}" in
      shared)
        python3 "$ROOT/BuildSupport/simulator_setup.py" validate-shared \
          --udid "$DEVICE_HUB_SIMULATOR_UDID"
        return
        ;;
      direct)
        return
        ;;
      *)
        printf 'Inherited simulator state has no valid ownership mode.\n' >&2
        return 125
        ;;
    esac
  fi

  local shared_supervisor=""
  if [[ -n "${CODEX_SIMULATOR_LEASE_ID:-}" ]]; then
    shared_supervisor="${CODEX_SIMULATOR_LEASE_COMMAND:?lease command missing}"
  elif command -v codex-simulator-lease >/dev/null 2>&1; then
    shared_supervisor="$(command -v codex-simulator-lease)"
  elif [[ "${CODEX_AGENT:-0}" == "1" ]]; then
    printf 'codex-simulator-lease is required for agent-driven simulator work.\n' >&2
    return 125
  fi

  if [[ -n "$shared_supervisor" && -z "${CODEX_SIMULATOR_LEASE_ID:-}" ]]; then
    unset DEVICE_HUB_SIMULATOR_UDID
    exec "$shared_supervisor" run \
      --name "$lease_name" \
      --timeout-seconds "$timeout_seconds" \
      -- "$script_path" "$@"
  fi

  local setup_mode="direct"
  if [[ -n "${CODEX_SIMULATOR_LEASE_ID:-}" ]]; then
    setup_mode="shared"
  fi
  local setup_output
  setup_output="$(
    python3 "$ROOT/BuildSupport/simulator_setup.py" prepare --mode "$setup_mode"
  )"
  read -r DEVICE_HUB_SIMULATOR_UDID DEVICE_HUB_SIMULATOR_CREATED \
    <<<"$setup_output"
  if [[ -z "$DEVICE_HUB_SIMULATOR_UDID" ]]; then
    printf 'Simulator setup did not return a device identifier.\n' >&2
    return 125
  fi
  export DEVICE_HUB_SIMULATOR_UDID
  export DEVICE_HUB_SIMULATOR_CREATED
  DEVICE_HUB_SIMULATOR_SETUP_MODE="$setup_mode"
  export DEVICE_HUB_SIMULATOR_SETUP_MODE
  DEVICE_HUB_SIMULATOR_CLEANUP_REQUIRED=1
}

devicehub_cleanup_simulator() {
  if [[ "${DEVICE_HUB_SIMULATOR_CLEANUP_REQUIRED:-0}" != "1" ||
    "${DEVICE_HUB_SIMULATOR_SETUP_MODE:-}" != "direct" ]]; then
    return 0
  fi
  local created_flag=()
  if [[ "${DEVICE_HUB_SIMULATOR_CREATED:-0}" == "1" ]]; then
    created_flag=(--created)
  fi
  python3 "$ROOT/BuildSupport/simulator_setup.py" cleanup \
    --udid "${DEVICE_HUB_SIMULATOR_UDID:?simulator identifier missing}" \
    "${created_flag[@]}"
}
