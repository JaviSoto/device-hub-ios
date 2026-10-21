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



class GuardedProcessExecutionTests(GuardedProcessTestCase):
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

