#!/usr/bin/env python3
"""Run one bounded Device Hub operation and clean up its entire process session."""

from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import re
import signal
import stat
import subprocess
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from types import FrameType
from typing import IO, Iterator, Sequence

MAXIMUM_TIMEOUT_SECONDS = 3_600.0
MAXIMUM_GRACE_SECONDS = 30.0
LOCK_CONTENTION_EXIT_STATUS = 75
TIMEOUT_EXIT_STATUS = 124
RESIDUAL_PROCESS_EXIT_STATUS = 125
CLEANUP_FAILURE_EXIT_STATUS = 126
LOCK_METADATA_MAXIMUM_BYTES = 4_096
NAME_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
PROCESS_INSPECTION_TIMEOUT_SECONDS = 2.0
MAXIMUM_KILL_SWEEPS = 3
WATCHDOG_NORMAL_COMPLETION_MESSAGE = b"device-hub-guard-complete-v1"
PROCESS_STATUS_EXECUTABLES = (Path("/bin/ps"), Path("/usr/bin/ps"))
CORE_SIMULATOR_RUNTIME_VOLUMES_ROOT = Path("/Library/Developer/CoreSimulator/Volumes")


@dataclass(frozen=True)
class GuardConfiguration:
    """Validated inputs for one guarded child process."""

    name: str
    timeout_seconds: float
    grace_seconds: float
    lock_path: Path
    command: tuple[str, ...]


class LockUnavailableError(RuntimeError):
    """Raised when another Device Hub operation owns the single-flight lock."""

    def __init__(self, owner: str) -> None:
        super().__init__(owner)
        self.owner = owner


class RequestedTermination(BaseException):
    """Interrupt normal waiting so a received signal can be forwarded safely."""

    def __init__(self, signal_number: int) -> None:
        super().__init__(signal_number)
        self.signal_number = signal_number


@dataclass(frozen=True)
class HeldLock:
    """Open descriptor proving that a guarded descendant owns the lock."""

    descriptor: int


@dataclass(frozen=True)
class ProcessSessionMember:
    """Safe process metadata used to decide operation-session ownership."""

    process_id: int
    parent_process_id: int
    executable_path: Path


@dataclass
class WatchdogSupervision:
    """Require callers to explicitly attest that owned cleanup was verified."""

    cleanup_verified: bool = False

    def mark_cleanup_verified(self) -> None:
        """Allow the watcher to stand down after the caller proves cleanup."""

        self.cleanup_verified = True


def bounded_seconds(value: str, *, maximum: float, label: str) -> float:
    """Parse a positive finite duration capped at the supplied maximum."""

    try:
        seconds = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{label} must be a number") from error
    if not math.isfinite(seconds) or seconds <= 0 or seconds > maximum:
        raise argparse.ArgumentTypeError(
            f"{label} must be greater than 0 and at most {maximum:g}"
        )
    return seconds


