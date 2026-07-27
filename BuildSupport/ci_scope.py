"""Select the smallest safe local CI scope for the current Git checkout."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path
from typing import Iterable


def is_documentation_only(paths: Iterable[str]) -> bool:
    """Return whether every changed path is documentation."""
    changed_paths = tuple(paths)
    return bool(changed_paths) and all(
        path == "LICENSE"
        or path.endswith(".md")
        or path.startswith("Docs/")
        for path in changed_paths
    )


def _git_lines(repository: Path, *arguments: str) -> set[str]:
    result = subprocess.run(
        ("git", *arguments),
        cwd=repository,
        check=True,
        capture_output=True,
        text=True,
    )
    return {line for line in result.stdout.splitlines() if line}


def changed_paths(repository: Path) -> set[str]:
    """Return committed, staged, unstaged, and untracked local changes."""
    paths = _git_lines(
        repository,
        "diff",
        "--name-only",
        "--diff-filter=ACMRTUXB",
        "HEAD",
    )
    paths |= _git_lines(repository, "ls-files", "--others", "--exclude-standard")

    upstream = subprocess.run(
        ("git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"),
        cwd=repository,
        check=False,
        capture_output=True,
        text=True,
    )
    if upstream.returncode == 0:
        paths |= _git_lines(
            repository,
            "diff",
            "--name-only",
            "--diff-filter=ACMRTUXB",
            f"{upstream.stdout.strip()}...HEAD",
        )

    return paths


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    paths = changed_paths(arguments.repository.resolve())
    print("documentation" if is_documentation_only(paths) else "full")


if __name__ == "__main__":
    main()
