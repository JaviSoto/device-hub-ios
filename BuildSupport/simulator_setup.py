#!/usr/bin/env python3
"""Prepare one managed iOS simulator inside an approved lifecycle boundary."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass

XCRUN = "/usr/bin/xcrun"
MANAGED_SIMULATOR_NAME = "Device Hub Tests - Codex iPhone 17 Pro"
IDENTIFIER_PATTERN = re.compile(
    r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
)
CommandRunner = Callable[[tuple[str, ...], bool], str]


class SimulatorSetupError(RuntimeError):
    """Raised when exact simulator ownership cannot be established."""


class CommandError(SimulatorSetupError):
    """Raised when a bounded lifecycle command fails."""


@dataclass(frozen=True)
class SimulatorDevice:
    """The bounded device identity needed by the setup transaction."""

    identifier: str
    name: str
    state: str


@dataclass(frozen=True)
class PreparedSimulator:
    """The simulator selected by setup and whether this invocation created it."""

    identifier: str
    created: bool


def validate_identifier(value: object) -> str:
    """Return one canonical CoreSimulator identifier or fail closed."""

    if not isinstance(value, str) or IDENTIFIER_PATTERN.fullmatch(value) is None:
        raise SimulatorSetupError("simulator identifier is invalid")
    return value


def subprocess_command(arguments: tuple[str, ...], check: bool = True) -> str:
    """Run one bounded command and return its standard output."""

    try:
        result = subprocess.run(
            arguments,
            check=check,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise CommandError(f"command failed: {arguments[0]} {arguments[1]}") from error
    return result.stdout.strip()


def json_command(
    run_command: CommandRunner,
    arguments: tuple[str, ...],
) -> object:
    """Decode one bounded command response as JSON."""

    try:
        return json.loads(run_command(arguments, True))
    except json.JSONDecodeError as error:
        raise SimulatorSetupError("simctl returned malformed JSON") from error


def simulator_inventory(run_command: CommandRunner) -> tuple[SimulatorDevice, ...]:
    """Return available simulators using only exact identity fields."""

    payload = json_command(
        run_command,
        (XCRUN, "simctl", "list", "devices", "available", "--json"),
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("devices"), dict):
        raise SimulatorSetupError("simctl device inventory is malformed")
    devices: list[SimulatorDevice] = []
    for runtime_devices in payload["devices"].values():
        if not isinstance(runtime_devices, list):
            raise SimulatorSetupError("simctl runtime device inventory is malformed")
        for raw_device in runtime_devices:
            if not isinstance(raw_device, dict):
                raise SimulatorSetupError("simctl device entry is malformed")
            if raw_device.get("isAvailable", True) is not True:
                continue
            name = raw_device.get("name")
            state = raw_device.get("state")
            if not isinstance(name, str) or not isinstance(state, str):
                raise SimulatorSetupError("simctl device identity is malformed")
            devices.append(
                SimulatorDevice(
                    identifier=validate_identifier(raw_device.get("udid")),
                    name=name,
                    state=state,
                )
            )
    return tuple(devices)


def managed_simulator(run_command: CommandRunner) -> SimulatorDevice | None:
    """Find at most one exact managed simulator, rejecting ambiguity."""

    matches = tuple(
        device
        for device in simulator_inventory(run_command)
        if device.name == MANAGED_SIMULATOR_NAME
    )
    if len(matches) > 1:
        raise SimulatorSetupError(
            "managed simulator name did not resolve to exactly one device"
        )
    return matches[0] if matches else None


def runtime_identifier(run_command: CommandRunner) -> str:
    """Select the newest available iOS 27 runtime deterministically."""

    payload = json_command(
        run_command,
        (XCRUN, "simctl", "list", "runtimes", "--json"),
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("runtimes"), list):
        raise SimulatorSetupError("simctl runtime inventory is malformed")
    candidates = tuple(
        runtime["identifier"]
        for runtime in payload["runtimes"]
        if isinstance(runtime, dict)
        and runtime.get("isAvailable") is True
        and isinstance(runtime.get("identifier"), str)
        and runtime["identifier"].startswith(
            "com.apple.CoreSimulator.SimRuntime.iOS-27-"
        )
    )
    if not candidates:
        raise SimulatorSetupError("no available iOS 27 simulator runtime")
    return max(
        candidates,
        key=lambda identifier: tuple(
            int(component)
            for component in identifier.rsplit("iOS-", maxsplit=1)[-1].split("-")
        ),
    )


def device_type_identifier(run_command: CommandRunner) -> str:
    """Select iPhone 17 Pro, or the newest available iPhone device type."""

    payload = json_command(
        run_command,
        (XCRUN, "simctl", "list", "devicetypes", "--json"),
    )
    if not isinstance(payload, dict) or not isinstance(
        payload.get("devicetypes"), list
    ):
        raise SimulatorSetupError("simctl device-type inventory is malformed")
    candidates = tuple(
        device
        for device in payload["devicetypes"]
        if isinstance(device, dict)
        and isinstance(device.get("name"), str)
        and device["name"].startswith("iPhone ")
        and isinstance(device.get("identifier"), str)
    )
    preferred = next(
        (device for device in candidates if device["name"] == "iPhone 17 Pro"),
        None,
    )
    selected = preferred or (candidates[-1] if candidates else None)
    if selected is None:
        raise SimulatorSetupError("no iPhone simulator device type")
    return selected["identifier"]


def select_or_create_simulator(
    run_command: CommandRunner,
) -> PreparedSimulator:
    """Reuse one exact managed device or create and verify it once."""

    existing = managed_simulator(run_command)
    if existing is not None:
        return PreparedSimulator(identifier=existing.identifier, created=False)
    identifier = validate_identifier(
        run_command(
            (
                XCRUN,
                "simctl",
                "create",
                MANAGED_SIMULATOR_NAME,
                device_type_identifier(run_command),
                runtime_identifier(run_command),
            ),
            True,
        ).strip()
    )
    created = tuple(
        device
        for device in simulator_inventory(run_command)
        if device.identifier == identifier and device.name == MANAGED_SIMULATOR_NAME
    )
    if len(created) != 1:
        remove_unregistered_creation(run_command, identifier)
        raise SimulatorSetupError(
            "created simulator UUID and managed name could not be verified"
        )
    return PreparedSimulator(identifier=identifier, created=True)


def remove_unregistered_creation(
    run_command: CommandRunner,
    identifier: str,
) -> None:
    """Remove the exact new device if supervisor registration failed."""

    run_command((XCRUN, "simctl", "shutdown", identifier), False)
    run_command((XCRUN, "simctl", "delete", identifier), True)
    deadline = time.monotonic() + 5
    while any(
        device.identifier == identifier for device in simulator_inventory(run_command)
    ):
        if time.monotonic() >= deadline:
            raise SimulatorSetupError(
                "unregistered simulator could not be proven absent"
            )
        time.sleep(0.05)


def shared_lease_command(environment: Mapping[str, str]) -> str:
    """Validate the authoritative supervisor environment."""

    if not environment.get("CODEX_SIMULATOR_LEASE_ID"):
        raise SimulatorSetupError("shared simulator lease identity is missing")
    command = environment.get("CODEX_SIMULATOR_LEASE_COMMAND")
    if not command or not os.path.isabs(command):
        raise SimulatorSetupError("shared simulator lease command is invalid")
    return command


def prepare_shared_simulator(
    *,
    environment: Mapping[str, str],
    run_command: CommandRunner = subprocess_command,
) -> PreparedSimulator:
    """Register and boot one device through the shared host supervisor."""

    lease_command = shared_lease_command(environment)
    prepared = select_or_create_simulator(run_command)
    register = (
        lease_command,
        "register",
        "--udid",
        prepared.identifier,
        "--name",
        MANAGED_SIMULATOR_NAME,
    )
    if prepared.created:
        register = (*register, "--created")
    try:
        run_command(register, True)
    except Exception:
        if prepared.created:
            remove_unregistered_creation(run_command, prepared.identifier)
        raise
    run_command(
        (lease_command, "boot", "--udid", prepared.identifier),
        True,
    )
    return prepared


def prepare_simulator(
    *,
    environment: Mapping[str, str],
    run_command: CommandRunner = subprocess_command,
) -> str:
    """Compatibility entry point returning the shared simulator UUID."""

    return prepare_shared_simulator(
        environment=environment,
        run_command=run_command,
    ).identifier


def validate_shared_simulator(
    identifier: str,
    *,
    environment: Mapping[str, str],
    run_command: CommandRunner = subprocess_command,
) -> None:
    """Prove an inherited UUID is the shared supervisor's active device."""

    identifier = validate_identifier(identifier)
    lease_command = shared_lease_command(environment)
    payload = json_command(
        run_command,
        (lease_command, "status", "--json"),
    )
    if (
        not isinstance(payload, dict)
        or payload.get("active") is not True
        or payload.get("active_udid") != identifier
    ):
        raise SimulatorSetupError(
            "inherited simulator is not active in the shared lease"
        )


