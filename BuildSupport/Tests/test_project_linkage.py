from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PROJECT_SPECIFICATION = REPOSITORY_ROOT / "project.yml"


def target_block(name: str) -> str:
    """Return one top-level target mapping from the XcodeGen specification."""

    lines = PROJECT_SPECIFICATION.read_text(encoding="utf-8").splitlines()
    header = f"  {name}:"
    try:
        start = lines.index(header)
    except ValueError as error:
        raise AssertionError(f"missing target {name}") from error

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.startswith("  ") and not line.startswith("    ") and line.endswith(":"):
            end = index
            break
    return "\n".join(lines[start:end])


class ProjectLinkageTests(unittest.TestCase):
    def test_app_bundles_the_third_party_notices(self) -> None:
        notices = REPOSITORY_ROOT / "THIRD_PARTY_NOTICES.md"
        app_target = target_block("DeviceHub")

        self.assertTrue(notices.is_file())
        self.assertIn(
            "- path: THIRD_PARTY_NOTICES.md\n        buildPhase: resources",
            app_target,
        )

    def test_private_media_allows_the_simulator_app_to_be_signed(self) -> None:
        private_media_target = target_block("DeviceHubPrivateMedia")

        self.assertIn(
            'GENERATE_INFOPLIST_FILE: "YES"',
            private_media_target,
            "the static framework still needs bundle metadata when Xcode "
            "signs the containing simulator build",
        )

    def test_live_composition_is_linked_once_into_each_final_binary(self) -> None:
        live_target = target_block("DeviceHubLive")
        app_target = target_block("DeviceHub")

        self.assertIn(
            "type: library.static",
            live_target,
            "DeviceHubLive must be a static library so package products are "
            "linked only by each final app or test binary",
        )
        self.assertNotIn(
            "MACH_O_TYPE:",
            live_target,
            "a static framework merges package dependencies into itself; use "
            "a real static-library target instead",
        )
        for compile_only_dependency in (
            "- framework: Rust/Artifacts/DeviceHubFFI.xcframework\n"
            "        embed: false\n"
            "        link: false",
            "- target: DeviceHubPrivateMedia\n"
            "        link: false",
            "- package: DeviceHubKit\n"
            "        product: DeviceHubCore\n"
            "        link: false",
            "- package: DeviceHubKit\n"
            "        product: DeviceHubClient\n"
            "        link: false",
            "- package: DeviceHubKit\n"
            "        product: DeviceHubDiagnostics\n"
            "        link: false",
            "- package: DeviceHubKit\n"
            "        product: DeviceHubPersistence\n"
            "        link: false",
            "- package: DeviceHubKit\n"
            "        product: DeviceHubTransport\n"
            "        link: false",
        ):
            self.assertIn(
                compile_only_dependency,
                live_target,
                "DeviceHubLive dependencies must be compile-only so its "
                "static archive contains only DeviceHubLive objects",
            )
        for final_product in (
            "DeviceHubCore",
            "DeviceHubClient",
            "DeviceHubDiagnostics",
            "DeviceHubFeature",
            "DeviceHubPersistence",
            "DeviceHubTransport",
            "DeviceHubUI",
        ):
            self.assertIn(
                f"product: {final_product}",
                app_target,
                "the app must link every package product it imports",
            )
        self.assertIn(
            "- target: DeviceHubLive\n        embed: false",
            app_target,
            "the static DeviceHubLive composition target must be linked but "
            "never embedded",
        )
        for final_dependency in (
            "framework: Rust/Artifacts/DeviceHubFFI.xcframework",
            "target: DeviceHubPrivateMedia",
        ):
            self.assertIn(
                final_dependency,
                app_target,
                "the app must link each native dependency used by the static "
                "composition library",
            )

        tests_target = target_block("DeviceHubLiveTests")
        self.assertIn(
            "- target: DeviceHubLive\n        embed: false",
            tests_target,
            "the static DeviceHubLive composition target must not be embedded "
            "in the test bundle",
        )
        for final_product in (
            "DeviceHubCore",
            "DeviceHubClient",
            "DeviceHubDiagnostics",
            "DeviceHubPersistence",
            "DeviceHubTransport",
        ):
            self.assertIn(
                f"product: {final_product}",
                tests_target,
                "the test bundle must link every package product it imports",
            )


if __name__ == "__main__":
    unittest.main()
