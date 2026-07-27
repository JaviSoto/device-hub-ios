from __future__ import annotations

import importlib
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "BuildSupport" / "guarded_process.py"
sys.path.insert(0, str(RUNNER.parent))
guarded_process = importlib.import_module("guarded_process")
sys.path.pop(0)


def process_exists(pid: int) -> bool:
    """Return whether a process is still addressable without mutating it."""

    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def different_group_descendant_program(identity_path: Path) -> str:
    """Return a fixture program that records its PID, PGID, and session ID."""

    return (
        "import os, pathlib, time; "
        "os.setpgid(0, 0); "
        f"pathlib.Path({str(identity_path)!r}).write_text("
        "':'.join(str(value) for value in "
        "(os.getpid(), os.getpgrp(), os.getsid(0)))); "
        "time.sleep(30)"
    )


class GuardedProcessTests(unittest.TestCase):
    def assert_different_group_same_session(self, identity_path: Path) -> int:
        """Validate the cross-process-group fixture and return its PID."""

        process_id, process_group_id, process_session_id = (
            int(value) for value in identity_path.read_text().split(":")
        )
        self.assertEqual(process_group_id, process_id)
        self.assertNotEqual(process_session_id, process_id)
        return process_id

    def run_guarded(
        self,
        lock_path: Path,
        command: list[str],
        *,
        timeout_seconds: str = "5",
        grace_seconds: str = "0.25",
        name: str = "test-operation",
    ) -> subprocess.CompletedProcess[str]:
        """Run the real process guard with an isolated lock."""

        return subprocess.run(
            [
                sys.executable,
                str(RUNNER),
                "--name",
                name,
                "--timeout-seconds",
                timeout_seconds,
                "--grace-seconds",
                grace_seconds,
                "--lock-path",
                str(lock_path),
                "--",
                *command,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_watchdog_preserves_session_after_normal_completion(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        os.write(write_descriptor, b"device-hub-guard-complete-v1")
        os.close(write_descriptor)

        with mock.patch.object(
            guarded_process,
            "terminate_external_process_session",
        ) as terminate_session:
            result = guarded_process.watchdog_main(
                [
                    "--read-fd",
                    str(read_descriptor),
                    "--process-session-id",
                    "424242",
                    "--grace-seconds",
                    "0.1",
                ]
            )

        self.assertEqual(result, 0)
        terminate_session.assert_not_called()

    def test_watchdog_cleans_session_without_exact_completion(self) -> None:
        for payload in (
            b"",
            b"device-hub-guard-complete",
            b"device-hub-guard-complete-v1-extra",
        ):
            with self.subTest(payload=payload):
                read_descriptor, write_descriptor = os.pipe()
                os.write(write_descriptor, payload)
                os.close(write_descriptor)

                with mock.patch.object(
                    guarded_process,
                    "terminate_external_process_session",
                ) as terminate_session:
                    result = guarded_process.watchdog_main(
                        [
                            "--read-fd",
                            str(read_descriptor),
                            "--process-session-id",
                            "424242",
                            "--grace-seconds",
                            "0.1",
                        ]
                    )

                self.assertEqual(result, 0)
                terminate_session.assert_called_once_with(
                    424242,
                    grace_seconds=0.1,
                )

    def test_watchdog_read_failure_cleans_session(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        os.close(write_descriptor)

        with (
            mock.patch.object(
                guarded_process.os,
                "read",
                side_effect=OSError("injected read failure"),
            ),
            mock.patch.object(
                guarded_process,
                "terminate_external_process_session",
            ) as terminate_session,
        ):
            result = guarded_process.watchdog_main(
                [
                    "--read-fd",
                    str(read_descriptor),
                    "--process-session-id",
                    "424242",
                    "--grace-seconds",
                    "0.1",
                ]
            )

        self.assertEqual(result, 0)
        terminate_session.assert_called_once_with(
            424242,
            grace_seconds=0.1,
        )

    def test_parent_watchdog_write_failure_closes_and_reaps(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        watchdog = mock.Mock()
        watchdog.wait.return_value = 0
        try:
            with (
                mock.patch.object(
                    guarded_process.os,
                    "pipe",
                    return_value=(read_descriptor, write_descriptor),
                ),
                mock.patch.object(
                    guarded_process.subprocess,
                    "Popen",
                    return_value=watchdog,
                ),
                mock.patch.object(
                    guarded_process.os,
                    "write",
                    side_effect=OSError("injected write failure"),
                ),
                self.assertRaisesRegex(
                    OSError,
                    "injected write failure",
                ),
            ):
                with guarded_process.parent_death_watchdog(
                    424242,
                    grace_seconds=0.1,
                ) as supervision:
                    supervision.mark_cleanup_verified()

            with self.assertRaises(OSError):
                os.fstat(read_descriptor)
            with self.assertRaises(OSError):
                os.fstat(write_descriptor)
            watchdog.wait.assert_called_once()
        finally:
            for descriptor in (read_descriptor, write_descriptor):
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_parent_watchdog_requires_explicit_cleanup_verification(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        watchdog = mock.Mock()
        watchdog.wait.return_value = 0
        try:
            with (
                mock.patch.object(
                    guarded_process.os,
                    "pipe",
                    return_value=(read_descriptor, write_descriptor),
                ),
                mock.patch.object(
                    guarded_process.subprocess,
                    "Popen",
                    return_value=watchdog,
                ),
                mock.patch.object(
                    guarded_process.os,
                    "write",
                ) as write_completion,
            ):
                with guarded_process.parent_death_watchdog(
                    424242,
                    grace_seconds=0.1,
                ):
                    pass

            write_completion.assert_not_called()
            watchdog.wait.assert_called_once()
        finally:
            for descriptor in (read_descriptor, write_descriptor):
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_parent_watchdog_sends_exact_normal_completion(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        watchdog = mock.Mock()
        watchdog.wait.return_value = 0
        try:
            with (
                mock.patch.object(
                    guarded_process.os,
                    "pipe",
                    return_value=(read_descriptor, write_descriptor),
                ),
                mock.patch.object(
                    guarded_process.subprocess,
                    "Popen",
                    return_value=watchdog,
                ),
                mock.patch.object(
                    guarded_process.os,
                    "write",
                    return_value=len(b"device-hub-guard-complete-v1"),
                ) as write_completion,
            ):
                with guarded_process.parent_death_watchdog(
                    424242,
                    grace_seconds=0.1,
                ) as supervision:
                    supervision.mark_cleanup_verified()

            write_completion.assert_called_once_with(
                write_descriptor,
                b"device-hub-guard-complete-v1",
            )
            watchdog.wait.assert_called_once()
        finally:
            for descriptor in (read_descriptor, write_descriptor):
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_parent_watchdog_does_not_signal_exceptional_completion(
        self,
    ) -> None:
        read_descriptor, write_descriptor = os.pipe()
        watchdog = mock.Mock()
        watchdog.wait.return_value = 0
        try:
            with (
                mock.patch.object(
                    guarded_process.os,
                    "pipe",
                    return_value=(read_descriptor, write_descriptor),
                ),
                mock.patch.object(
                    guarded_process.subprocess,
                    "Popen",
                    return_value=watchdog,
                ),
                mock.patch.object(
                    guarded_process.os,
                    "write",
                ) as write_completion,
                self.assertRaisesRegex(
                    RuntimeError,
                    "injected guarded-body failure",
                ),
            ):
                with guarded_process.parent_death_watchdog(
                    424242,
                    grace_seconds=0.1,
                ):
                    raise RuntimeError("injected guarded-body failure")

            write_completion.assert_not_called()
            watchdog.wait.assert_called_once()
        finally:
            for descriptor in (read_descriptor, write_descriptor):
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_parent_watchdog_partial_write_fails_supervision(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        watchdog = mock.Mock()
        watchdog.wait.return_value = 0
        try:
            with (
                mock.patch.object(
                    guarded_process.os,
                    "pipe",
                    return_value=(read_descriptor, write_descriptor),
                ),
                mock.patch.object(
                    guarded_process.subprocess,
                    "Popen",
                    return_value=watchdog,
                ),
                mock.patch.object(
                    guarded_process.os,
                    "write",
                    return_value=len(b"device-hub-guard-complete-v1") - 1,
                ),
                self.assertRaisesRegex(
                    OSError,
                    "could not notify the process watchdog",
                ),
            ):
                with guarded_process.parent_death_watchdog(
                    424242,
                    grace_seconds=0.1,
                ) as supervision:
                    supervision.mark_cleanup_verified()

            watchdog.wait.assert_called_once()
        finally:
            for descriptor in (read_descriptor, write_descriptor):
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_parent_watchdog_nonzero_exit_fails_supervision(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        watchdog = mock.Mock()
        watchdog.wait.return_value = 7
        try:
            with (
                mock.patch.object(
                    guarded_process.os,
                    "pipe",
                    return_value=(read_descriptor, write_descriptor),
                ),
                mock.patch.object(
                    guarded_process.subprocess,
                    "Popen",
                    return_value=watchdog,
                ),
                mock.patch.object(
                    guarded_process.os,
                    "write",
                    return_value=len(b"device-hub-guard-complete-v1"),
                ),
                self.assertRaisesRegex(
                    OSError,
                    "process watchdog exited with status 7",
                ),
            ):
                with guarded_process.parent_death_watchdog(
                    424242,
                    grace_seconds=0.1,
                ) as supervision:
                    supervision.mark_cleanup_verified()

            with self.assertRaises(OSError):
                os.fstat(read_descriptor)
            with self.assertRaises(OSError):
                os.fstat(write_descriptor)
            watchdog.wait.assert_called_once()
        finally:
            for descriptor in (read_descriptor, write_descriptor):
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_parent_watchdog_timeout_fails_supervision(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        watchdog = mock.Mock()
        watchdog.wait.side_effect = (
            subprocess.TimeoutExpired("process-watchdog", 0.1),
            0,
        )
        try:
            with (
                mock.patch.object(
                    guarded_process.os,
                    "pipe",
                    return_value=(read_descriptor, write_descriptor),
                ),
                mock.patch.object(
                    guarded_process.subprocess,
                    "Popen",
                    return_value=watchdog,
                ),
                mock.patch.object(
                    guarded_process.os,
                    "write",
                    return_value=len(b"device-hub-guard-complete-v1"),
                ),
                self.assertRaisesRegex(
                    OSError,
                    "process watchdog exceeded its supervision deadline",
                ),
            ):
                with guarded_process.parent_death_watchdog(
                    424242,
                    grace_seconds=0.1,
                ):
                    pass

            watchdog.kill.assert_called_once_with()
            self.assertEqual(watchdog.wait.call_count, 2)
        finally:
            for descriptor in (read_descriptor, write_descriptor):
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    @unittest.skipUnless(
        sys.platform == "darwin",
        "CoreSimulator runtime services exist only on macOS",
    )
    def test_managed_simulator_runtime_is_not_a_background_leak(self) -> None:
        runtime_service = guarded_process.ProcessSessionMember(
            process_id=53742,
            parent_process_id=53308,
            executable_path=Path(
                "/Library/Developer/CoreSimulator/Volumes/iOS_24A5380g/"
                "Library/Developer/CoreSimulator/Profiles/Runtimes/"
                "iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/"
                "System/Library/PrivateFrameworks/"
                "DVTInstrumentsFoundation.framework/DTServiceHub"
            ),
        )
        leaked_build_tools = (
            guarded_process.ProcessSessionMember(
                process_id=61001,
                parent_process_id=1,
                executable_path=Path("/usr/bin/xcodebuild"),
            ),
            guarded_process.ProcessSessionMember(
                process_id=61002,
                parent_process_id=1,
                executable_path=Path("/usr/bin/swift"),
            ),
            guarded_process.ProcessSessionMember(
                process_id=61003,
                parent_process_id=1,
                executable_path=Path("/Users/example/.cargo/bin/cargo"),
            ),
            guarded_process.ProcessSessionMember(
                process_id=61004,
                parent_process_id=1,
                executable_path=Path(
                    "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl"
                ),
            ),
            guarded_process.ProcessSessionMember(
                process_id=61005,
                parent_process_id=1,
                executable_path=Path(
                    "/Library/Developer/CoreSimulator/Volumes-untrusted/" "DTServiceHub"
                ),
            ),
        )

        remaining = guarded_process.background_processes_requiring_cleanup(
            (runtime_service, *leaked_build_tools),
            preserve_managed_simulator_services=True,
        )
        interrupted_cleanup = guarded_process.background_processes_requiring_cleanup(
            (runtime_service, *leaked_build_tools),
            preserve_managed_simulator_services=False,
        )

        self.assertEqual(remaining, leaked_build_tools)
        self.assertEqual(
            interrupted_cleanup,
            (runtime_service, *leaked_build_tools),
        )

    def test_selected_xcode_test_service_hub_matches_only_exact_toolchain(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            developer_directory = root / "Xcode-beta.app" / "Contents" / "Developer"
            service_hub = (
                developer_directory.parent
                / "SharedFrameworks"
                / "DVTInstrumentsFoundation.framework"
                / "Resources"
                / "DTServiceHub"
            )
            service_hub.parent.mkdir(parents=True)
            service_hub.touch()

            selected = guarded_process.ProcessSessionMember(
                process_id=62001,
                parent_process_id=1,
                executable_path=service_hub,
            )
            other_toolchain = guarded_process.ProcessSessionMember(
                process_id=62002,
                parent_process_id=1,
                executable_path=(
                    root
                    / "Other-Xcode.app"
                    / "Contents"
                    / "SharedFrameworks"
                    / "DVTInstrumentsFoundation.framework"
                    / "Resources"
                    / "DTServiceHub"
                ),
            )
            similarly_named = guarded_process.ProcessSessionMember(
                process_id=62003,
                parent_process_id=1,
                executable_path=developer_directory.parent / "DTServiceHub",
            )

            self.assertTrue(
                guarded_process.is_selected_xcode_test_service_hub(
                    selected,
                    developer_directory=developer_directory,
                )
            )
            self.assertFalse(
                guarded_process.is_selected_xcode_test_service_hub(
                    other_toolchain,
                    developer_directory=developer_directory,
                )
            )
            self.assertFalse(
                guarded_process.is_selected_xcode_test_service_hub(
                    similarly_named,
                    developer_directory=developer_directory,
                )
            )

    def test_cleanup_selected_xcode_test_service_hub_targets_only_service(
        self,
    ) -> None:
        developer_directory = Path("/Applications/Xcode-beta.app/Contents/Developer")
        service_hub = guarded_process.ProcessSessionMember(
            process_id=63001,
            parent_process_id=1,
            executable_path=(
                developer_directory.parent
                / "SharedFrameworks"
                / "DVTInstrumentsFoundation.framework"
                / "Resources"
                / "DTServiceHub"
            ),
        )
        unrelated = guarded_process.ProcessSessionMember(
            process_id=63002,
            parent_process_id=1,
            executable_path=Path("/Users/example/.cargo/bin/cargo"),
        )

        with (
            mock.patch.object(
                guarded_process,
                "process_session_members",
                side_effect=((service_hub, unrelated), (unrelated,)),
            ),
            mock.patch.object(
                guarded_process,
                "signal_process_session_members",
            ) as signal_members,
            mock.patch.object(
                guarded_process,
                "wait_for_known_session_members",
            ) as wait_for_members,
        ):
            cleaned = guarded_process.cleanup_selected_xcode_test_service_hub(
                424242,
                developer_directory=developer_directory,
                grace_seconds=0.25,
            )

        self.assertTrue(cleaned)
        signal_members.assert_called_once_with(
            424242,
            (service_hub,),
            signal.SIGTERM,
        )
        wait_for_members.assert_called_once()

    def test_success_propagates_environment_and_exit_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output = root / "environment.txt"
            result = self.run_guarded(
                root / "guard.lock",
                [
                    sys.executable,
                    "-c",
                    (
                        "import os, pathlib; "
                        f"pathlib.Path({str(output)!r}).write_text("
                        "os.environ.get('DEVICE_HUB_GUARD_HELD', 'missing'))"
                    ),
                ],
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), "1")

            failure = self.run_guarded(
                root / "guard.lock",
                [sys.executable, "-c", "raise SystemExit(23)"],
            )
            self.assertEqual(failure.returncode, 23)

    def test_invalid_timeout_fails_before_starting_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            sentinel = root / "started"

            for timeout in ("0", "-1", "3601", "not-a-number"):
                with self.subTest(timeout=timeout):
                    result = self.run_guarded(
                        root / "guard.lock",
                        [
                            sys.executable,
                            "-c",
                            f"from pathlib import Path; Path({str(sentinel)!r}).touch()",
                        ],
                        timeout_seconds=timeout,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(sentinel.exists())

    def test_lock_file_is_private_and_symlinks_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            lock_path = root / "guard.lock"
            success = self.run_guarded(
                lock_path,
                [sys.executable, "-c", "raise SystemExit(0)"],
            )

            self.assertEqual(success.returncode, 0, success.stderr)
            self.assertEqual(stat.S_IMODE(lock_path.stat().st_mode), 0o600)

            target = root / "must-not-change"
            target.write_text("preserved")
            symlink = root / "symlink.lock"
            symlink.symlink_to(target)
            sentinel = root / "started"
            refused = self.run_guarded(
                symlink,
                [
                    sys.executable,
                    "-c",
                    f"from pathlib import Path; Path({str(sentinel)!r}).touch()",
                ],
            )

            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(target.read_text(), "preserved")
            self.assertFalse(sentinel.exists())

    def test_spawn_failure_releases_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            lock_path = root / "guard.lock"

            failure = self.run_guarded(
                lock_path,
                [str(root / "does-not-exist")],
            )
            self.assertEqual(failure.returncode, 127)

            next_run = self.run_guarded(
                lock_path,
                [sys.executable, "-c", "raise SystemExit(0)"],
            )
            self.assertEqual(next_run.returncode, 0, next_run.stderr)

    def test_child_signal_status_uses_shell_convention(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            result = self.run_guarded(
                root / "guard.lock",
                [
                    sys.executable,
                    "-c",
                    "import os, signal; os.kill(os.getpid(), signal.SIGKILL)",
                ],
            )

            self.assertEqual(result.returncode, 137, result.stderr)

    def test_contender_fails_before_starting_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            lock_path = root / "guard.lock"
            owner_ready = root / "owner-ready"
            contender_started = root / "contender-started"
            owner = subprocess.Popen(
                [
                    sys.executable,
                    str(RUNNER),
                    "--name",
                    "owner",
                    "--timeout-seconds",
                    "10",
                    "--grace-seconds",
                    "0.25",
                    "--lock-path",
                    str(lock_path),
                    "--",
                    sys.executable,
                    "-c",
                    (
                        "import pathlib, time; "
                        f"pathlib.Path({str(owner_ready)!r}).touch(); "
                        "time.sleep(30)"
                    ),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not owner_ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(owner_ready.exists(), "lock owner did not start")

                contender = self.run_guarded(
                    lock_path,
                    [
                        sys.executable,
                        "-c",
                        (
                            "from pathlib import Path; "
                            f"Path({str(contender_started)!r}).touch()"
                        ),
                    ],
                    name="contender",
                )

                self.assertEqual(contender.returncode, 75)
                self.assertFalse(contender_started.exists())
                self.assertIn("already running", contender.stderr)
            finally:
                owner.send_signal(signal.SIGTERM)
                try:
                    owner.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    owner.kill()
                    owner.communicate(timeout=5)

    def test_contender_never_echoes_untrusted_lock_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            lock_path = root / "guard.lock"
            owner_ready = root / "owner-ready"
            secret_marker = "must-not-appear-from-lock-file"
            owner = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    (
                        "import fcntl, pathlib, time; "
                        f"path = pathlib.Path({str(lock_path)!r}); "
                        "path.parent.mkdir(parents=True, exist_ok=True); "
                        "lock = path.open('w+'); "
                        "fcntl.flock(lock.fileno(), fcntl.LOCK_EX); "
                        f"lock.write({secret_marker!r}); lock.flush(); "
                        f"pathlib.Path({str(owner_ready)!r}).touch(); "
                        "time.sleep(30)"
                    ),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not owner_ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(owner_ready.exists(), "lock owner did not start")

                contender = self.run_guarded(
                    lock_path,
                    [sys.executable, "-c", "raise SystemExit(0)"],
                    name="contender",
                )

                self.assertEqual(contender.returncode, 75)
                self.assertIn("owner metadata unavailable", contender.stderr)
                self.assertNotIn(secret_marker, contender.stdout)
                self.assertNotIn(secret_marker, contender.stderr)
            finally:
                owner.send_signal(signal.SIGTERM)
                try:
                    owner.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    owner.kill()
                    owner.communicate(timeout=5)

    def test_timeout_kills_descendants_and_releases_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            lock_path = root / "guard.lock"
            grandchild_pid_path = root / "grandchild.pid"
            secret_marker = "must-not-appear-in-guard-output"
            result = self.run_guarded(
                lock_path,
                [
                    sys.executable,
                    "-c",
                    (
                        "import pathlib, subprocess, sys, time; "
                        "child = subprocess.Popen("
                        "[sys.executable, '-c', 'import time; time.sleep(30)']); "
                        f"pathlib.Path({str(grandchild_pid_path)!r}).write_text("
                        "str(child.pid)); "
                        "time.sleep(30)"
                    ),
                    secret_marker,
                ],
                timeout_seconds="0.25",
                grace_seconds="0.1",
            )

            self.assertEqual(result.returncode, 124, result.stderr)
            self.assertTrue(grandchild_pid_path.exists())
            grandchild_pid = int(grandchild_pid_path.read_text())
            deadline = time.monotonic() + 3
            while process_exists(grandchild_pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(
                process_exists(grandchild_pid),
                "timed-out descendant survived its guarded process group",
            )
            self.assertNotIn(secret_marker, result.stdout)
            self.assertNotIn(secret_marker, result.stderr)
            self.assertNotIn(secret_marker, lock_path.read_text())

            next_run = self.run_guarded(
                lock_path,
                [sys.executable, "-c", "raise SystemExit(0)"],
            )
            self.assertEqual(next_run.returncode, 0, next_run.stderr)

    def test_timeout_kills_same_session_descendant_in_another_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            descendant_pid_path = root / "other-group-descendant.pid"
            descendant_pid: int | None = None
            descendant_program = different_group_descendant_program(descendant_pid_path)
            try:
                result = self.run_guarded(
                    root / "guard.lock",
                    [
                        sys.executable,
                        "-c",
                        (
                            "import subprocess, sys, time; "
                            f"subprocess.Popen([sys.executable, '-c', "
                            f"{descendant_program!r}], "
                            "stdin=subprocess.DEVNULL, "
                            "stdout=subprocess.DEVNULL, "
                            "stderr=subprocess.DEVNULL); "
                            "time.sleep(30)"
                        ),
                    ],
                    timeout_seconds="0.25",
                    grace_seconds="0.1",
                )

                self.assertTrue(
                    descendant_pid_path.exists(),
                    "same-session descendant did not start",
                )
                descendant_pid = self.assert_different_group_same_session(
                    descendant_pid_path
                )
                self.assertEqual(result.returncode, 124, result.stderr)
                deadline = time.monotonic() + 3
                while process_exists(descendant_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(
                    process_exists(descendant_pid),
                    "timed-out same-session descendant survived in another group",
                )
            finally:
                if descendant_pid is not None and process_exists(descendant_pid):
                    os.kill(descendant_pid, signal.SIGKILL)

    def test_successful_child_cannot_leave_a_background_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            lock_path = root / "guard.lock"
            grandchild_pid_path = root / "grandchild.pid"
            grandchild_pid: int | None = None
            try:
                result = self.run_guarded(
                    lock_path,
                    [
                        sys.executable,
                        "-c",
                        (
                            "import pathlib, subprocess, sys; "
                            "child = subprocess.Popen("
                            "[sys.executable, '-c', 'import time; time.sleep(30)'], "
                            "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, "
                            "stderr=subprocess.DEVNULL); "
                            f"pathlib.Path({str(grandchild_pid_path)!r}).write_text("
                            "str(child.pid))"
                        ),
                    ],
                )

                self.assertTrue(grandchild_pid_path.exists())
                grandchild_pid = int(grandchild_pid_path.read_text())
                self.assertEqual(result.returncode, 125, result.stderr)
                self.assertIn("left background processes", result.stderr)
                deadline = time.monotonic() + 3
                while process_exists(grandchild_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(
                    process_exists(grandchild_pid),
                    "background descendant survived successful direct child",
                )
            finally:
                if grandchild_pid is not None and process_exists(grandchild_pid):
                    os.kill(grandchild_pid, signal.SIGKILL)

    def test_successful_child_cannot_leave_descendant_in_another_group(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            descendant_pid_path = root / "other-group-descendant.pid"
            descendant_pid: int | None = None
            descendant_program = different_group_descendant_program(descendant_pid_path)
            parent_program = "\n".join(
                (
                    "import pathlib, subprocess, sys, time",
                    (
                        "child = subprocess.Popen("
                        f"[sys.executable, '-c', {descendant_program!r}], "
                        "stdin=subprocess.DEVNULL, "
                        "stdout=subprocess.DEVNULL, "
                        "stderr=subprocess.DEVNULL)"
                    ),
                    "deadline = time.monotonic() + 2",
                    (f"path = pathlib.Path({str(descendant_pid_path)!r})"),
                    "while not path.exists() and time.monotonic() < deadline:",
                    "    time.sleep(0.01)",
                    "if not path.exists():",
                    "    raise SystemExit(91)",
                )
            )
            try:
                result = self.run_guarded(
                    root / "guard.lock",
                    [
                        sys.executable,
                        "-c",
                        parent_program,
                    ],
                )

                self.assertTrue(
                    descendant_pid_path.exists(),
                    "same-session descendant did not start",
                )
                descendant_pid = self.assert_different_group_same_session(
                    descendant_pid_path
                )
                self.assertEqual(result.returncode, 125, result.stderr)
                deadline = time.monotonic() + 3
                while process_exists(descendant_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(
                    process_exists(descendant_pid),
                    "background same-session descendant survived in another group",
                )
            finally:
                if descendant_pid is not None and process_exists(descendant_pid):
                    os.kill(descendant_pid, signal.SIGKILL)

    def test_sigterm_kills_descendants_and_releases_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            lock_path = root / "guard.lock"
            grandchild_pid_path = root / "grandchild.pid"
            owner = subprocess.Popen(
                [
                    sys.executable,
                    str(RUNNER),
                    "--name",
                    "signal-owner",
                    "--timeout-seconds",
                    "10",
                    "--grace-seconds",
                    "0.1",
                    "--lock-path",
                    str(lock_path),
                    "--",
                    sys.executable,
                    "-c",
                    (
                        "import pathlib, subprocess, sys, time; "
                        "child = subprocess.Popen("
                        "[sys.executable, '-c', 'import time; time.sleep(30)']); "
                        f"pathlib.Path({str(grandchild_pid_path)!r}).write_text("
                        "str(child.pid)); "
                        "time.sleep(30)"
                    ),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not grandchild_pid_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(
                    grandchild_pid_path.exists(), "guarded command did not start"
                )
                grandchild_pid = int(grandchild_pid_path.read_text())

                owner.send_signal(signal.SIGTERM)
                _, stderr = owner.communicate(timeout=5)

                self.assertEqual(owner.returncode, 143, stderr)
                deadline = time.monotonic() + 3
                while process_exists(grandchild_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(process_exists(grandchild_pid))

                next_run = self.run_guarded(
                    lock_path,
                    [sys.executable, "-c", "raise SystemExit(0)"],
                )
                self.assertEqual(next_run.returncode, 0, next_run.stderr)
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.communicate(timeout=5)

    def test_sigterm_kills_same_session_descendant_in_another_group(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            descendant_pid_path = root / "other-group-descendant.pid"
            descendant_program = different_group_descendant_program(descendant_pid_path)
            owner = subprocess.Popen(
                [
                    sys.executable,
                    str(RUNNER),
                    "--name",
                    "other-group-signal-owner",
                    "--timeout-seconds",
                    "10",
                    "--grace-seconds",
                    "0.1",
                    "--lock-path",
                    str(root / "guard.lock"),
                    "--",
                    sys.executable,
                    "-c",
                    (
                        "import subprocess, sys, time; "
                        f"subprocess.Popen([sys.executable, '-c', "
                        f"{descendant_program!r}], "
                        "stdin=subprocess.DEVNULL, "
                        "stdout=subprocess.DEVNULL, "
                        "stderr=subprocess.DEVNULL); "
                        "time.sleep(30)"
                    ),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            descendant_pid: int | None = None
            try:
                deadline = time.monotonic() + 5
                while not descendant_pid_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(
                    descendant_pid_path.exists(),
                    "same-session descendant did not start",
                )
                descendant_pid = self.assert_different_group_same_session(
                    descendant_pid_path
                )

                owner.send_signal(signal.SIGTERM)
                _, stderr = owner.communicate(timeout=5)

                self.assertEqual(owner.returncode, 143, stderr)
                deadline = time.monotonic() + 3
                while process_exists(descendant_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(
                    process_exists(descendant_pid),
                    "terminated same-session descendant survived in another group",
                )
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.communicate(timeout=5)
                if descendant_pid is not None and process_exists(descendant_pid):
                    os.kill(descendant_pid, signal.SIGKILL)

    def test_sighup_kills_descendants_and_releases_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            lock_path = root / "guard.lock"
            grandchild_pid_path = root / "grandchild.pid"
            owner = subprocess.Popen(
                [
                    sys.executable,
                    str(RUNNER),
                    "--name",
                    "hangup-owner",
                    "--timeout-seconds",
                    "10",
                    "--grace-seconds",
                    "0.1",
                    "--lock-path",
                    str(lock_path),
                    "--",
                    sys.executable,
                    "-c",
                    (
                        "import pathlib, subprocess, sys, time; "
                        "child = subprocess.Popen("
                        "[sys.executable, '-c', 'import time; time.sleep(30)']); "
                        f"pathlib.Path({str(grandchild_pid_path)!r}).write_text("
                        "str(child.pid)); "
                        "time.sleep(30)"
                    ),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not grandchild_pid_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(
                    grandchild_pid_path.exists(), "guarded command did not start"
                )
                grandchild_pid = int(grandchild_pid_path.read_text())

                owner.send_signal(signal.SIGHUP)
                _, stderr = owner.communicate(timeout=5)

                self.assertEqual(owner.returncode, 129, stderr)
                deadline = time.monotonic() + 3
                while process_exists(grandchild_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(process_exists(grandchild_pid))

                next_run = self.run_guarded(
                    lock_path,
                    [sys.executable, "-c", "raise SystemExit(0)"],
                )
                self.assertEqual(next_run.returncode, 0, next_run.stderr)
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.communicate(timeout=5)

    def test_watchdog_kills_child_when_guard_is_sigkilled(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            child_pid_path = root / "child.pid"
            owner = subprocess.Popen(
                [
                    sys.executable,
                    str(RUNNER),
                    "--name",
                    "watchdog-owner",
                    "--timeout-seconds",
                    "10",
                    "--grace-seconds",
                    "0.1",
                    "--lock-path",
                    str(root / "guard.lock"),
                    "--",
                    sys.executable,
                    "-c",
                    (
                        "import os, pathlib, time; "
                        f"pathlib.Path({str(child_pid_path)!r}).write_text("
                        "str(os.getpid())); "
                        "time.sleep(30)"
                    ),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            child_pid: int | None = None
            try:
                deadline = time.monotonic() + 5
                while not child_pid_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(child_pid_path.exists(), "guarded child did not start")
                child_pid = int(child_pid_path.read_text())

                owner.kill()
                owner.wait(timeout=5)

                deadline = time.monotonic() + 3
                while process_exists(child_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(
                    process_exists(child_pid),
                    "watchdog did not terminate child after guard death",
                )
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait(timeout=5)
                if child_pid is not None and process_exists(child_pid):
                    try:
                        os.killpg(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_watchdog_kills_same_session_descendant_in_another_group(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            child_pid_path = root / "child.pid"
            descendant_pid_path = root / "other-group-descendant.pid"
            descendant_program = different_group_descendant_program(descendant_pid_path)
            owner = subprocess.Popen(
                [
                    sys.executable,
                    str(RUNNER),
                    "--name",
                    "other-group-watchdog-owner",
                    "--timeout-seconds",
                    "10",
                    "--grace-seconds",
                    "0.1",
                    "--lock-path",
                    str(root / "guard.lock"),
                    "--",
                    sys.executable,
                    "-c",
                    (
                        "import os, pathlib, subprocess, sys, time; "
                        f"pathlib.Path({str(child_pid_path)!r}).write_text("
                        "str(os.getpid())); "
                        f"subprocess.Popen([sys.executable, '-c', "
                        f"{descendant_program!r}], "
                        "stdin=subprocess.DEVNULL, "
                        "stdout=subprocess.DEVNULL, "
                        "stderr=subprocess.DEVNULL); "
                        "time.sleep(30)"
                    ),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            child_pid: int | None = None
            descendant_pid: int | None = None
            try:
                deadline = time.monotonic() + 5
                while (
                    not child_pid_path.exists() or not descendant_pid_path.exists()
                ) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(child_pid_path.exists())
                self.assertTrue(descendant_pid_path.exists())
                child_pid = int(child_pid_path.read_text())
                descendant_pid = self.assert_different_group_same_session(
                    descendant_pid_path
                )

                owner.kill()
                owner.wait(timeout=5)

                deadline = time.monotonic() + 3
                while (
                    process_exists(child_pid) or process_exists(descendant_pid)
                ) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(
                    process_exists(child_pid),
                    "watchdog did not terminate the guarded session leader",
                )
                self.assertFalse(
                    process_exists(descendant_pid),
                    "watchdog missed a same-session descendant in another group",
                )
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait(timeout=5)
                for process_id in (child_pid, descendant_pid):
                    if process_id is not None and process_exists(process_id):
                        os.kill(process_id, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