def prepare_direct_simulator(
    *,
    run_command: CommandRunner = subprocess_command,
) -> PreparedSimulator:
    """Prepare a simulator on an isolated host without the shared supervisor."""

    prepared = select_or_create_simulator(run_command)
    run_command((XCRUN, "simctl", "boot", prepared.identifier), False)
    run_command((XCRUN, "simctl", "bootstatus", prepared.identifier, "-b"), True)
    return prepared


def wait_until_shutdown_or_absent(
    identifier: str,
    *,
    run_command: CommandRunner,
) -> None:
    """Prove that the exact direct-mode simulator is no longer booted."""

    deadline = time.monotonic() + 5
    while True:
        matching = tuple(
            device
            for device in simulator_inventory(run_command)
            if device.identifier == identifier
        )
        if not matching or (len(matching) == 1 and matching[0].state == "Shutdown"):
            return
        if time.monotonic() >= deadline:
            raise SimulatorSetupError("simulator could not be proven shut down")
        time.sleep(0.05)


def cleanup_direct_simulator(
    identifier: str,
    *,
    created: bool,
    run_command: CommandRunner = subprocess_command,
) -> None:
    """Shutdown one direct-mode device and delete it only when newly created."""

    identifier = validate_identifier(identifier)
    run_command((XCRUN, "simctl", "shutdown", identifier), False)
    wait_until_shutdown_or_absent(identifier, run_command=run_command)
    if not created:
        return
    run_command((XCRUN, "simctl", "delete", identifier), True)
    deadline = time.monotonic() + 5
    while any(
        device.identifier == identifier for device in simulator_inventory(run_command)
    ):
        if time.monotonic() >= deadline:
            raise SimulatorSetupError("created simulator could not be proven absent")
        time.sleep(0.05)


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    """Parse the small simulator setup CLI."""

    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--mode", choices=("shared", "direct"), required=True)
    validate = subparsers.add_parser("validate-shared")
    validate.add_argument("--udid", required=True)
    cleanup = subparsers.add_parser("cleanup")
    cleanup.add_argument("--udid", required=True)
    cleanup.add_argument("--created", action="store_true")
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    """Prepare or clean one simulator for the shell harness."""

    namespace = parse_arguments(sys.argv[1:] if arguments is None else arguments)
    try:
        if namespace.operation == "prepare":
            prepared = (
                prepare_shared_simulator(environment=os.environ)
                if namespace.mode == "shared"
                else prepare_direct_simulator()
            )
            print(f"{prepared.identifier} {int(prepared.created)}")
        elif namespace.operation == "validate-shared":
            validate_shared_simulator(
                namespace.udid,
                environment=os.environ,
            )
        else:
            cleanup_direct_simulator(
                namespace.udid,
                created=namespace.created,
            )
    except (OSError, SimulatorSetupError, subprocess.SubprocessError) as error:
        print(f"Could not safely prepare the simulator: {error}", file=sys.stderr)
        return 125
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
