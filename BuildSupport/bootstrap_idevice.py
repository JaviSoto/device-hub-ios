#!/usr/bin/env python3
"""Materialize Device Hub's reviewed idevice source without a submodule."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
import uuid
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

IDEVICE_REPOSITORY = "https://github.com/jkcoxson/idevice.git"
IDEVICE_REVISION = "a64b8867815b3da17b5c927531bdba877e8456ef"
IDEVICE_PATCH_SHA256 = (
    "6654ef68a966f5a05e04470d08871e1f70f5b4747eb4d5865b6fcb2ea32d00bd"
)
IDEVICE_TREE_SHA256 = "80f7c0dd46982e888a7d6f6d209720ca492723ddc57bc7255c2ea1a6e19e3ee2"


class BootstrapError(RuntimeError):
    """A fail-closed dependency bootstrap failure suitable for CLI display."""


@dataclass(frozen=True)
class DependencySpecification:
    """Immutable source, patch, output, and integrity contract for a dependency."""

    repository: str
    revision: str
    patch: Path
    patch_sha256: str
    tree_sha256: str
    destination: Path


def default_specification() -> DependencySpecification:
    """Return the repository-owned idevice bootstrap contract."""

    repository = Path(__file__).resolve().parents[1]
    return DependencySpecification(
        repository=IDEVICE_REPOSITORY,
        revision=IDEVICE_REVISION,
        patch=repository / "Vendor" / "patches" / "idevice-device-hub.patch",
        patch_sha256=IDEVICE_PATCH_SHA256,
        tree_sha256=IDEVICE_TREE_SHA256,
        destination=repository / "Vendor" / "idevice",
    )


def tree_digest(root: Path) -> str:
    """Hash source paths, contents, symlink targets, and executable bits.

    Git metadata and Cargo build products are excluded. The resulting digest is
    stable across umasks and proves that an existing checkout is exactly the
    reviewed source tree.
    """

    if not root.is_dir():
        raise BootstrapError(f"dependency tree does not exist: {root}")

    digest = hashlib.sha256()
    paths = sorted(
        root.rglob("*"),
        key=lambda path: path.relative_to(root).as_posix(),
    )
    for path in paths:
        relative = path.relative_to(root)
        if ".git" in relative.parts or relative.parts[0] == "target":
            continue

        if path.is_symlink():
            kind = b"L"
            executable = b"-"
            contents = os.readlink(path).encode()
        elif path.is_file():
            kind = b"F"
            executable = b"x" if path.stat().st_mode & stat.S_IXUSR else b"-"
            contents = path.read_bytes()
        else:
            continue

        digest.update(kind)
        digest.update(executable)
        digest.update(relative.as_posix().encode())
        digest.update(b"\0")
        digest.update(contents)
        digest.update(b"\0")
    return digest.hexdigest()


def bootstrap(
    specification: DependencySpecification,
    *,
    replace: bool = False,
) -> bool:
    """Materialize and verify a dependency, returning whether it changed.

    Existing drift fails closed. Callers must opt into replacement explicitly;
    replacement is atomic and retains an existing Cargo ``target`` directory.
    """

    destination = specification.destination.resolve()
    vendor_directory = destination.parent
    vendor_directory.mkdir(parents=True, exist_ok=True)
    lock_path = vendor_directory / ".idevice-bootstrap.lock"

    with _exclusive_lock(lock_path):
        _verify_patch(specification)

        if destination.exists():
            if not destination.is_dir():
                raise BootstrapError(
                    f"dependency destination is not a directory: {destination}"
                )
            if tree_digest(destination) == specification.tree_sha256:
                return False
            if not replace:
                raise BootstrapError(
                    "existing idevice source does not match the reviewed tree; "
                    "remove local edits or rerun with --replace"
                )

        staging = Path(
            tempfile.mkdtemp(prefix=".idevice-bootstrap-", dir=vendor_directory)
        )
        try:
            _materialize(specification, staging)
            _install(staging, destination, replace=replace)
        finally:
            _remove_generated_tree(staging, vendor_directory)
    return True


def _verify_patch(specification: DependencySpecification) -> None:
    if not specification.patch.is_file():
        raise BootstrapError(f"idevice patch is missing: {specification.patch}")
    actual = hashlib.sha256(specification.patch.read_bytes()).hexdigest()
    if actual != specification.patch_sha256:
        raise BootstrapError(
            "idevice patch checksum does not match the reviewed contract"
        )


def _materialize(
    specification: DependencySpecification,
    staging: Path,
) -> None:
    _run_git(("init", "--quiet"), cwd=staging, purpose="initialize idevice checkout")
    _run_git(
        ("remote", "add", "origin", specification.repository),
        cwd=staging,
        purpose="configure idevice upstream",
    )
    _run_git(
        (
            "fetch",
            "--quiet",
            "--depth=1",
            "origin",
            specification.revision,
        ),
        cwd=staging,
        purpose="fetch pinned idevice revision",
    )
    _run_git(
        ("checkout", "--quiet", "--detach", "FETCH_HEAD"),
        cwd=staging,
        purpose="check out pinned idevice revision",
    )
    actual_revision = _run_git(
        ("rev-parse", "HEAD"),
        cwd=staging,
        purpose="verify idevice revision",
    ).strip()
    if actual_revision != specification.revision:
        raise BootstrapError("idevice checkout did not resolve to the pinned revision")

    try:
        _run_git(
            ("apply", "--check", str(specification.patch)),
            cwd=staging,
            purpose="verify idevice patch",
        )
    except BootstrapError as error:
        raise BootstrapError(
            "idevice patch does not apply cleanly to the pinned revision"
        ) from error
    _run_git(
        ("apply", str(specification.patch)),
        cwd=staging,
        purpose="apply idevice patch",
    )

    actual_tree = tree_digest(staging)
    if actual_tree != specification.tree_sha256:
        raise BootstrapError(
            "patched idevice tree checksum does not match the reviewed contract"
        )


def _install(staging: Path, destination: Path, *, replace: bool) -> None:
    if not destination.exists():
        try:
            os.replace(staging, destination)
        except OSError as error:
            raise BootstrapError("could not install the idevice source tree") from error
        return

    if not replace:
        raise BootstrapError(
            "refusing to replace an existing idevice source tree without --replace"
        )

    backup = destination.parent / f".idevice-previous-{uuid.uuid4().hex}"
    installed = False
    cache_moved = False
    try:
        os.replace(destination, backup)
        try:
            os.replace(staging, destination)
            installed = True
        except OSError as error:
            os.replace(backup, destination)
            raise BootstrapError("could not install the idevice source tree") from error

        previous_cache = backup / "target"
        if previous_cache.exists():
            os.replace(previous_cache, destination / "target")
            cache_moved = True
        _remove_generated_tree(backup, destination.parent)
    except Exception as error:
        if installed and backup.exists():
            try:
                if cache_moved and (destination / "target").exists():
                    os.replace(destination / "target", backup / "target")
                os.replace(destination, staging)
                os.replace(backup, destination)
            except OSError as rollback_error:
                raise BootstrapError(
                    "idevice install failed and the previous tree could not be restored"
                ) from rollback_error
        if isinstance(error, BootstrapError):
            raise
        raise BootstrapError("could not install the idevice source tree") from error


def _run_git(
    arguments: Sequence[str],
    *,
    cwd: Path,
    purpose: str,
) -> str:
    result = subprocess.run(
        ("git", *arguments),
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise BootstrapError(f"{purpose} failed")
    return result.stdout


@contextmanager
def _exclusive_lock(path: Path) -> Iterator[None]:
    try:
        descriptor = os.open(
            path,
            os.O_CREAT | os.O_EXCL | os.O_WRONLY,
            0o600,
        )
    except FileExistsError as error:
        raise BootstrapError("another idevice bootstrap is already running") from error

    try:
        os.write(descriptor, f"{os.getpid()}\n".encode())
        yield
    finally:
        os.close(descriptor)
        path.unlink(missing_ok=True)


def _remove_generated_tree(path: Path, allowed_parent: Path) -> None:
    if not path.exists():
        return
    resolved = path.resolve()
    if resolved.parent != allowed_parent.resolve() or not resolved.name.startswith(
        (".idevice-bootstrap-", ".idevice-previous-")
    ):
        raise BootstrapError(f"refusing to remove unexpected path: {resolved}")
    shutil.rmtree(resolved)


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Fetch the pinned idevice revision and apply Device Hub's reviewed patch."
        )
    )
    parser.add_argument(
        "--replace",
        action="store_true",
        help="atomically replace a drifted checkout while preserving Cargo build output",
    )
    return parser.parse_args()


def main() -> int:
    arguments = _parse_arguments()
    specification = default_specification()
    try:
        changed = bootstrap(specification, replace=arguments.replace)
    except BootstrapError as error:
        print(f"error: {error}", file=os.sys.stderr)
        return 1
    status = "materialized" if changed else "already current"
    print(
        f"idevice {specification.revision[:12]}: {status}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
