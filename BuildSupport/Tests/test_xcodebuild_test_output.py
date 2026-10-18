from __future__ import annotations

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "BuildSupport" / "xcodebuild_test_output.sh"


class XcodebuildTestOutputTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.producer = self.bin / "fixture-xcodebuild"
        self.producer.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
action="$1"
shift
result_bundle=""
while (( $# )); do
  if [[ "$1" == "-resultBundlePath" ]]; then
    result_bundle="$2"
    shift 2
  else
    shift
  fi
done
printf '%s\\n' "${FIXTURE_OUTPUT:-Testing started}"
if [[ "${FIXTURE_CREATE_RESULT:-1}" == "1" ]]; then
  mkdir -p "$result_bundle"
fi
exit "${FIXTURE_XCODEBUILD_EXIT:-0}"
""",
            encoding="utf-8",
        )
        self.producer.chmod(0o755)
        self.shared_support = self.root / "shared-support"
        logger_directory = self.shared_support / "scripts"
        logger_directory.mkdir(parents=True)
        self.logger = logger_directory / "run_logged.py"
        self.logger.write_text(
            """from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--log", required=True, type=Path)
parser.add_argument("--label", required=True)
parser.add_argument("--timeout", required=True, type=float)
parser.add_argument("command", nargs=argparse.REMAINDER)
arguments = parser.parse_args()
command = arguments.command[1:] if arguments.command[:1] == ["--"] else arguments.command
started = time.monotonic()
descriptor = os.open(arguments.log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "wb") as log:
    try:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                timeout=arguments.timeout, check=False)
        status = result.returncode
    except subprocess.TimeoutExpired:
        status = 124
    log.flush()
receipt = {"label": arguments.label, "exit_code": status,
           "elapsed_seconds": round(time.monotonic() - started, 2),
           "log": str(arguments.log), "log_bytes": arguments.log.stat().st_size}
if status:
    lines = arguments.log.read_text(encoding="utf-8", errors="replace").splitlines()
    receipt["diagnostics"] = [line[:300] for line in lines
        if re.search(r"error:|failed|failure|fatal|warning:|timed out", line, re.I)
        and not re.search(r"token|password|secret|authorization|<key>|<string>|BEGIN .*KEY", line, re.I)][-8:]
print(json.dumps(receipt))
sys.exit(status)
""",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_helper(self, *, raw_log: Path, result_bundle: Path, **fixture_env: str):
        command = " ".join(
            (
                "source",
                shlex.quote(str(HELPER)),
                "&&",
                "devicehub_run_xcodebuild",
                "fixture-test",
                shlex.quote(str(raw_log)),
                shlex.quote(str(result_bundle)),
                "10",
                shlex.quote(str(self.producer)),
                "test",
                "-project",
                "Fixture.xcodeproj",
            )
        )
        environment = os.environ.copy()
        environment.update(
            {
                "SHARED_IOS_SUPPORT_DIR": str(self.shared_support),
                **fixture_env,
            }
        )
        return subprocess.run(
            ("/bin/bash", "-c", command),
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_success_retains_raw_log_and_returns_concise_status(self) -> None:
        raw_log = self.root / "evidence" / "success.log"
        result_bundle = self.root / "evidence" / "success.xcresult"

        result = self.run_helper(
            raw_log=raw_log,
            result_bundle=result_bundle,
            FIXTURE_OUTPUT="Test Suite 'Fixture' passed",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(raw_log.read_text(encoding="utf-8").strip(), "Test Suite 'Fixture' passed")
        self.assertTrue(result_bundle.is_dir())
        self.assertIn('"label": "devicehub-fixture-test"', result.stdout)
        self.assertNotIn("Test Suite 'Fixture' passed", result.stdout + result.stderr)
        self.assertIn("XCODEBUILD_OK action=fixture-test", result.stderr)
        self.assertIn(str(raw_log), result.stderr)
        self.assertIn(str(result_bundle), result.stderr)

    def test_app_test_entrypoints_share_the_native_test_output_helper(self) -> None:
        live_tests = (ROOT / "Scripts" / "test-live-ios.sh").read_text(encoding="utf-8")
        app_tests = (ROOT / "Scripts" / "test-app.sh").read_text(encoding="utf-8")
        helper = HELPER.read_text(encoding="utf-8")

        self.assertIn("BuildSupport/xcodebuild_test_output.sh", live_tests)
        self.assertIn("BuildSupport/xcodebuild_test_output.sh", app_tests)
        self.assertIn("run_logged.py", helper)
        self.assertNotIn("xcbeautify", live_tests + app_tests + helper)
        self.assertNotIn("tee", helper)
        self.assertNotIn("-quiet", live_tests)
        self.assertNotIn("-quiet", app_tests)

    def test_compiler_error_preserves_producer_status_and_evidence(self) -> None:
        raw_log = self.root / "evidence" / "compiler.log"
        result_bundle = self.root / "evidence" / "compiler.xcresult"

        result = self.run_helper(
            raw_log=raw_log,
            result_bundle=result_bundle,
            FIXTURE_OUTPUT="warning: fixture warning; error: fixture compiler failure",
            FIXTURE_XCODEBUILD_EXIT="67",
        )

        self.assertEqual(result.returncode, 67)
        self.assertIn("error: fixture compiler failure", raw_log.read_text(encoding="utf-8"))
        self.assertTrue(result_bundle.is_dir())
        self.assertIn("xcodebuild_exit=67", result.stderr)
        self.assertIn("error: fixture compiler failure", result.stdout)
        self.assertIn(str(raw_log), result.stderr)
        self.assertIn(str(result_bundle), result.stderr)

    def test_xctest_failure_preserves_original_status_and_result_bundle(self) -> None:
        raw_log = self.root / "evidence" / "xctest.log"
        result_bundle = self.root / "evidence" / "xctest.xcresult"

        result = self.run_helper(
            raw_log=raw_log,
            result_bundle=result_bundle,
            FIXTURE_OUTPUT="Test Case 'KeyboardTests.testResponder' failed",
            FIXTURE_XCODEBUILD_EXIT="65",
        )

        self.assertEqual(result.returncode, 65)
        self.assertIn("KeyboardTests.testResponder", raw_log.read_text(encoding="utf-8"))
        self.assertTrue(result_bundle.is_dir())
        self.assertIn("xcodebuild_exit=65", result.stderr)

    def test_missing_result_bundle_is_not_reported_as_success(self) -> None:
        raw_log = self.root / "evidence" / "missing.log"
        result_bundle = self.root / "evidence" / "missing.xcresult"

        result = self.run_helper(
            raw_log=raw_log,
            result_bundle=result_bundle,
            FIXTURE_CREATE_RESULT="0",
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("XCODEBUILD_RESULT_MISSING", result.stderr)
        self.assertTrue(raw_log.is_file())

    def test_existing_log_is_not_overwritten(self) -> None:
        raw_log = self.root / "evidence" / "existing.log"
        raw_log.parent.mkdir(parents=True)
        raw_log.write_text("keep this evidence\n", encoding="utf-8")
        result_bundle = self.root / "evidence" / "existing.xcresult"

        result = self.run_helper(raw_log=raw_log, result_bundle=result_bundle)

        self.assertEqual(result.returncode, 2)
        self.assertEqual(raw_log.read_text(encoding="utf-8"), "keep this evidence\n")
        self.assertFalse(result_bundle.exists())
        self.assertIn("Refusing to overwrite existing test evidence", result.stderr)


if __name__ == "__main__":
    unittest.main()
