from __future__ import annotations

import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MISE_PATH = ROOT / "mise.toml"
CI_PATH = ROOT / "ci" / "run_ci.sh"


class CILocalGateContractTests(unittest.TestCase):
    def test_repository_owns_one_canonical_ci_task(self) -> None:
        config = tomllib.loads(MISE_PATH.read_text())

        self.assertEqual("ci/run_ci.sh", config["tasks"]["ci"]["run"])
        self.assertFalse((ROOT / ".github" / "workflows" / "ci.yml").exists())

    def test_ci_runs_every_test_lint_preview_and_release_build_gate(self) -> None:
        source = CI_PATH.read_text()

        for command in (
            "run_ci_task test",
            "run_ci_task protocol:verify",
            "run_ci_task lint",
            "run_ci_task previews",
            "run_ci_task build",
        ):
            with self.subTest(command=command):
                self.assertIn(command, source)

        self.assertIn("CONFIGURATION=Release", source)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", source)
        self.assertIn("DEVICE_HUB_FULL_CI", source)

    def test_ci_keeps_the_outer_guard_while_nested_mise_tasks_reacquire_their_lock(self) -> None:
        source = CI_PATH.read_text()

        self.assertIn("DEVICE_HUB_GUARD_HELD=0", source)
        self.assertIn("DEVICE_HUB_GUARD_LOCK_PATH", source)

    def test_ci_leaves_simulator_ownership_with_the_preflighted_test_app(self) -> None:
        source = CI_PATH.read_text()

        self.assertNotIn("codex-simulator-lease", source)
        self.assertNotIn("devicehub_require_simulator", source)
        app_test = (ROOT / "Scripts" / "test-app.sh").read_text()
        self.assertLess(
            app_test.index('DESTINATION="generic/platform=iOS Simulator"'),
            app_test.index("devicehub_require_simulator device-hub-test-app"),
        )
        self.assertIn("devicehub_cleanup_simulator", app_test)

    def test_ci_fails_when_verification_changes_the_checkout(self) -> None:
        source = CI_PATH.read_text()

        self.assertIn("git diff", source)
        self.assertIn("Device Hub CI passed", source)


if __name__ == "__main__":
    unittest.main()
