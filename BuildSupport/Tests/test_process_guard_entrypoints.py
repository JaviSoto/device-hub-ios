from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARDED_RUN = ROOT / "Scripts" / "guarded-run.sh"
PROCESS_GUARD = ROOT / "BuildSupport" / "process_guard.sh"
HEAVY_ENTRYPOINTS = (
    ROOT / "ci" / "run_ci.sh",
    ROOT / "Sources" / "DeviceHubPrivateMedia" / "Tests" / "run-tests.sh",
    ROOT / "Scripts" / "archive-app.sh",
    ROOT / "Scripts" / "build-app.sh",
    ROOT / "Scripts" / "build-protocol-xcframework.sh",
    ROOT / "Scripts" / "lint-dead-code.sh",
    ROOT / "Scripts" / "render-local-previews.sh",
    ROOT / "Scripts" / "test-app.sh",
    ROOT / "Scripts" / "test-core.sh",
    ROOT / "Scripts" / "test-live-ios.sh",
    ROOT / "Scripts" / "test-rust.sh",
    ROOT / "Scripts" / "verify-protocol-xcframework.sh",
)


class ProcessGuardEntrypointTests(unittest.TestCase):
    def test_shell_entrypoint_acquires_guard_and_marks_child(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            lock_path = temporary_root / "guard.lock"
            output_path = temporary_root / "environment.txt"
            environment = os.environ.copy()
            environment["DEVICE_HUB_GUARD_LOCK_PATH"] = str(lock_path)

            result = subprocess.run(
                [
                    "bash",
                    str(GUARDED_RUN),
                    "--name",
                    "entrypoint-test",
                    "--timeout-seconds",
                    "5",
                    "--",
                    "bash",
                    "-c",
                    (f"printf '%s' \"$DEVICE_HUB_GUARD_HELD\" > " f"{output_path!s}"),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
                env=environment,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output_path.read_text(), "1")

    def test_guard_helper_reexecutes_script_exactly_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            lock_path = temporary_root / "guard.lock"
            count_path = temporary_root / "count.txt"
            fixture = temporary_root / "fixture.sh"
            fixture.write_text(
                "\n".join(
                    [
                        "#!/usr/bin/env bash",
                        "set -euo pipefail",
                        f"source {str(PROCESS_GUARD)!r}",
                        ("devicehub_require_guard fixture-test 5 " '"$0" "$@"'),
                        (
                            "test -r "
                            '"/dev/fd/${DEVICE_HUB_GUARD_FD:?guard fd missing}"'
                        ),
                        f"printf 'run\\n' >> {str(count_path)!r}",
                    ]
                )
                + "\n"
            )
            fixture.chmod(0o755)
            environment = os.environ.copy()
            environment["DEVICE_HUB_GUARD_LOCK_PATH"] = str(lock_path)

            result = subprocess.run(
                ["bash", str(fixture)],
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
                env=environment,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(count_path.read_text().splitlines(), ["run"])

    def test_forged_guard_environment_cannot_bypass_an_active_owner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            lock_path = temporary_root / "guard.lock"
            owner_ready = temporary_root / "owner-ready"
            sentinel = temporary_root / "forged-started"
            fixture = temporary_root / "fixture.sh"
            fixture.write_text(
                "\n".join(
                    [
                        "#!/usr/bin/env bash",
                        "set -euo pipefail",
                        f"source {str(PROCESS_GUARD)!r}",
                        ("devicehub_require_guard forged-test 5 " '"$0" "$@"'),
                        f"touch {str(sentinel)!r}",
                    ]
                )
                + "\n"
            )
            fixture.chmod(0o755)
            environment = os.environ.copy()
            environment["DEVICE_HUB_GUARD_HELD"] = "1"
            environment["DEVICE_HUB_GUARD_LOCK_PATH"] = str(lock_path)
            environment.pop("DEVICE_HUB_GUARD_FD", None)
            owner = subprocess.Popen(
                [
                    "bash",
                    str(GUARDED_RUN),
                    "--name",
                    "real-owner",
                    "--timeout-seconds",
                    "10",
                    "--",
                    "python3",
                    "-c",
                    (
                        "import pathlib, time; "
                        f"pathlib.Path({str(owner_ready)!r}).touch(); "
                        "time.sleep(30)"
                    ),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=environment,
            )
            try:
                deadline = time.monotonic() + 5
                while not owner_ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(owner_ready.exists(), "lock owner did not start")

                forged = subprocess.run(
                    ["bash", str(fixture)],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=10,
                    env=environment,
                )

                self.assertEqual(forged.returncode, 75)
                self.assertFalse(sentinel.exists())
            finally:
                owner.send_signal(signal.SIGTERM)
                try:
                    owner.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    owner.kill()
                    owner.wait(timeout=5)

    def test_every_heavy_entrypoint_requires_the_shared_guard(self) -> None:
        for entrypoint in HEAVY_ENTRYPOINTS:
            with self.subTest(entrypoint=entrypoint.relative_to(ROOT)):
                contents = entrypoint.read_text()
                source_index = contents.find("BuildSupport/process_guard.sh")
                guard_index = contents.find("devicehub_require_guard")

                self.assertGreaterEqual(source_index, 0)
                self.assertGreater(guard_index, source_index)

    def test_ci_delegates_to_named_mise_tasks(self) -> None:
        contents = (ROOT / "ci" / "run_ci.sh").read_text()

        self.assertIn("mise run test", contents)
        self.assertIn("mise run protocol:verify", contents)
        self.assertIn("mise run lint", contents)
        self.assertIn("mise run previews", contents)
        self.assertNotIn("test_*.py", contents)


if __name__ == "__main__":
    unittest.main()
