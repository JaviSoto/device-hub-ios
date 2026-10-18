#!/usr/bin/env python3
"""Own one disposable simulator for a single Device Hub test run."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

XCRUN = "/usr/bin/xcrun"
SIMSLIM_PATH = "/opt/homebrew/bin/simslim"
SIMSLIM_PROFILE_PATH = Path.home() / ".config" / "simslim" / "codex.json"
IDENTIFIER_PATTERN = re.compile(
    r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
)
TASK_NAME_PATTERN = re.compile(r"[^A-Za-z0-9_-]+")
TASK_MARKER = " - Codex "
CommandRunner = Callable[[tuple[str, ...], bool], str]
SimSlimConfiguration = tuple[str, Path]


class SimulatorSetupError(RuntimeError):
    """Raised when the task cannot prove ownership of its simulator."""


class CommandError(SimulatorSetupError):
    """Raised when a bounded lifecycle command fails."""


@dataclass(frozen=True)
class SimulatorDevice:
    """The exact identity and current state returned by simctl."""

    identifier: str
    name: str
    state: str


@dataclass(frozen=True)
class PreparedSimulator:
    """The task-owned simulator created and configured by this invocation."""

    identifier: str
    name: str


@dataclass(frozen=True)
class SimulatorRuntime:
    """The selected iOS runtime and its compatible simulator device types."""

    identifier: str
    supported_device_type_identifiers: frozenset[str]


def validate_identifier(value: object) -> str:
    """Return one canonical CoreSimulator identifier or fail closed."""

    if not isinstance(value, str) or IDENTIFIER_PATTERN.fullmatch(value) is None:
        raise SimulatorSetupError("simulator identifier is invalid")
    return value


def subprocess_command(arguments: tuple[str, ...], check: bool = True) -> str:
    """Run one bounded simulator command and return its standard output."""

    operation = (
        f"simctl {arguments[2]}"
        if len(arguments) > 2 and arguments[1] == "simctl"
        else " ".join(arguments[:2])
    )
    if arguments and Path(arguments[0]).name == "simslim":
        timeout_seconds = 600 if len(arguments) > 1 and arguments[1] in {"on", "off"} else 60
    else:
        timeout_seconds = (
            180 if len(arguments) > 2 and arguments[1:3] == ("simctl", "bootstatus") else 60
        )
    try:
        result = subprocess.run(
            arguments,
            check=check,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as error:
        raise CommandError(
            f"{operation} timed out after {timeout_seconds} seconds"
        ) from error
    except subprocess.CalledProcessError as error:
        detail = " ".join((error.stderr or "").strip().split())[:500]
        suffix = f": {detail}" if detail else ""
        raise CommandError(f"{operation} failed{suffix}") from error
    except OSError as error:
        raise CommandError(f"{operation} could not start: {error}") from error
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


def select_runtime(run_command: CommandRunner) -> SimulatorRuntime:
    """Select the newest iOS 27.1+ runtime and its supported device types."""

    payload = json_command(
        run_command,
        (XCRUN, "simctl", "list", "runtimes", "--json"),
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("runtimes"), list):
        raise SimulatorSetupError("simctl runtime inventory is malformed")
    candidates: list[tuple[tuple[int, ...], str]] = []
    prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
    for runtime in payload["runtimes"]:
        if (
            not isinstance(runtime, dict)
            or runtime.get("isAvailable") is not True
            or not isinstance(runtime.get("identifier"), str)
        ):
            continue
        identifier = runtime["identifier"]
        if not identifier.startswith(prefix):
            continue
        version_components = identifier.removeprefix(prefix).split("-")
        if not all(component.isdecimal() for component in version_components):
            continue
        version = tuple(int(component) for component in version_components)
        if version[0] == 27 and version >= (27, 1):
            candidates.append((version, identifier))
    if not candidates:
        raise SimulatorSetupError("no available iOS 27.1 or later simulator runtime")
    selected_identifier = max(candidates, key=lambda candidate: candidate[0])[1]
    selected_runtime = next(
        runtime
        for runtime in payload["runtimes"]
        if isinstance(runtime, dict) and runtime.get("identifier") == selected_identifier
    )
    raw_device_types = selected_runtime.get("supportedDeviceTypes")
    if not isinstance(raw_device_types, list):
        raise SimulatorSetupError("selected iOS runtime has no supported simulator device types")
    supported_device_type_identifiers = frozenset(
        device_type["identifier"]
        for device_type in raw_device_types
        if isinstance(device_type, dict) and isinstance(device_type.get("identifier"), str)
    )
    if not supported_device_type_identifiers:
        raise SimulatorSetupError("selected iOS runtime has no supported simulator device types")
    return SimulatorRuntime(
        identifier=selected_identifier,
        supported_device_type_identifiers=supported_device_type_identifiers,
    )


def device_type_identifier(
    run_command: CommandRunner,
    supported_device_type_identifiers: frozenset[str],
    requested_name: str | None = None,
) -> str:
    """Select an exact compatible model or the preferred compatible iPhone."""

    payload = json_command(
        run_command,
        (XCRUN, "simctl", "list", "devicetypes", "--json"),
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("devicetypes"), list):
        raise SimulatorSetupError("simctl device-type inventory is malformed")
    candidates = tuple(
        device
        for device in payload["devicetypes"]
        if isinstance(device, dict)
        and isinstance(device.get("name"), str)
        and device["name"].startswith(("iPhone ", "iPad "))
        and isinstance(device.get("identifier"), str)
    )
    if requested_name is not None:
        selected = next(
            (device for device in candidates if device["name"] == requested_name),
            None,
        )
        if selected is None:
            raise SimulatorSetupError(
                f"no exact iPhone or iPad simulator device type named {requested_name!r}"
            )
        if selected["identifier"] not in supported_device_type_identifiers:
            raise SimulatorSetupError(
                f"simulator device type {requested_name!r} is not supported by the selected iOS runtime"
            )
    else:
        compatible = tuple(
            device
            for device in candidates
            if device["identifier"] in supported_device_type_identifiers
        )
        preferred = next(
            (device for device in compatible if device["name"] == "iPhone Duo"),
            None,
        )
        standard = next(
            (device for device in compatible if device["name"] == "iPhone 17 Pro"),
            None,
        )
        selected = preferred or standard or next(
            (device for device in compatible if device["name"].startswith("iPhone ")),
            None,
        )
    if selected is None:
        raise SimulatorSetupError("no iPhone simulator device type supported by the selected iOS runtime")
    return selected["identifier"]


def simslim_configuration() -> SimSlimConfiguration | None:
    """Require the shared SimSlim binary and profile together on home Macs."""

    simslim = Path(SIMSLIM_PATH)
    if not simslim.is_file():
        discovered = shutil.which("simslim")
        simslim = Path(discovered) if discovered else simslim
    profile = Path(SIMSLIM_PROFILE_PATH)
    simslim_available = simslim.is_file() and os.access(simslim, os.X_OK)
    profile_available = profile.is_file()
    if not simslim_available and not profile_available:
        return None
    if not simslim_available or not profile_available:
        raise SimulatorSetupError(
            "simslim and its profile must both be available before simulator setup"
        )
    return str(simslim), profile


def task_simulator_name(task_name: str) -> str:
    """Return a unique name that identifies this task-owned simulator."""

    slug = TASK_NAME_PATTERN.sub("-", task_name).strip("-_")
    if not slug:
        raise SimulatorSetupError("simulator task name is invalid")
    return f"{slug}{TASK_MARKER}{uuid.uuid4().hex[:10]}"


def create_task_simulator(
    *,
    task_name: str,
    run_command: CommandRunner,
    device_type_name: str | None = None,
) -> PreparedSimulator:
    """Create and verify one fresh simulator rather than borrowing a device."""

    name = task_simulator_name(task_name)
    runtime = select_runtime(run_command)
    identifier = validate_identifier(
        run_command(
            (
                XCRUN,
                "simctl",
                "create",
                name,
                device_type_identifier(
                    run_command,
                    runtime.supported_device_type_identifiers,
                    device_type_name,
                ),
                runtime.identifier,
            ),
            True,
        ).strip()
    )
    matches = tuple(
        device
        for device in simulator_inventory(run_command)
        if device.identifier == identifier and device.name == name
    )
    if len(matches) != 1:
        remove_unregistered_creation(run_command, identifier)
        raise SimulatorSetupError(
            "created simulator UUID and task-owned name could not be verified"
        )
    return PreparedSimulator(identifier=identifier, name=name)


def remove_unregistered_creation(
    run_command: CommandRunner,
    identifier: str,
) -> None:
    """Remove only a newly created device that failed identity verification."""

    run_command((XCRUN, "simctl", "shutdown", identifier), False)
    run_command((XCRUN, "simctl", "delete", identifier), True)
    deadline = time.monotonic() + 5
    while any(
        device.identifier == identifier for device in simulator_inventory(run_command)
    ):
        if time.monotonic() >= deadline:
            raise SimulatorSetupError("unregistered simulator could not be proven absent")
        time.sleep(0.05)


def task_device(
    identifier: str,
    name: str,
    *,
    run_command: CommandRunner,
    require_booted: bool = True,
) -> SimulatorDevice:
    """Prove the UDID and exact task-specific name still identify one device."""

    identifier = validate_identifier(identifier)
    if TASK_MARKER not in name:
        raise SimulatorSetupError("simulator name does not identify a Codex task")
    matches = tuple(
        device
        for device in simulator_inventory(run_command)
        if device.identifier == identifier
    )
    if len(matches) != 1 or matches[0].name != name:
        raise SimulatorSetupError("UDID does not match the task-owned simulator")
    if require_booted and matches[0].state != "Booted":
        raise SimulatorSetupError("task-owned simulator is not booted")
    return matches[0]


def apply_simslim_profile(
    identifier: str,
    configuration: SimSlimConfiguration,
    *,
    run_command: CommandRunner,
) -> None:
    """Apply and immediately verify the shared profile on one exact UDID."""

    executable, profile = configuration
    run_command(
        (executable, "on", identifier, "--profile", str(profile)),
        True,
    )
    run_command(
        (executable, "verify", identifier, "--profile", str(profile)),
        True,
    )


def verify_stock_status(
    identifier: str,
    configuration: SimSlimConfiguration,
    *,
    run_command: CommandRunner,
) -> None:
    """Require SimSlim to report the exact device back at stock state."""

    executable, _profile = configuration
    payload = json_command(
        run_command,
        (executable, "status", "--json", identifier),
    )
    if (
        not isinstance(payload, dict)
        or payload.get("booted") is not True
        or payload.get("managedDisabled") != 0
        or payload.get("verdict") != "stock"
    ):
        raise SimulatorSetupError("could not verify stock simulator services")


def validate_task_simulator(
    identifier: str,
    name: str,
    *,
    run_command: CommandRunner = subprocess_command,
) -> None:
    """Validate nested test scripts inherited the task's exact active UDID."""

    task_device(identifier, name, run_command=run_command)
    configuration = simslim_configuration()
    if configuration is not None:
        executable, profile = configuration
        run_command(
            (executable, "verify", identifier, "--profile", str(profile)),
            True,
        )


