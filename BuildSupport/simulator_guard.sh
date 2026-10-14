#!/usr/bin/env bash

# Own one fresh simulator per test run. On home Macs simulator_setup.py applies
# and verifies the shared SimSlim profile; hosted runners use exact direct
# lifecycle commands when SimSlim and its home profile are both absent.
devicehub_require_simulator() {
  if (( $# != 1 )); then
    printf 'simulator task name is required.\n' >&2
    return 2
  fi
  local task_name="$1"

  if [[ -n "${DEVICE_HUB_SIMULATOR_UDID:-}" ]]; then
    if [[ "${DEVICE_HUB_SIMULATOR_SETUP_MODE:-}" != "task" ||
      -z "${DEVICE_HUB_SIMULATOR_NAME:-}" ]]; then
      printf 'Inherited simulator state has no valid task ownership.\n' >&2
      return 125
    fi
    python3 "$ROOT/BuildSupport/simulator_setup.py" validate-task \
      --udid "$DEVICE_HUB_SIMULATOR_UDID" \
      --name "$DEVICE_HUB_SIMULATOR_NAME"
    return
  fi

  local setup_output
  setup_output="$(
    python3 "$ROOT/BuildSupport/simulator_setup.py" prepare --name "$task_name"
  )"
  IFS=$'\t' read -r DEVICE_HUB_SIMULATOR_UDID DEVICE_HUB_SIMULATOR_CREATED \
    DEVICE_HUB_SIMULATOR_NAME <<<"$setup_output"
  if [[ -z "$DEVICE_HUB_SIMULATOR_UDID" ||
    -z "$DEVICE_HUB_SIMULATOR_NAME" ]]; then
    printf 'Simulator setup did not return a complete task-owned device.\n' >&2
    return 125
  fi
  export DEVICE_HUB_SIMULATOR_UDID
  export DEVICE_HUB_SIMULATOR_CREATED
  export DEVICE_HUB_SIMULATOR_NAME
  DEVICE_HUB_SIMULATOR_SETUP_MODE="task"
  export DEVICE_HUB_SIMULATOR_SETUP_MODE
  # Deliberately not exported: only the process that created the device owns
  # its final cleanup. Nested test scripts may validate and use it, not delete it.
  DEVICE_HUB_SIMULATOR_CLEANUP_REQUIRED=1
}

devicehub_cleanup_simulator() {
  if [[ "${DEVICE_HUB_SIMULATOR_CLEANUP_REQUIRED:-0}" != "1" ||
    "${DEVICE_HUB_SIMULATOR_SETUP_MODE:-}" != "task" ]]; then
    return 0
  fi
  python3 "$ROOT/BuildSupport/simulator_setup.py" cleanup \
    --udid "${DEVICE_HUB_SIMULATOR_UDID:?simulator identifier missing}" \
    --name "${DEVICE_HUB_SIMULATOR_NAME:?simulator name missing}"
  DEVICE_HUB_SIMULATOR_CLEANUP_REQUIRED=0
}