def parse_arguments(arguments: Sequence[str]) -> GuardConfiguration:
    """Parse and validate CLI inputs without running the requested command."""

    parser = argparse.ArgumentParser(
        description=(
            "Run one Device Hub operation with a global lock, a hard timeout, "
            "and process-session cleanup."
        )
    )
    parser.add_argument("--name", required=True)
    parser.add_argument(
        "--timeout-seconds",
        required=True,
        type=lambda value: bounded_seconds(
            value,
            maximum=MAXIMUM_TIMEOUT_SECONDS,
            label="timeout",
        ),
    )
    parser.add_argument(
        "--grace-seconds",
        default=5.0,
        type=lambda value: bounded_seconds(
            value,
            maximum=MAXIMUM_GRACE_SECONDS,
            label="grace period",
        ),
    )
    parser.add_argument("--lock-path", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    namespace = parser.parse_args(arguments)

    if NAME_PATTERN.fullmatch(namespace.name) is None:
        parser.error(
            "--name must contain only letters, digits, periods, underscores, "
            "or hyphens and be at most 64 characters"
        )

    command = tuple(namespace.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required after --")

    return GuardConfiguration(
        name=namespace.name,
        timeout_seconds=namespace.timeout_seconds,
        grace_seconds=namespace.grace_seconds,
        lock_path=Path(os.path.abspath(namespace.lock_path.expanduser())),
        command=command,
    )


def lock_metadata(name: str) -> str:
    """Return intentionally command-free ownership metadata for the lock."""

    return json.dumps(
        {
            "name": name,
            "pid": os.getpid(),
            "startedAt": datetime.now(timezone.utc).isoformat(),
        },
        sort_keys=True,
    )


def safe_lock_owner(raw_metadata: str) -> str:
    """Return bounded display metadata without echoing untrusted lock contents."""

    try:
        metadata = json.loads(raw_metadata)
    except (json.JSONDecodeError, TypeError):
        return "owner metadata unavailable"

    if not isinstance(metadata, dict):
        return "owner metadata unavailable"
    name = metadata.get("name")
    process_id = metadata.get("pid")
    if (
        not isinstance(name, str)
        or NAME_PATTERN.fullmatch(name) is None
        or isinstance(process_id, bool)
        or not isinstance(process_id, int)
        or process_id <= 0
    ):
        return "owner metadata unavailable"
    return f"operation {name!r} (pid {process_id})"


def open_secure_lock_file(path: Path) -> IO[str]:
    """Open one user-owned regular lock file without following a symlink."""

    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise OSError("process guard lock is not a user-owned regular file")
        os.fchmod(descriptor, 0o600)
        return os.fdopen(descriptor, "r+", encoding="utf-8")
    except BaseException:
        os.close(descriptor)
        raise


def inherited_lock_is_valid(path: Path) -> bool:
    """Validate or acquire the lock through a still-open inherited descriptor."""

    raw_descriptor = os.environ.get("DEVICE_HUB_GUARD_FD")
    if raw_descriptor is None or not raw_descriptor.isdecimal():
        return False
    descriptor = int(raw_descriptor)
    if descriptor < 3:
        return False

    try:
        descriptor_metadata = os.fstat(descriptor)
        path_metadata = os.stat(path, follow_symlinks=False)
    except OSError:
        return False
    if (
        not stat.S_ISREG(descriptor_metadata.st_mode)
        or not stat.S_ISREG(path_metadata.st_mode)
        or descriptor_metadata.st_uid != os.getuid()
        or path_metadata.st_uid != os.getuid()
        or descriptor_metadata.st_dev != path_metadata.st_dev
        or descriptor_metadata.st_ino != path_metadata.st_ino
    ):
        return False

    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, OSError):
        return False
    return True


@contextmanager
def acquire_lock(path: Path, *, name: str) -> Iterator[HeldLock]:
    """Hold an exclusive advisory lock until the guarded operation finishes."""

    with open_secure_lock_file(path) as lock_file:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            lock_file.seek(0)
            metadata = lock_file.read(LOCK_METADATA_MAXIMUM_BYTES + 1)
            owner = safe_lock_owner(
                metadata if len(metadata) <= LOCK_METADATA_MAXIMUM_BYTES else ""
            )
            raise LockUnavailableError(owner) from error

        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(lock_metadata(name))
        lock_file.flush()
        os.fsync(lock_file.fileno())
        try:
            yield HeldLock(descriptor=lock_file.fileno())
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def process_status_executable() -> Path:
    """Return a fixed system process-inspection binary, never a PATH override."""

    for executable in PROCESS_STATUS_EXECUTABLES:
        if executable.is_file() and os.access(executable, os.X_OK):
            return executable
    raise OSError("no trusted process status executable is available")


def is_core_simulator_runtime_service(executable_path: Path) -> bool:
    """Return whether an executable lives in Apple's managed simulator volume."""

    if sys.platform != "darwin":
        return False
    try:
        root_metadata = CORE_SIMULATOR_RUNTIME_VOLUMES_ROOT.stat()
    except OSError:
        return False
    if (
        root_metadata.st_uid != 0
        or not stat.S_ISDIR(root_metadata.st_mode)
        or root_metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        return False
    normalized_path = Path(os.path.abspath(executable_path))
    return (
        normalized_path == CORE_SIMULATOR_RUNTIME_VOLUMES_ROOT
        or CORE_SIMULATOR_RUNTIME_VOLUMES_ROOT in normalized_path.parents
    )


def is_selected_xcode_test_service_hub(
    member: ProcessSessionMember,
    *,
    developer_directory: Path,
) -> bool:
    """Return whether a member is the selected Xcode's host test service."""

    expected_path = (
        developer_directory.parent
        / "SharedFrameworks"
        / "DVTInstrumentsFoundation.framework"
        / "Resources"
        / "DTServiceHub"
    )
    return Path(os.path.realpath(member.executable_path)) == Path(
        os.path.realpath(expected_path)
    )


def background_processes_requiring_cleanup(
    members: Sequence[ProcessSessionMember],
    *,
    preserve_managed_simulator_services: bool,
) -> tuple[ProcessSessionMember, ...]:
    """Exclude only CoreSimulator runtime services from normal-exit cleanup."""

    if not preserve_managed_simulator_services:
        return tuple(members)
    return tuple(
        member
        for member in members
        if not is_core_simulator_runtime_service(member.executable_path)
    )


def process_session_members(
    process_session_id: int,
) -> tuple[ProcessSessionMember, ...]:
    """Return processes that still belong to one operation-owned POSIX session.

    Process IDs, parent IDs, and executable paths are requested. Arguments and
    environments are intentionally never read.
    """

    try:
        inspection = subprocess.run(
            [
                str(process_status_executable()),
                "-axo",
                "pid=,ppid=,comm=",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=PROCESS_INSPECTION_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OSError("could not inspect the guarded process session") from error
    if inspection.returncode != 0:
        raise OSError("could not inspect the guarded process session")

    members: list[ProcessSessionMember] = []
    for process_line in inspection.stdout.splitlines():
        fields = process_line.strip().split(maxsplit=2)
        if len(fields) != 3 or not fields[0].isdecimal() or not fields[1].isdecimal():
            raise OSError("process inspection returned malformed metadata")
        process_id = int(fields[0])
        parent_process_id = int(fields[1])
        try:
            session_id = os.getsid(process_id)
        except ProcessLookupError:
            continue
        except PermissionError as error:
            raise OSError(
                "could not validate guarded process session ownership"
            ) from error
        if session_id == process_session_id:
            members.append(
                ProcessSessionMember(
                    process_id=process_id,
                    parent_process_id=parent_process_id,
                    executable_path=Path(fields[2]),
                )
            )
    return tuple(members)


def signal_process_session_members(
    process_session_id: int,
    members: Sequence[ProcessSessionMember],
    signal_number: signal.Signals,
) -> None:
    """Signal only PIDs revalidated as members of the guarded session."""

    for member in members:
        try:
            if os.getsid(member.process_id) != process_session_id:
                continue
            os.kill(member.process_id, signal_number)
        except ProcessLookupError:
            continue
        except PermissionError as error:
            raise OSError(
                "could not signal a guarded process session member"
            ) from error


def process_is_session_member(
    process_id: int,
    process_session_id: int,
) -> bool:
    """Return whether a PID still belongs to the operation-owned session."""

    try:
        return os.getsid(process_id) == process_session_id
    except ProcessLookupError:
        return False
    except PermissionError as error:
        raise OSError("could not validate guarded process session ownership") from error


def wait_for_known_session_members(
    process_session_id: int,
    members: Sequence[ProcessSessionMember],
    *,
    deadline: float,
    process: subprocess.Popen[bytes] | None = None,
) -> None:
    """Wait boundedly for a known member snapshot without spawning pollers."""

    while time.monotonic() < deadline:
        if process is not None:
            process.poll()
        if not any(
            process_is_session_member(member.process_id, process_session_id)
            for member in members
        ):
            return
        time.sleep(0.01)


def cleanup_selected_xcode_test_service_hub(
    process_session_id: int,
    *,
    developer_directory: Path,
    grace_seconds: float,
) -> bool:
    """Stop Xcode's detached host test service without touching other members."""

    def service_hubs() -> tuple[ProcessSessionMember, ...]:
        return tuple(
            member
            for member in process_session_members(process_session_id)
            if is_selected_xcode_test_service_hub(
                member,
                developer_directory=developer_directory,
            )
        )

    members = service_hubs()
    if not members:
        return True
    signal_process_session_members(
        process_session_id,
        members,
        signal.SIGTERM,
    )
    wait_for_known_session_members(
        process_session_id,
        members,
        deadline=time.monotonic() + grace_seconds,
    )

    remaining = service_hubs()
    kill_deadline = time.monotonic() + max(grace_seconds, 0.1)
    kill_sweeps = 0
    while (
        remaining
        and kill_sweeps < MAXIMUM_KILL_SWEEPS
        and time.monotonic() < kill_deadline
    ):
        signal_process_session_members(
            process_session_id,
            remaining,
            signal.SIGKILL,
        )
        kill_sweeps += 1
        wait_for_known_session_members(
            process_session_id,
            remaining,
            deadline=kill_deadline,
        )
        remaining = service_hubs()
    return not remaining


def terminate_process_session_members(
    process_session_id: int,
    *,
    initial_signal: signal.Signals,
    grace_seconds: float,
    process: subprocess.Popen[bytes] | None = None,
    preserve_managed_simulator_services: bool = False,
) -> bool:
    """Boundedly terminate every same-session process, including new groups."""

    members = background_processes_requiring_cleanup(
        process_session_members(process_session_id),
        preserve_managed_simulator_services=(preserve_managed_simulator_services),
    )
    if members:
        signal_process_session_members(
            process_session_id,
            members,
            initial_signal,
        )
        wait_for_known_session_members(
            process_session_id,
            members,
            deadline=time.monotonic() + grace_seconds,
            process=process,
        )

    remaining = background_processes_requiring_cleanup(
        process_session_members(process_session_id),
        preserve_managed_simulator_services=(preserve_managed_simulator_services),
    )
    kill_deadline = time.monotonic() + max(grace_seconds, 0.1)
    kill_sweeps = 0
    while (
        remaining
        and kill_sweeps < MAXIMUM_KILL_SWEEPS
        and time.monotonic() < kill_deadline
    ):
        signal_process_session_members(
            process_session_id,
            remaining,
            signal.SIGKILL,
        )
        kill_sweeps += 1
        wait_for_known_session_members(
            process_session_id,
            remaining,
            deadline=kill_deadline,
            process=process,
        )
        remaining = background_processes_requiring_cleanup(
            process_session_members(process_session_id),
            preserve_managed_simulator_services=(preserve_managed_simulator_services),
        )

    if process is not None:
        try:
            process.wait(timeout=max(grace_seconds, 0.1))
        except subprocess.TimeoutExpired:
            return False
    return not background_processes_requiring_cleanup(
        process_session_members(process_session_id),
        preserve_managed_simulator_services=(preserve_managed_simulator_services),
    )


def terminate_direct_process(
    process: subprocess.Popen[bytes],
    *,
    initial_signal: signal.Signals,
    grace_seconds: float,
) -> bool:
    """Boundedly reap the exact child when session inspection is unavailable."""

    if process.poll() is not None:
        return True
    try:
        if os.getsid(process.pid) != process.pid:
            return False
        os.kill(process.pid, initial_signal)
    except ProcessLookupError:
        process.poll()
        return process.returncode is not None
    except PermissionError:
        return False

    try:
        process.wait(timeout=grace_seconds)
        return True
    except subprocess.TimeoutExpired:
        try:
            if os.getsid(process.pid) != process.pid:
                return False
            os.kill(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            return False
        try:
            process.wait(timeout=max(grace_seconds, 0.1))
            return True
        except subprocess.TimeoutExpired:
            return False


def terminate_process_session(
    process: subprocess.Popen[bytes],
    *,
    initial_signal: signal.Signals,
    grace_seconds: float,
    preserve_managed_simulator_services: bool = False,
) -> bool:
    """Clean an operation session, falling back safely if inspection fails."""

    try:
        return terminate_process_session_members(
            process.pid,
            initial_signal=initial_signal,
            grace_seconds=grace_seconds,
            process=process,
            preserve_managed_simulator_services=(preserve_managed_simulator_services),
        )
    except OSError:
        terminate_direct_process(
            process,
            initial_signal=initial_signal,
            grace_seconds=grace_seconds,
        )
        return False


def terminate_external_session_leader(
    process_session_id: int,
    *,
    grace_seconds: float,
) -> None:
    """Boundedly signal only a revalidated session leader as a safe fallback."""

    try:
        if os.getsid(process_session_id) != process_session_id:
            return
        os.kill(process_session_id, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        try:
            if os.getsid(process_session_id) != process_session_id:
                return
        except (ProcessLookupError, PermissionError):
            return
        time.sleep(0.01)
    try:
        if os.getsid(process_session_id) == process_session_id:
            os.kill(process_session_id, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        return


def terminate_external_process_session(
    process_session_id: int,
    *,
    grace_seconds: float,
) -> None:
    """Best-effort cleanup of all session members from the parent watchdog."""

    try:
        cleaned = terminate_process_session_members(
            process_session_id,
            initial_signal=signal.SIGTERM,
            grace_seconds=grace_seconds,
        )
    except OSError:
        cleaned = False
    if not cleaned:
        terminate_external_session_leader(
            process_session_id,
            grace_seconds=grace_seconds,
        )


def watchdog_main(arguments: Sequence[str]) -> int:
    """Kill an operation session unless its live guard completed normally."""

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--read-fd", required=True, type=int)
    parser.add_argument("--process-session-id", required=True, type=int)
    parser.add_argument(
        "--grace-seconds",
        required=True,
        type=lambda value: bounded_seconds(
            value,
            maximum=MAXIMUM_GRACE_SECONDS,
            label="grace period",
        ),
    )
    namespace = parser.parse_args(arguments)
    received = bytearray()
    read_failed = False
    try:
        while len(received) <= len(WATCHDOG_NORMAL_COMPLETION_MESSAGE):
            chunk = os.read(
                namespace.read_fd,
                len(WATCHDOG_NORMAL_COMPLETION_MESSAGE) + 1 - len(received),
            )
            if not chunk:
                break
            received.extend(chunk)
    except OSError:
        read_failed = True
    finally:
        try:
            os.close(namespace.read_fd)
        except OSError:
            read_failed = True
    if not read_failed and bytes(received) == WATCHDOG_NORMAL_COMPLETION_MESSAGE:
        return 0
    terminate_external_process_session(
        namespace.process_session_id,
        grace_seconds=namespace.grace_seconds,
    )
    return 0


@contextmanager
def parent_death_watchdog(
    process_session_id: int,
    *,
    grace_seconds: float,
) -> Iterator[WatchdogSupervision]:
    """Keep an independent parent-death watcher for the process session."""

    read_descriptor, write_descriptor = os.pipe()
    watchdog: subprocess.Popen[bytes] | None = None
    supervision = WatchdogSupervision()
    try:
        watchdog = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--watchdog",
                "--read-fd",
                str(read_descriptor),
                "--process-session-id",
                str(process_session_id),
                "--grace-seconds",
                str(grace_seconds),
            ],
            close_fds=True,
            pass_fds=(read_descriptor,),
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        os.close(read_descriptor)
        read_descriptor = -1
        yield supervision
    finally:
        supervision_error: OSError | None = None
        if read_descriptor >= 0:
            try:
                os.close(read_descriptor)
            except OSError as error:
                supervision_error = error
        if supervision.cleanup_verified:
            try:
                written = os.write(
                    write_descriptor,
                    WATCHDOG_NORMAL_COMPLETION_MESSAGE,
                )
                if written != len(WATCHDOG_NORMAL_COMPLETION_MESSAGE):
                    supervision_error = OSError(
                        "could not notify the process watchdog of normal completion"
                    )
            except OSError as error:
                supervision_error = error
        try:
            os.close(write_descriptor)
        except OSError as error:
            supervision_error = supervision_error or error
        if watchdog is not None:
            try:
                watchdog_status = watchdog.wait(
                    timeout=max(grace_seconds * 3, 5.0)
                )
                if watchdog_status != 0:
                    supervision_error = supervision_error or OSError(
                        f"process watchdog exited with status {watchdog_status}"
                    )
            except subprocess.TimeoutExpired:
                supervision_error = supervision_error or OSError(
                    "process watchdog exceeded its supervision deadline"
                )
                watchdog.kill()
                try:
                    watchdog.wait(timeout=max(grace_seconds, 0.1))
                except subprocess.TimeoutExpired:
                    pass
        if supervision_error is not None:
            raise supervision_error


@contextmanager
def termination_signal_scope() -> Iterator[None]:
    """Translate SIGINT and SIGTERM into cleanup-aware control flow."""

    previous_handlers: dict[signal.Signals, signal.Handlers] = {}

    def handle_signal(
        signal_number: int,
        _frame: FrameType | None,
    ) -> None:
        raise RequestedTermination(signal_number)

    for signal_name in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        previous_handlers[signal_name] = signal.getsignal(signal_name)
        signal.signal(signal_name, handle_signal)
    try:
        yield
    finally:
        for signal_name, handler in previous_handlers.items():
            signal.signal(signal_name, handler)


def child_environment(name: str, held_lock: HeldLock) -> dict[str, str]:
    """Mark the child as guarded without exposing its command in metadata."""

    environment = os.environ.copy()
    environment["DEVICE_HUB_GUARD_HELD"] = "1"
    environment["DEVICE_HUB_GUARD_FD"] = str(held_lock.descriptor)
    environment["DEVICE_HUB_GUARD_NAME"] = name
    return environment


def run_guarded(configuration: GuardConfiguration) -> int:
    """Run the child once, returning its status or a conventional guard status."""

    process: subprocess.Popen[bytes] | None = None
    try:
        with acquire_lock(
            configuration.lock_path,
            name=configuration.name,
        ) as held_lock:
            with termination_signal_scope():
                try:
                    process = subprocess.Popen(
                        configuration.command,
                        close_fds=True,
                        env=child_environment(
                            configuration.name,
                            held_lock,
                        ),
                        pass_fds=(held_lock.descriptor,),
                        start_new_session=True,
                    )
                except OSError as error:
                    error_number = (
                        f" (errno {error.errno})" if error.errno is not None else ""
                    )
                    print(
                        f"Could not start {configuration.name}{error_number}.",
                        file=sys.stderr,
                    )
                    return 127

                try:
                    with parent_death_watchdog(
                        process.pid,
                        grace_seconds=configuration.grace_seconds,
                    ) as supervision:
                        try:
                            return_code = process.wait(
                                timeout=configuration.timeout_seconds
                            )
                            background_processes = (
                                background_processes_requiring_cleanup(
                                    process_session_members(process.pid),
                                    preserve_managed_simulator_services=True,
                                )
                            )
                            if background_processes:
                                cleaned = terminate_process_session(
                                    process,
                                    initial_signal=signal.SIGTERM,
                                    grace_seconds=configuration.grace_seconds,
                                    preserve_managed_simulator_services=True,
                                )
                                print(
                                    f"{configuration.name} left background "
                                    "processes outside CoreSimulator; they "
                                    "were terminated.",
                                    file=sys.stderr,
                                )
                                if cleaned:
                                    supervision.mark_cleanup_verified()
                                return (
                                    RESIDUAL_PROCESS_EXIT_STATUS
                                    if cleaned
                                    else CLEANUP_FAILURE_EXIT_STATUS
                                )
                            supervision.mark_cleanup_verified()
                            if return_code < 0:
                                return 128 + abs(return_code)
                            return return_code
                        except subprocess.TimeoutExpired:
                            cleaned = terminate_process_session(
                                process,
                                initial_signal=signal.SIGTERM,
                                grace_seconds=configuration.grace_seconds,
                            )
                            print(
                                f"{configuration.name} timed out after "
                                f"{configuration.timeout_seconds:g} seconds; "
                                "its process session was terminated.",
                                file=sys.stderr,
                            )
                            if cleaned:
                                supervision.mark_cleanup_verified()
                            return (
                                TIMEOUT_EXIT_STATUS
                                if cleaned
                                else CLEANUP_FAILURE_EXIT_STATUS
                            )
                        except RequestedTermination as termination:
                            cleaned = terminate_process_session(
                                process,
                                initial_signal=signal.Signals(
                                    termination.signal_number
                                ),
                                grace_seconds=configuration.grace_seconds,
                            )
                            if cleaned:
                                supervision.mark_cleanup_verified()
                            return (
                                128 + termination.signal_number
                                if cleaned
                                else CLEANUP_FAILURE_EXIT_STATUS
                            )
                except OSError as error:
                    cleaned = terminate_process_session(
                        process,
                        initial_signal=signal.SIGTERM,
                        grace_seconds=configuration.grace_seconds,
                    )
                    print(
                        f"Could not supervise {configuration.name}: {error}.",
                        file=sys.stderr,
                    )
                    return CLEANUP_FAILURE_EXIT_STATUS
    except LockUnavailableError as error:
        print(
            f"A Device Hub operation is already running: {error.owner}",
            file=sys.stderr,
        )
        return LOCK_CONTENTION_EXIT_STATUS
    except OSError as error:
        error_number = f" (errno {error.errno})" if error.errno is not None else ""
        print(
            f"Could not prepare the Device Hub process guard{error_number}.",
            file=sys.stderr,
        )
        return CLEANUP_FAILURE_EXIT_STATUS
    except RequestedTermination as termination:
        if process is not None:
            cleaned = terminate_process_session(
                process,
                initial_signal=signal.Signals(termination.signal_number),
                grace_seconds=configuration.grace_seconds,
            )
            if not cleaned:
                return CLEANUP_FAILURE_EXIT_STATUS
        return 128 + termination.signal_number


def main(arguments: Sequence[str] | None = None) -> int:
    """CLI entry point."""

    supplied_arguments = sys.argv[1:] if arguments is None else arguments
    if supplied_arguments and supplied_arguments[0] == "--watchdog":
        return watchdog_main(supplied_arguments[1:])
    if (
        supplied_arguments
        and supplied_arguments[0] == "--cleanup-selected-xcode-test-service-hub"
    ):
        parser = argparse.ArgumentParser(add_help=False)
        parser.add_argument("--developer-dir", required=True, type=Path)
        parser.add_argument(
            "--grace-seconds",
            default=5.0,
            type=lambda value: bounded_seconds(
                value,
                maximum=MAXIMUM_GRACE_SECONDS,
                label="grace period",
            ),
        )
        namespace = parser.parse_args(supplied_arguments[1:])
        developer_directory = Path(
            os.path.abspath(namespace.developer_dir.expanduser())
        )
        try:
            return (
                0
                if cleanup_selected_xcode_test_service_hub(
                    os.getsid(0),
                    developer_directory=developer_directory,
                    grace_seconds=namespace.grace_seconds,
                )
                else 1
            )
        except OSError:
            print(
                "Could not clean up Xcode's detached test service.",
                file=sys.stderr,
            )
            return 1
    if supplied_arguments and supplied_arguments[0] == "--validate-inherited-lock":
        parser = argparse.ArgumentParser(add_help=False)
        parser.add_argument("--lock-path", required=True, type=Path)
        namespace = parser.parse_args(supplied_arguments[1:])
        return (
            0
            if inherited_lock_is_valid(
                Path(os.path.abspath(namespace.lock_path.expanduser()))
            )
            else 1
        )
    configuration = parse_arguments(supplied_arguments)
    return run_guarded(configuration)


if __name__ == "__main__":
    raise SystemExit(main())