def prepare_task_simulator(
    *,
    task_name: str,
    run_command: CommandRunner = subprocess_command,
    device_type_name: str | None = None,
) -> PreparedSimulator:
    """Create and boot one exact task-owned simulator after build preflight."""

    configuration = simslim_configuration()
    prepared = create_task_simulator(
        task_name=task_name,
        run_command=run_command,
        device_type_name=device_type_name,
    )
    try:
        if configuration is not None:
            apply_simslim_profile(
                prepared.identifier,
                configuration,
                run_command=run_command,
            )
        else:
            run_command((XCRUN, "simctl", "boot", prepared.identifier), False)
            run_command(
                (XCRUN, "simctl", "bootstatus", prepared.identifier, "-b"),
                True,
            )
        task_device(
            prepared.identifier,
            prepared.name,
            run_command=run_command,
        )
    except Exception as setup_error:
        try:
            cleanup_task_simulator(
                prepared.identifier,
                prepared.name,
                run_command=run_command,
                configuration=configuration,
            )
        except Exception as cleanup_error:
            raise SimulatorSetupError(
                f"simulator setup failed and cleanup was not verified: {cleanup_error}"
            ) from setup_error
        raise
    return prepared


def wait_until_shutdown_or_absent(
    identifier: str,
    *,
    run_command: CommandRunner,
) -> None:
    """Prove the exact task-owned simulator is no longer booted."""

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


