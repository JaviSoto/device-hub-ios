from __future__ import annotations

import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class MiseToolingContractTests(unittest.TestCase):
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

        self.assertEqual(1, script.count("mise run protocol:verify"))

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


if __name__ == "__main__":
    unittest.main()
