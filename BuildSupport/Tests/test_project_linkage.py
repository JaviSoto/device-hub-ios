from __future__ import annotations

import subprocess
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
    def test_ios_runtime_version_guard_checks_numeric_versions(self) -> None:
        helper = REPOSITORY_ROOT / "BuildSupport/check_xcode_toolchain.sh"
        for version, expected in (
            ("27.0", False),
            ("27.1", True),
            ("27.2", True),
            ("28.0", True),
            ("27", False),
            ("27.invalid", False),
        ):
            with self.subTest(version=version):
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        'source "$1"; is_ios_271_or_later "$2"',
                        "bash",
                        str(helper),
                        version,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_ios_deployment_floor_is_271_across_app_and_native_inputs(self) -> None:
        project = PROJECT_SPECIFICATION.read_text(encoding="utf-8")
        package = (REPOSITORY_ROOT / "Packages/DeviceHubKit/Package.swift").read_text(
            encoding="utf-8"
        )
        build_xcframework = (REPOSITORY_ROOT / "Scripts/build-protocol-xcframework.sh").read_text(
            encoding="utf-8"
        )
        verify_xcframework = (REPOSITORY_ROOT / "Scripts/verify-protocol-xcframework.sh").read_text(
            encoding="utf-8"
        )
        private_media_tests = (REPOSITORY_ROOT / "Sources/DeviceHubPrivateMedia/Tests/run-tests.sh").read_text(
            encoding="utf-8"
        )
        probe_info = (REPOSITORY_ROOT / "Sources/DeviceHubPrivateMedia/Probe/Info.plist").read_text(
            encoding="utf-8"
        )

        self.assertTrue('iOS: "27.1"' in project, "XcodeGen must set iOS to 27.1")
        self.assertTrue(
            'xcodeVersion: "27.1"' in project,
            "XcodeGen metadata must require the Xcode 27.1 toolchain",
        )
        self.assertTrue(
            'IPHONEOS_DEPLOYMENT_TARGET: "27.1"' in project,
            "the app build setting must set iOS to 27.1",
        )
        self.assertTrue(
            '.iOS("27.1")' in package,
            "SwiftPM must set the iOS platform to 27.1",
        )
        self.assertTrue(
            'readonly DEPLOYMENT_TARGET="27.1"' in build_xcframework,
            "the Rust XCFramework slices must target iOS 27.1",
        )
        self.assertIn(
            "devicehub_check_xcode_toolchain",
            build_xcframework,
            "the Rust XCFramework build must use the shared Xcode and SDK check",
        )
        for build_entry in (
            "Scripts/build-app.sh",
            "Scripts/archive-app.sh",
            "Scripts/build-device-ipa.sh",
            "Scripts/test-live-ios.sh",
            "Sources/DeviceHubPrivateMedia/Tests/run-tests.sh",
        ):
            contents = (REPOSITORY_ROOT / build_entry).read_text(encoding="utf-8")
            self.assertIn(
                "devicehub_check_xcode_toolchain",
                contents,
                f"{build_entry} must enforce the shared Xcode and SDK floor",
            )
        self.assertTrue(
            'readonly EXPECTED_MINIMUM="27.1"' in verify_xcframework,
            "the XCFramework verifier must require iOS 27.1",
        )
        self.assertTrue(
            "-target arm64-apple-ios27.1" in private_media_tests,
            "the device probe must target iOS 27.1",
        )
        self.assertTrue(
            "-target \"$simulator_arch-apple-ios27.1-simulator\"" in private_media_tests,
            "the simulator probe must target iOS 27.1",
        )
        self.assertTrue(
            "<string>27.1</string>" in probe_info,
            "the probe bundle must declare iOS 27.1 as its minimum",
        )

    def test_app_bundles_the_third_party_notices(self) -> None:
        notices = REPOSITORY_ROOT / "THIRD_PARTY_NOTICES.md"
        app_target = target_block("DeviceHub")

        self.assertTrue(notices.is_file())
        self.assertIn(
            "- path: THIRD_PARTY_NOTICES.md\n        buildPhase: resources",
            app_target,
        )

    def test_app_build_keeps_bounded_logs_and_allows_the_personal_bundle_id(self) -> None:
        build = (REPOSITORY_ROOT / "Scripts/build-app.sh").read_text(
            encoding="utf-8"
        )
        app_target = target_block("DeviceHub")

        self.assertIn("run_logged.py", build)
        self.assertIn('-resultBundlePath "$BUILD_RESULT_BUNDLE"', build)
        self.assertIn(
            'DEVICE_HUB_BUNDLE_IDENTIFIER="${DEVICE_HUB_BUNDLE_IDENTIFIER:-es.javisoto.DeviceHub}"',
            build,
        )
        self.assertIn(
            'XCODEBUILD_ARGS+=("DEVICE_HUB_BUNDLE_IDENTIFIER=$DEVICE_HUB_BUNDLE_IDENTIFIER")',
            build,
        )
        self.assertIn(
            "DEVICE_HUB_BUNDLE_IDENTIFIER: es.javisoto.DeviceHub",
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
            "target: DeviceHubPrivateMedia\n        embed: false",
        ):
            self.assertIn(
                final_dependency,
                app_target,
                "the app must link but not embed each native dependency used by "
                "the static composition library",
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
