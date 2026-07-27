import subprocess
import tempfile
import unittest
from pathlib import Path

from BuildSupport.ci_scope import changed_paths, is_documentation_only


class CIScopeTests(unittest.TestCase):
    def test_documentation_scope_requires_at_least_one_documentation_change(self):
        self.assertFalse(is_documentation_only([]))
        self.assertTrue(is_documentation_only(["README.md", "Docs/Architecture.md"]))
        self.assertTrue(is_documentation_only(["LICENSE"]))
        self.assertFalse(is_documentation_only(["README.md", "Sources/App.swift"]))

    def test_changed_paths_includes_committed_work_and_worktree_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "work"
            repository.mkdir()
            self.run_git(repository, "init", "-b", "main")
            self.run_git(repository, "config", "user.email", "ci@example.com")
            self.run_git(repository, "config", "user.name", "CI Test")
            self.run_git(repository, "config", "commit.gpgsign", "false")
            (repository / "README.md").write_text("Initial\n")
            self.run_git(repository, "add", "README.md")
            self.run_git(repository, "commit", "-m", "Initial")

            remote = root / "remote.git"
            self.run_git(repository, "init", "--bare", str(remote))
            self.run_git(repository, "remote", "add", "origin", str(remote))
            self.run_git(repository, "push", "-u", "origin", "main")

            (repository / "README.md").write_text("Committed\n")
            self.run_git(repository, "commit", "-am", "Update docs")
            (repository / "Docs").mkdir()
            (repository / "Docs" / "Design.md").write_text("Untracked\n")

            self.assertEqual(
                changed_paths(repository),
                {"README.md", "Docs/Design.md"},
            )

    @staticmethod
    def run_git(repository: Path, *arguments: str) -> None:
        subprocess.run(
            ("git", *arguments),
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
