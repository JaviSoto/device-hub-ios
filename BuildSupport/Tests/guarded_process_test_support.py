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


class GuardedProcessTestCase(unittest.TestCase):
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

