"""Validate Device Hub's first-run and remote-session accessibility hierarchy."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any


class AccessibilityScreen(StrEnum):
    """User-visible checkpoints exercised by app integration tests."""

    naming = "naming"
    post_bootstrap = "post-bootstrap"
    live = "live"
    folded_live = "folded-live"
    controls_menu = "controls-menu"


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
    AccessibilityScreen.live: frozenset({"More Controls"}),
    AccessibilityScreen.folded_live: frozenset(
        {"More Controls", "Remote Controls", "Home", "Lock", "Keyboard", "Rotate"}
    ),
    AccessibilityScreen.controls_menu: frozenset({"Home", "Lock", "Keyboard", "Rotate"}),
}
BLOCKED_VALUES = frozenset(
    {
        "Device Hub Couldn't Start",
        "Pairing Couldn’t Be Restored",
    }
)


@dataclass(frozen=True)
class AccessibilityInspection:
    """One hierarchy's required and forbidden visible controls."""

    values: tuple[str, ...]
    missing: tuple[str, ...]
    unexpected: tuple[str, ...]

    @property
    def is_ready(self) -> bool:
        """Whether the hierarchy satisfies the selected screen contract."""

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
    """Reduce AXe JSON to the selected screen's user-visible contract."""

    values = tuple(_strings(payload))
    value_set = frozenset(values)
    blocked_values = BLOCKED_VALUES
    if screen == AccessibilityScreen.live:
        blocked_values |= EXPECTED_VALUES[AccessibilityScreen.controls_menu]
    return AccessibilityInspection(
        values=values,
        missing=tuple(sorted(EXPECTED_VALUES[screen].difference(value_set))),
        unexpected=tuple(sorted(blocked_values.intersection(value_set))),
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
            f"Device Hub's {arguments.screen} screen exposed unexpected controls or a startup failure; "
            f"unexpected={list(inspection.unexpected)!r}"
        )
    else:
        print(
            f"AXe hierarchy did not expose Device Hub's {arguments.screen} screen; "
            f"missing={list(inspection.missing)!r}; "
            f"sample={list(inspection.values[:20])!r}"
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
