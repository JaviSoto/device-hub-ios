from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "BuildSupport"))

import accessibility_contract


class AccessibilityContractTests(unittest.TestCase):
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
