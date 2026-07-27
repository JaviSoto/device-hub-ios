from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "ci.yml"


def load_workflow() -> dict[str, object]:
    result = subprocess.run(
        ["yq", "-o=json", ".", str(WORKFLOW_PATH)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


class CIWorkflowContractTests(unittest.TestCase):
    def test_ci_runs_for_main_and_pull_requests(self) -> None:
        workflow = load_workflow()
        triggers = workflow["on"]

        self.assertEqual(["main"], triggers["push"]["branches"])
        self.assertEqual(["main"], triggers["pull_request"]["branches"])
        self.assertIn("workflow_dispatch", triggers)

    def test_ci_uses_one_xcode_27_runner_with_shared_setup(self) -> None:
        workflow = load_workflow()
        jobs = workflow["jobs"]

        self.assertEqual({"contents": "read"}, workflow["permissions"])
        self.assertEqual(1, len(jobs))
        job = next(iter(jobs.values()))
        self.assertEqual("xcode-27", job["runs-on"])

        steps = job["steps"]
        uses = [step.get("uses", "") for step in steps]
        self.assertEqual(1, sum("actions/checkout@" in action for action in uses))
        self.assertEqual(1, sum("jdx/mise-action@" in action for action in uses))

    def test_ci_exposes_atomic_mise_steps_and_builds_the_app(self) -> None:
        workflow = load_workflow()
        job = next(iter(workflow["jobs"].values()))
        steps = job["steps"]

        named_commands = {
            step["name"]: step["run"]
            for step in steps
            if "name" in step and "run" in step
        }
        self.assertEqual(
            {
                "Bootstrap protocol dependency": "mise run protocol:bootstrap",
                "Build protocol XCFramework": "mise run protocol:xcframework",
                "Generate Xcode project": "mise run generate",
                "Test build tooling": "mise run test:support",
                "Test native media boundary": "mise run test:media",
                "Check Swift formatting": "mise run format:check",
                "Lint Swift": "mise run lint:swift",
                "Lint shell scripts": "mise run lint:shell",
                "Detect duplicate code": "mise run lint:duplication",
                "Detect dead code": "mise run lint:dead-code",
                "Test Rust protocol": "mise run test:rust",
                "Test Swift packages": "mise run test:swift",
                "Verify protocol bridge": "mise run protocol:verify",
                "Build iOS app": "mise run build:app",
            },
            named_commands,
        )
        self.assertTrue(all(command.startswith("mise run ") for command in named_commands.values()))

        app_build = next(
            step for step in steps if step.get("run") == "mise run build:app"
        )
        self.assertEqual("Release", app_build["env"]["CONFIGURATION"])
        self.assertEqual("NO", app_build["env"]["CODE_SIGNING_ALLOWED"])
        self.assertIn("DERIVED_DATA_PATH", app_build["env"])

        swift_tests = next(
            step for step in steps if step.get("run") == "mise run test:swift"
        )
        self.assertIn("SWIFT_SCRATCH_PATH", swift_tests["env"])

    def test_safe_checks_run_as_visible_background_steps(self) -> None:
        workflow = load_workflow()
        job = next(iter(workflow["jobs"].values()))
        steps = job["steps"]
        background_commands = {
            step["run"] for step in steps if step.get("background") is True
        }
        self.assertEqual(
            {
                "mise run format:check",
                "mise run lint:swift",
                "mise run lint:shell",
                "mise run lint:duplication",
                "mise run lint:dead-code",
                "mise run test:rust",
                "mise run test:swift",
                "mise run protocol:verify",
                "mise run build:app",
            },
            background_commands,
        )
        self.assertTrue(any("wait-all" in step for step in steps))
        self.assertFalse(any("parallel" in step for step in steps))

    def test_parallel_heavy_steps_use_independent_process_guards(self) -> None:
        workflow = load_workflow()
        job = next(iter(workflow["jobs"].values()))
        guarded_steps = [
            step
            for step in job["steps"]
            if step.get("background") is True
            and step.get("run")
            in {
                "mise run test:rust",
                "mise run test:swift",
                "mise run protocol:verify",
                "mise run build:app",
                "mise run lint:dead-code",
            }
        ]
        lock_paths = [
            step["env"]["DEVICE_HUB_GUARD_LOCK_PATH"]
            for step in guarded_steps
        ]

        self.assertEqual(5, len(lock_paths))
        self.assertEqual(len(lock_paths), len(set(lock_paths)))


if __name__ == "__main__":
    unittest.main()