def cleanup_task_simulator(
    identifier: str,
    name: str,
    *,
    run_command: CommandRunner = subprocess_command,
    configuration: SimSlimConfiguration | None = None,
) -> None:
    """Restore stock services, then shut down and delete this task's device."""

    identifier = validate_identifier(identifier)
    task_device(
        identifier,
        name,
        run_command=run_command,
        require_booted=False,
    )
    if configuration is None:
        configuration = simslim_configuration()
    if configuration is not None:
        executable, _profile = configuration
        run_command((executable, "off", identifier), True)
        verify_stock_status(identifier, configuration, run_command=run_command)
    run_command((XCRUN, "simctl", "shutdown", identifier), False)
    wait_until_shutdown_or_absent(identifier, run_command=run_command)
    run_command((XCRUN, "simctl", "delete", identifier), True)
    deadline = time.monotonic() + 5
    while any(
        device.identifier == identifier for device in simulator_inventory(run_command)
    ):
        if time.monotonic() >= deadline:
            raise SimulatorSetupError("task-owned simulator could not be proven absent")
        time.sleep(0.05)


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    """Parse the simulator helper's small task-owned lifecycle interface."""

    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--name", required=True)
    prepare.add_argument("--device-type")
    validate = subparsers.add_parser("validate-task")
    validate.add_argument("--udid", required=True)
    validate.add_argument("--name", required=True)
    cleanup = subparsers.add_parser("cleanup")
    cleanup.add_argument("--udid", required=True)
    cleanup.add_argument("--name", required=True)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    """Create, validate, or clean up the exact task-owned simulator."""

    namespace = parse_arguments(sys.argv[1:] if arguments is None else arguments)
    try:
        if namespace.operation == "prepare":
            prepared = prepare_task_simulator(
                task_name=namespace.name,
                device_type_name=namespace.device_type,
            )
            print(f"{prepared.identifier}\t1\t{prepared.name}")
        elif namespace.operation == "validate-task":
            validate_task_simulator(namespace.udid, namespace.name)
        else:
            cleanup_task_simulator(namespace.udid, namespace.name)
    except (OSError, SimulatorSetupError, subprocess.SubprocessError) as error:
        print(f"Could not safely prepare the simulator: {error}", file=sys.stderr)
        return 125
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
