from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "BuildSupport"))

import accessibility_contract


class AccessibilityContractTests(unittest.TestCase):
    def test_folded_session_exposes_direct_controls_without_opening_more(self) -> None:
        baseline = accessibility_contract.inspect_hierarchy(
            {"label": "More Controls"},
            screen=accessibility_contract.AccessibilityScreen.folded_live,
        )
        self.assertFalse(baseline.is_ready)
        self.assertEqual(baseline.missing, ("Home", "Keyboard", "Lock", "Remote Controls", "Rotate"))

        folded = accessibility_contract.inspect_hierarchy(
            {"children": [{"label": label} for label in (
                "More Controls", "Remote Controls", "Home", "Lock", "Keyboard", "Rotate",
            )]},
            screen=accessibility_contract.AccessibilityScreen.folded_live,
        )
        self.assertTrue(folded.is_ready)

    def test_live_screen_exposes_only_the_corner_menu(self) -> None:
        for label in ("Home", "Lock", "Keyboard", "Rotate"):
            with self.subTest(label=label):
                result = accessibility_contract.inspect_hierarchy(
                    {"children": [{"label": "More Controls"}, {"label": label}]},
                    screen=accessibility_contract.AccessibilityScreen.live,
                )
                self.assertFalse(result.is_ready)
                self.assertEqual(result.unexpected, (label,))

        self.assertTrue(accessibility_contract.inspect_hierarchy(
            {"label": "More Controls"},
            screen=accessibility_contract.AccessibilityScreen.live,
        ).is_ready)

    def test_menu_contains_every_former_bar_action(self) -> None:
        labels = ("Home", "Lock", "Keyboard", "Rotate")
        for missing in labels:
            with self.subTest(missing=missing):
                result = accessibility_contract.inspect_hierarchy(
                    {"children": [{"label": label} for label in labels if label != missing]},
                    screen=accessibility_contract.AccessibilityScreen.controls_menu,
                )
                self.assertEqual(result.missing, (missing,))

        self.assertTrue(accessibility_contract.inspect_hierarchy(
            {"children": [{"label": label} for label in labels]},
            screen=accessibility_contract.AccessibilityScreen.controls_menu,
        ).is_ready)

    def test_incomplete_hierarchy_is_not_ready(self) -> None:
        result = accessibility_contract.inspect_hierarchy(
            {
                "children": [
                    {"role": "AXApplication"},
                    {"role": "AXGroup"},
                ]
            },
            screen=accessibility_contract.AccessibilityScreen.post_bootstrap,
        )

        self.assertFalse(result.is_ready)
        self.assertEqual(
            result.missing,
            (
                "Device Hub",
                "Pair Nearby Device",
                "Your Remote Screen Starts Here",
            ),
        )
        self.assertEqual(result.unexpected, ())

    def test_naming_hierarchy_is_ready_only_for_the_naming_contract(self) -> None:
        result = accessibility_contract.inspect_hierarchy(
            {
                "label": "Device Hub",
                "children": [
                    {"label": "Name This Device Hub"},
                    {"label": "Advertised Device Name"},
                ],
            },
            screen=accessibility_contract.AccessibilityScreen.naming,
        )

        self.assertTrue(result.is_ready)
        self.assertEqual(result.missing, ())
        self.assertEqual(result.unexpected, ())

    def test_post_bootstrap_hierarchy_is_ready(self) -> None:
        result = accessibility_contract.inspect_hierarchy(
            {
                "label": "Device Hub",
                "children": [
                    {"label": "Pair Nearby Device"},
                    {"label": "Your Remote Screen Starts Here"},
                ],
            },
            screen=accessibility_contract.AccessibilityScreen.post_bootstrap,
        )

        self.assertTrue(result.is_ready)
        self.assertEqual(result.missing, ())
        self.assertEqual(result.unexpected, ())

    def test_startup_failure_never_satisfies_the_contract(self) -> None:
        result = accessibility_contract.inspect_hierarchy(
            {
                "label": "Device Hub",
                "children": [
                    {"label": "Name This Device Hub"},
                    {"label": "Advertised Device Name"},
                    {"label": "Device Hub Couldn't Start"},
                ],
            },
            screen=accessibility_contract.AccessibilityScreen.naming,
        )

        self.assertFalse(result.is_ready)
        self.assertEqual(result.missing, ())
        self.assertEqual(result.unexpected, ("Device Hub Couldn't Start",))


if __name__ == "__main__":
    unittest.main()
