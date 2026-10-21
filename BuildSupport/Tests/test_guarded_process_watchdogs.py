from __future__ import annotations

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

from guarded_process_test_support import (
    GuardedProcessTestCase,
    RUNNER,
    different_group_descendant_program,
    guarded_process,
    process_exists,
)



class GuardedProcessWatchdogTests(GuardedProcessTestCase):
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
            self.assertEqual(watchdog.wait.call_args_list[0].kwargs["timeout"], 5.0)
        finally:
            for descriptor in (read_descriptor, write_descriptor):
                try:
                    os.close(descriptor)
                except OSError:
                    pass

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

