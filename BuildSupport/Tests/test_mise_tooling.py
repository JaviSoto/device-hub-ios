from __future__ import annotations

import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class MiseToolingContractTests(unittest.TestCase):
    def test_swiftpm_builds_default_to_derived_data_scratch(self) -> None:
        core_test = (ROOT / "Scripts" / "test-core.sh").read_text()
        previews = (ROOT / "Scripts" / "render-local-previews.sh").read_text()

        self.assertIn(
            'SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-$DERIVED_DATA_PATH/SwiftPM/DeviceHubKit}"',
            core_test,
        )
        self.assertIn('TEST_ARGUMENTS+=(--scratch-path "$SCRATCH_PATH")', core_test)
        self.assertIn(
            'PREVIEW_SCRATCH_PATH="${PREVIEW_SCRATCH_PATH:-$DERIVED_DATA_PATH/SwiftPM/PreviewRenderer}"',
            previews,
        )
        self.assertIn(
            'SWIFT_RUN_ARGUMENTS+=(--scratch-path "$PREVIEW_SCRATCH_PATH")',
            previews,
        )

    def test_rust_builds_default_to_derived_data_targets(self) -> None:
        rust_tests = (ROOT / "Scripts" / "test-rust.sh").read_text()
        protocol_build = (ROOT / "Scripts" / "build-protocol-xcframework.sh").read_text()

        self.assertIn(
            'CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$DERIVED_DATA_PATH/Rust/.build/tests}"',
            rust_tests,
        )
        self.assertIn(
            'readonly BUILD_ROOT="${DEVICE_HUB_PROTOCOL_TARGET_DIR:-$DERIVED_DATA_PATH/Rust/.build/cargo-ios-$DEPLOYMENT_TARGET}"',
            protocol_build,
        )

    def test_hosted_ci_shell_dependencies_are_managed_by_mise(self) -> None:
        configuration = tomllib.loads((ROOT / "mise.toml").read_text())
        tools = configuration["tools"]

        self.assertIn("ripgrep", tools)
        self.assertIn("shellcheck", tools)
        self.assertIn("yq", tools)

    def test_complete_test_task_runs_native_media_once(self) -> None:
        configuration = tomllib.loads((ROOT / "mise.toml").read_text())
        steps = configuration["tasks"]["test"]["run"]
        task_names = [
            step["task"]
            for step in steps
            if isinstance(step, dict) and "task" in step
        ]

        self.assertEqual(1, task_names.count("test:media"))

    def test_full_ci_verifies_the_packaged_protocol_once(self) -> None:
        script = (ROOT / "ci" / "run_ci.sh").read_text()

        self.assertEqual(1, script.count("run_ci_task protocol:verify"))

    def test_full_ci_preflights_process_inspection_and_generates_project_first(self) -> None:
        script = (ROOT / "ci" / "run_ci.sh").read_text()

        preflight_index = script.index("--preflight-process-inspection")
        guard_index = script.index("devicehub_require_guard full-ci")
        generate_index = script.index("run_ci_task generate")
        tests_index = script.index("run_ci_task test")

        self.assertLess(preflight_index, guard_index)
        self.assertLess(generate_index, tests_index)

    def test_lint_task_delegates_to_atomic_mise_tasks(self) -> None:
        configuration = tomllib.loads((ROOT / "mise.toml").read_text())
        steps = configuration["tasks"]["lint"]["run"]
        task_names = [step["task"] for step in steps]

        self.assertEqual(
            [
                "format:check",
                "lint:swift",
                "lint:shell",
                "lint:duplication",
                "generate",
                "lint:dead-code",
            ],
            task_names,
        )

    def test_protocol_build_delegates_to_atomic_mise_tasks(self) -> None:
        configuration = tomllib.loads((ROOT / "mise.toml").read_text())
        steps = configuration["tasks"]["protocol:build"]["run"]

        self.assertEqual(
            [
                {"task": "protocol:bootstrap"},
                {"task": "protocol:xcframework"},
            ],
            steps,
        )

    def test_preview_gate_requires_the_current_screen_first_ipad_layout(self) -> None:
        script = (ROOT / "Scripts" / "render-local-previews.sh").read_text()

        self.assertIn('item["layout"] == "single-column"', script)
        self.assertNotIn('two-column', script)


if __name__ == "__main__":
    unittest.main()
