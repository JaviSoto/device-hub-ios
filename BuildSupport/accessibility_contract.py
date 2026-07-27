"""Validate Device Hub's clean first-run accessibility hierarchy."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any


class AccessibilityScreen(StrEnum):
    """User-visible checkpoints exercised by the clean-install CI flow."""

    naming = "naming"
    post_bootstrap = "post-bootstrap"


EXPECTED_VALUES = {
    AccessibilityScreen.naming: frozenset(
        {
            "Advertised Device Name",
            "Device Hub",
            "Name This Device Hub",
        }
    ),
    AccessibilityScreen.post_bootstrap: frozenset(
        {
            "Device Hub",
            "Pair Nearby Device",
            "Your Remote Screen Starts Here",
        }
    ),
}
BLOCKED_VALUES = frozenset(
    {
        "Device Hub Couldn't Start",
        "Pairing Couldn’t Be Restored",
    }
)


@dataclass(frozen=True)
class AccessibilityInspection:
    """One hierarchy's readiness and closed startup-failure vocabulary."""

    values: tuple[str, ...]
    missing: tuple[str, ...]
    unexpected: tuple[str, ...]

    @property
    def is_ready(self) -> bool:
        """Whether the hierarchy exposes the complete clean first-run UI."""

        return not self.missing and not self.unexpected


def _strings(value: object) -> list[str]:
    if isinstance(value, dict):
        return [item for nested in value.values() for item in _strings(nested)]
    if isinstance(value, list):
        return [item for nested in value for item in _strings(nested)]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def inspect_hierarchy(
    payload: object,
    *,
    screen: AccessibilityScreen,
) -> AccessibilityInspection:
    """Reduce AXe JSON to the user-visible first-run contract."""

    values = tuple(_strings(payload))
    value_set = frozenset(values)
    return AccessibilityInspection(
        values=values,
        missing=tuple(sorted(EXPECTED_VALUES[screen].difference(value_set))),
        unexpected=tuple(sorted(BLOCKED_VALUES.intersection(value_set))),
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("hierarchy", type=Path)
    parser.add_argument(
        "--screen",
        choices=tuple(AccessibilityScreen),
        default=AccessibilityScreen.post_bootstrap,
        type=AccessibilityScreen,
    )
    parser.add_argument(
        "--probe",
        action="store_true",
        help="Return readiness without printing an incomplete hierarchy.",
    )
    return parser


def main() -> int:
    """Validate one AXe capture, optionally as a silent readiness probe."""

    arguments = _parser().parse_args()
    try:
        payload: Any = json.loads(arguments.hierarchy.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        if not arguments.probe:
            print(f"AXe hierarchy could not be inspected: {error}")
        return 1

    inspection = inspect_hierarchy(payload, screen=arguments.screen)
    if inspection.is_ready:
        return 0
    if arguments.probe:
        return 1
    if inspection.unexpected:
        print(
            "Device Hub's clean simulator launch surfaced a startup failure; "
            f"unexpected={list(inspection.unexpected)!r}"
        )
    else:
        print(
            "AXe hierarchy did not expose Device Hub's clean first-run "
            "experience; "
            f"missing={list(inspection.missing)!r}; "
            f"sample={list(inspection.values[:20])!r}"
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
