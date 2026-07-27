from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import bootstrap_idevice


class IDeviceBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_directory = tempfile.TemporaryDirectory()
        cls.fixture_root = Path(cls.fixture_directory.name)
        cls.upstream = cls.fixture_root / "upstream"
        cls.patch = cls.fixture_root / "device-hub.patch"

        cls._git("init", "--initial-branch=main", str(cls.upstream))
        (cls.upstream / "src").mkdir(parents=True)
        (cls.upstream / "LICENSE.txt").write_text("MIT fixture\n")
        (cls.upstream / "src" / "value.txt").write_text("upstream\n")
        cls._git("-C", str(cls.upstream), "add", ".")
        cls._git(
            "-C",
            str(cls.upstream),
            "-c",
            "user.name=Device Hub Tests",
            "-c",
            "user.email=tests@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-m",
            "fixture",
        )
        cls.revision = cls._git(
            "-C", str(cls.upstream), "rev-parse", "HEAD"
        ).stdout.strip()

        (cls.upstream / "src" / "value.txt").write_text("device hub\n")
        patch_bytes = cls._git(
            "-C", str(cls.upstream), "diff", "--binary", "--full-index"
        ).stdout.encode()
        cls.patch.write_bytes(patch_bytes)
        cls.patch_sha256 = hashlib.sha256(patch_bytes).hexdigest()

        expected = cls.fixture_root / "expected"
        cls._git("clone", "--quiet", str(cls.upstream), str(expected))
        cls._git("-C", str(expected), "checkout", "--detach", cls.revision)
        cls._git("-C", str(expected), "apply", str(cls.patch))
        cls.tree_sha256 = bootstrap_idevice.tree_digest(expected)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fixture_directory.cleanup()

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.destination = self.root / "Vendor" / "idevice"
        self.specification = bootstrap_idevice.DependencySpecification(
            repository=str(self.upstream),
            revision=self.revision,
            patch=self.patch,
            patch_sha256=self.patch_sha256,
            tree_sha256=self.tree_sha256,
            destination=self.destination,
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_clean_bootstrap_checks_out_exact_revision_and_applies_patch(self) -> None:
        changed = bootstrap_idevice.bootstrap(self.specification)

        self.assertTrue(changed)
        self.assertEqual(
            (self.destination / "src" / "value.txt").read_text(),
            "device hub\n",
        )
        self.assertEqual(
            self._git("-C", str(self.destination), "rev-parse", "HEAD").stdout.strip(),
            self.revision,
        )
        self.assertEqual(
            bootstrap_idevice.tree_digest(self.destination),
            self.tree_sha256,
        )

    def test_bootstrap_is_idempotent_for_an_exact_existing_tree(self) -> None:
        bootstrap_idevice.bootstrap(self.specification)

        changed = bootstrap_idevice.bootstrap(self.specification)

        self.assertFalse(changed)
        self.assertEqual(
            (self.destination / "src" / "value.txt").read_text(),
            "device hub\n",
        )

    def test_patch_checksum_mismatch_fails_before_creating_destination(self) -> None:
        invalid = replace(self.specification, patch_sha256="0" * 64)

        with self.assertRaisesRegex(
            bootstrap_idevice.BootstrapError,
            "patch checksum",
        ):
            bootstrap_idevice.bootstrap(invalid)

        self.assertFalse(self.destination.exists())
        self.assertEqual(self._temporary_bootstrap_paths(), [])

    def test_patch_apply_failure_leaves_no_partial_destination(self) -> None:
        invalid_patch = self.root / "invalid.patch"
        invalid_patch.write_text(
            "diff --git a/missing.txt b/missing.txt\n"
            "--- a/missing.txt\n"
            "+++ b/missing.txt\n"
            "@@ -1 +1 @@\n"
            "-missing\n"
            "+replacement\n"
        )
        invalid = replace(
            self.specification,
            patch=invalid_patch,
            patch_sha256=hashlib.sha256(invalid_patch.read_bytes()).hexdigest(),
        )

        with self.assertRaisesRegex(
            bootstrap_idevice.BootstrapError,
            "apply cleanly",
        ):
            bootstrap_idevice.bootstrap(invalid)

        self.assertFalse(self.destination.exists())
        self.assertEqual(self._temporary_bootstrap_paths(), [])

    def test_tree_checksum_mismatch_leaves_no_partial_destination(self) -> None:
        invalid = replace(self.specification, tree_sha256="f" * 64)

        with self.assertRaisesRegex(
            bootstrap_idevice.BootstrapError,
            "tree checksum",
        ):
            bootstrap_idevice.bootstrap(invalid)

        self.assertFalse(self.destination.exists())
        self.assertEqual(self._temporary_bootstrap_paths(), [])

    def test_drift_fails_closed_without_replace(self) -> None:
        bootstrap_idevice.bootstrap(self.specification)
        (self.destination / "src" / "value.txt").write_text("local edit\n")

        with self.assertRaisesRegex(
            bootstrap_idevice.BootstrapError,
            "does not match",
        ):
            bootstrap_idevice.bootstrap(self.specification)

        self.assertEqual(
            (self.destination / "src" / "value.txt").read_text(),
            "local edit\n",
        )

    def test_explicit_replace_repairs_drift_and_preserves_build_cache(self) -> None:
        bootstrap_idevice.bootstrap(self.specification)
        (self.destination / "src" / "value.txt").write_text("local edit\n")
        target_cache = self.destination / "target" / "cache"
        target_cache.mkdir(parents=True)
        (target_cache / "artifact").write_text("generated\n")

        changed = bootstrap_idevice.bootstrap(self.specification, replace=True)

        self.assertTrue(changed)
        self.assertEqual(
            (self.destination / "src" / "value.txt").read_text(),
            "device hub\n",
        )
        self.assertEqual(
            (self.destination / "target" / "cache" / "artifact").read_text(),
            "generated\n",
        )
        self.assertEqual(self._temporary_bootstrap_paths(), [])

    def test_failed_atomic_install_restores_previous_tree(self) -> None:
        bootstrap_idevice.bootstrap(self.specification)
        (self.destination / "src" / "value.txt").write_text("local edit\n")
        real_replace = os.replace
        call_count = 0

        def fail_second_replace(source: Path, destination: Path) -> None:
            nonlocal call_count
            call_count += 1
            if call_count == 2:
                raise OSError("injected install failure")
            real_replace(source, destination)

        with mock.patch.object(
            bootstrap_idevice.os,
            "replace",
            side_effect=fail_second_replace,
        ), self.assertRaisesRegex(
            bootstrap_idevice.BootstrapError,
            "install",
        ):
            bootstrap_idevice.bootstrap(self.specification, replace=True)

        self.assertEqual(
            (self.destination / "src" / "value.txt").read_text(),
            "local edit\n",
        )
        self.assertEqual(self._temporary_bootstrap_paths(), [])

    def test_existing_lock_fails_before_writing(self) -> None:
        self.destination.parent.mkdir(parents=True)
        lock = self.destination.parent / ".idevice-bootstrap.lock"
        lock.write_text("other process\n")

        with self.assertRaisesRegex(
            bootstrap_idevice.BootstrapError,
            "already running",
        ):
            bootstrap_idevice.bootstrap(self.specification)

        self.assertFalse(self.destination.exists())

    def _temporary_bootstrap_paths(self) -> list[Path]:
        vendor = self.destination.parent
        if not vendor.exists():
            return []
        return sorted(
            path
            for path in vendor.iterdir()
            if path.name.startswith((".idevice-bootstrap-", ".idevice-previous-"))
        )

    @staticmethod
    def _git(*arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ("git", *arguments),
            check=True,
            capture_output=True,
            text=True,
        )


class RepositoryIDeviceDependencyContractTests(unittest.TestCase):
    def test_reviewed_patch_and_generated_tree_match_the_pinned_contract(self) -> None:
        specification = bootstrap_idevice.default_specification()

        self.assertEqual(
            specification.revision,
            "a64b8867815b3da17b5c927531bdba877e8456ef",
        )
        self.assertEqual(
            hashlib.sha256(specification.patch.read_bytes()).hexdigest(),
            specification.patch_sha256,
        )
        if specification.destination.is_dir():
            self.assertEqual(
                bootstrap_idevice.tree_digest(specification.destination),
                specification.tree_sha256,
            )


if __name__ == "__main__":
    unittest.main()
