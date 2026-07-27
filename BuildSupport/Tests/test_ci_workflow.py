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

    def test_ci_exposes_named_parallel_checks_and_builds_the_app(self) -> None:
        workflow = load_workflow()
        job = next(iter(workflow["jobs"].values()))
        steps = job["steps"]

        self.assertNotIn("Verify source", [step.get("name") for step in steps])
        self.assertFalse(
            any("mise run ci:hosted" in step.get("run", "") for step in steps)
        )

        parallel_groups = [step["parallel"] for step in steps if "parallel" in step]
        self.assertEqual(1, len(parallel_groups))
        parallel_steps = parallel_groups[0]
        names = [step["name"] for step in parallel_steps]
        self.assertEqual(len(names), len(set(names)))

        commands = {step["run"] for step in parallel_steps}
        self.assertTrue(
            {
                "mise run test:support",
                "mise run lint:shell",
                "mise run test:rust",
                "mise run test:swift",
                "mise run test:media",
                "mise run protocol:verify",
                "mise run build:app",
            }.issubset(commands)
        )

        app_build = next(
            step for step in parallel_steps if step["run"] == "mise run build:app"
        )
        self.assertEqual("Release", app_build["env"]["CONFIGURATION"])
        self.assertEqual("NO", app_build["env"]["CODE_SIGNING_ALLOWED"])
        self.assertIn("DERIVED_DATA_PATH", app_build["env"])

        swift_tests = next(
            step for step in parallel_steps if step["run"] == "mise run test:swift"
        )
        self.assertIn("SWIFT_SCRATCH_PATH", swift_tests["env"])

    def test_parallel_heavy_steps_use_independent_process_guards(self) -> None:
        workflow = load_workflow()
        job = next(iter(workflow["jobs"].values()))
        parallel_group = next(
            step["parallel"] for step in job["steps"] if "parallel" in step
        )
        guarded_commands = {
            "mise run test:rust",
            "mise run test:swift",
            "mise run test:media",
            "mise run protocol:verify",
            "mise run build:app",
        }
        lock_paths = [
            step["env"]["DEVICE_HUB_GUARD_LOCK_PATH"]
            for step in parallel_group
            if step["run"] in guarded_commands
        ]

        self.assertEqual(len(guarded_commands), len(lock_paths))
        self.assertEqual(len(lock_paths), len(set(lock_paths)))


if __name__ == "__main__":
    unittest.main()
