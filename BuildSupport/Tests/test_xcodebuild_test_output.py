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
        self.formatter = self.bin / "fixture-xcbeautify"
        self.formatter.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >"$FIXTURE_FORMATTER_ARGS"
cat
exit "${FIXTURE_FORMATTER_EXIT:-0}"
""",
            encoding="utf-8",
        )
        self.tee = self.bin / "tee"
        self.tee.write_text(
            """#!/usr/bin/env bash
cat >/dev/null
exit "${FIXTURE_TEE_EXIT:-29}"
""",
            encoding="utf-8",
        )
        for command in (self.producer, self.formatter, self.tee):
            command.chmod(0o755)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_helper(self, *, raw_log: Path, result_bundle: Path, **fixture_env: str):
        formatter_args = self.root / "formatter-args.txt"
        command = " ".join(
            (
                "source",
                shlex.quote(str(HELPER)),
                "&&",
                "devicehub_run_xcodebuild_test",
                "fixture-test",
                shlex.quote(str(raw_log)),
                shlex.quote(str(result_bundle)),
                shlex.quote(str(self.formatter)),
                shlex.quote(str(self.producer)),
                "test",
                "-project",
                "Fixture.xcodeproj",
            )
        )
        environment = os.environ.copy()
        environment.update(
            {
                "FIXTURE_FORMATTER_ARGS": str(formatter_args),
                **fixture_env,
            }
        )
        return subprocess.run(
            ("/bin/bash", "-c", command),
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        ), formatter_args

    def test_success_retains_raw_log_result_and_ci_summary(self) -> None:
        raw_log = self.root / "evidence" / "success.log"
        result_bundle = self.root / "evidence" / "success.xcresult"

        result, formatter_args = self.run_helper(
            raw_log=raw_log,
            result_bundle=result_bundle,
            FIXTURE_OUTPUT="Test Suite 'Fixture' passed",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(raw_log.read_text(encoding="utf-8").strip(), "Test Suite 'Fixture' passed")
        self.assertTrue(result_bundle.is_dir())
        self.assertEqual(
            formatter_args.read_text(encoding="utf-8").splitlines(),
            ["--is-ci --disable-logging"],
        )
        self.assertIn("XCODEBUILD_OK action=fixture-test", result.stderr)
        self.assertIn(str(raw_log), result.stderr)
        self.assertIn(str(result_bundle), result.stderr)

    def test_app_test_entrypoints_share_the_native_test_output_helper(self) -> None:
        live_tests = (ROOT / "Scripts" / "test-live-ios.sh").read_text(encoding="utf-8")
        app_tests = (ROOT / "Scripts" / "test-app.sh").read_text(encoding="utf-8")
        helper = HELPER.read_text(encoding="utf-8")

        self.assertIn("BuildSupport/xcodebuild_test_output.sh", live_tests)
        self.assertIn("BuildSupport/xcodebuild_test_output.sh", app_tests)
        self.assertIn("--is-ci --disable-logging", helper)
        self.assertNotIn("-quiet", live_tests)
        self.assertNotIn("-quiet", app_tests)

    def test_compiler_error_preserves_producer_status_and_evidence(self) -> None:
        raw_log = self.root / "evidence" / "compiler.log"
        result_bundle = self.root / "evidence" / "compiler.xcresult"

        result, _ = self.run_helper(
            raw_log=raw_log,
            result_bundle=result_bundle,
            FIXTURE_OUTPUT="warning: fixture warning; error: fixture compiler failure",
            FIXTURE_XCODEBUILD_EXIT="67",
        )

        self.assertEqual(result.returncode, 67)
        self.assertIn("error: fixture compiler failure", raw_log.read_text(encoding="utf-8"))
        self.assertTrue(result_bundle.is_dir())
        self.assertIn("xcodebuild_exit=67", result.stderr)
        self.assertIn(str(raw_log), result.stderr)
        self.assertIn(str(result_bundle), result.stderr)

    def test_xctest_failure_preserves_original_status_and_result_bundle(self) -> None:
        raw_log = self.root / "evidence" / "xctest.log"
        result_bundle = self.root / "evidence" / "xctest.xcresult"

        result, _ = self.run_helper(
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

        result, _ = self.run_helper(
            raw_log=raw_log,
            result_bundle=result_bundle,
            FIXTURE_CREATE_RESULT="0",
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("XCODEBUILD_RESULT_MISSING", result.stderr)
        self.assertTrue(raw_log.is_file())

    def test_raw_log_write_failure_is_reported_even_when_test_passes(self) -> None:
        result_bundle = self.root / "evidence" / "tee-failure.xcresult"
        command = " ".join(
            (
                "source",
                shlex.quote(str(HELPER)),
                "&&",
                "devicehub_run_xcodebuild_test",
                "fixture-test",
                shlex.quote(str(self.root / "evidence" / "tee-failure.log")),
                shlex.quote(str(result_bundle)),
                shlex.quote(str(self.formatter)),
                shlex.quote(str(self.producer)),
                "test",
                "-project",
                "Fixture.xcodeproj",
            )
        )
        environment = os.environ.copy()
        environment.update(
            {
                "FIXTURE_FORMATTER_ARGS": str(self.root / "formatter-args.txt"),
                "PATH": f"{self.bin}:{os.environ['PATH']}",
            }
        )
        result = subprocess.run(
            ("/bin/bash", "-c", command),
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 29)
        self.assertTrue(result_bundle.is_dir())
        self.assertIn("XCODEBUILD_OUTPUT_FAILED action=fixture-test tee_exit=29", result.stderr)


if __name__ == "__main__":
    unittest.main()
