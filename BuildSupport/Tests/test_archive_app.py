from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARCHIVE_SCRIPT = ROOT / "Scripts" / "archive-app.sh"


class ArchiveAppContractTests(unittest.TestCase):
    def test_archive_supports_explicit_unsigned_validation(self) -> None:
        contents = ARCHIVE_SCRIPT.read_text()

        self.assertIn('CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}"', contents)
        self.assertIn('CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED"', contents)

    def test_archive_can_opt_into_xcode_managed_provisioning(self) -> None:
        contents = ARCHIVE_SCRIPT.read_text()

        self.assertIn(
            'ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"',
            contents,
        )
        self.assertIn('if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]', contents)
        self.assertIn("XCODEBUILD_ARGS+=(-allowProvisioningUpdates)", contents)


if __name__ == "__main__":
    unittest.main()
