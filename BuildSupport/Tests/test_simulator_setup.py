from __future__ import annotations

import importlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "BuildSupport"))
simulator_setup = importlib.import_module("simulator_setup")
sys.path.pop(0)

EXISTING_UDID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
CREATED_UDID = "11111111-2222-3333-4444-555555555555"


class FakeCommandRunner:
    def __init__(self, devices: list[dict[str, object]] | None = None) -> None:
        self.devices = devices or []
        self.calls: list[tuple[tuple[str, ...], bool]] = []
        self.fail_slim = False
        self.fail_verify = False
        self.managed_disabled = 0
        self.created_device_types: list[str] = []

    def __call__(self, arguments: tuple[str, ...], check: bool = True) -> str:
        self.calls.append((arguments, check))
        if arguments[1:5] == ("simctl", "list", "devices", "available"):
            return json.dumps({"devices": {"iOS 27.0": self.devices}})
        if arguments[1:4] == ("simctl", "list", "runtimes"):
            return json.dumps(
                {
                    "runtimes": [
                        {
                            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                            "isAvailable": True,
                        }
                    ]
                }
            )
        if arguments[1:4] == ("simctl", "list", "devicetypes"):
            return json.dumps(
                {
                    "devicetypes": [
                        {
                            "name": "iPhone 17 Pro",
                            "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                        },
                        {
                            "name": "iPad Pro 13-inch (M4)",
                            "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4",
                        },
                    ]
                }
            )
        if arguments[1:3] == ("simctl", "create"):
            self.created_device_types.append(arguments[4])
            self.devices.append(
                {
                    "udid": CREATED_UDID,
                    "name": arguments[3],
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            )
            return CREATED_UDID
        if arguments[0] == simulator_setup.SIMSLIM_PATH:
            operation = arguments[1]
            identifier = arguments[3] if operation == "status" else arguments[2]
            device = next(
                device for device in self.devices if device["udid"] == identifier
            )
            if operation == "on":
                if self.fail_slim:
                    raise simulator_setup.CommandError("simslim on failed")
                device["state"] = "Booted"
            elif operation == "verify":
                if self.fail_verify:
                    raise simulator_setup.CommandError("simslim profile drift")
            elif operation == "off":
                device["state"] = "Booted"
            elif operation == "status":
                return json.dumps(
                    {
                        "managedDisabled": self.managed_disabled,
                        "managedTotal": 170,
                        "booted": True,
                        "persistent": True,
                        "verdict": "stock" if self.managed_disabled == 0 else "slim",
                    }
                )
            else:
                raise AssertionError(f"unexpected simslim command: {arguments}")
            return ""
        if arguments[1:3] == ("simctl", "boot"):
            identifier = arguments[3]
            device = next(device for device in self.devices if device["udid"] == identifier)
            device["state"] = "Booted"
            return ""
        if arguments[1:3] == ("simctl", "bootstatus"):
            return ""
        if arguments[1:3] == ("simctl", "shutdown"):
            identifier = arguments[3]
            for device in self.devices:
                if device["udid"] == identifier:
                    device["state"] = "Shutdown"
            return ""
        if arguments[1:3] == ("simctl", "delete"):
            identifier = arguments[3]
            self.devices = [device for device in self.devices if device["udid"] != identifier]
            return ""
        raise AssertionError(f"unexpected command: {arguments}")


class SimulatorSetupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        temporary_root = Path(self.temporary_directory.name)
        self.simslim_path = temporary_root / "simslim"
        self.simslim_path.write_text("fixture executable\n")
        self.simslim_path.chmod(0o755)
        self.profile_path = temporary_root / "codex.json"
        self.profile_path.write_text('{"name":"codex","except":[],"keep":[]}\n')
        self.simslim_patch = mock.patch.object(
            simulator_setup, "SIMSLIM_PATH", str(self.simslim_path)
        )
        self.profile_patch = mock.patch.object(
            simulator_setup, "SIMSLIM_PROFILE_PATH", self.profile_path
        )
        self.simslim_patch.start()
        self.profile_patch.start()
        self.addCleanup(self.simslim_patch.stop)
        self.addCleanup(self.profile_patch.stop)
        self.which_patch = mock.patch.object(simulator_setup.shutil, "which", return_value=None)
        self.which_patch.start()
        self.addCleanup(self.which_patch.stop)

    def test_creates_unique_task_owned_simulator_and_profiles_same_udid(self) -> None:
        runner = FakeCommandRunner()

        prepared = simulator_setup.prepare_task_simulator(
            task_name="device-hub-test-app",
            run_command=runner,
        )

        self.assertEqual(prepared.identifier, CREATED_UDID)
        self.assertIn(" - Codex ", prepared.name)
        self.assertIn("device-hub-test-app", prepared.name)
        simslim_calls = [
            call
            for call, _check in runner.calls
            if call[0] == simulator_setup.SIMSLIM_PATH
        ]
        self.assertEqual([call[1] for call in simslim_calls], ["on", "verify"])
        self.assertEqual([call[2] for call in simslim_calls], [CREATED_UDID] * 2)
        self.assertEqual(
            simslim_calls[0][3:],
            ("--profile", str(self.profile_path)),
        )
        self.assertEqual(
            simslim_calls[1][3:],
            ("--profile", str(self.profile_path)),
        )

    def test_never_reuses_another_task_codex_simulator(self) -> None:
        runner = FakeCommandRunner(
            [
                {
                    "udid": EXISTING_UDID,
                    "name": "Other Task - Codex 12345678",
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            ]
        )

        prepared = simulator_setup.prepare_task_simulator(
            task_name="device-hub-test-app",
            run_command=runner,
        )

        self.assertEqual(prepared.identifier, CREATED_UDID)
        self.assertNotEqual(prepared.identifier, EXISTING_UDID)

    def test_requested_ipad_model_is_selected_exactly(self) -> None:
        runner = FakeCommandRunner()

        simulator_setup.prepare_task_simulator(
            task_name="device-hub-control-baseline",
            device_type_name="iPad Pro 13-inch (M4)",
            run_command=runner,
        )

        self.assertEqual(
            runner.created_device_types,
            ["com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4"],
        )

    def test_missing_home_profile_fails_before_device_creation(self) -> None:
        runner = FakeCommandRunner()
        self.profile_path.unlink()

        with self.assertRaisesRegex(
            simulator_setup.SimulatorSetupError,
            "simslim and its profile must both be available",
        ):
            simulator_setup.prepare_task_simulator(
                task_name="device-hub-test-app",
                run_command=runner,
            )

        self.assertFalse(any(call[1:3] == ("simctl", "create") for call, _ in runner.calls))

    def test_profile_failure_restores_and_deletes_only_the_created_device(self) -> None:
        runner = FakeCommandRunner()
        runner.fail_verify = True

        with self.assertRaisesRegex(
            simulator_setup.CommandError,
            "simslim profile drift",
        ):
            simulator_setup.prepare_task_simulator(
                task_name="device-hub-test-app",
                run_command=runner,
            )

        simslim_operations = [
            call[1]
            for call, _check in runner.calls
            if call[0] == simulator_setup.SIMSLIM_PATH
        ]
        self.assertEqual(simslim_operations, ["on", "verify", "off", "status"])
        self.assertEqual(runner.devices, [])
        deleted = [
            call[3]
            for call, _check in runner.calls
            if call[1:3] == ("simctl", "delete")
        ]
        self.assertEqual(deleted, [CREATED_UDID])

    def test_inherited_simulator_is_checked_by_exact_udid_and_name(self) -> None:
        name = "Device Hub Tests - Codex abcdef12"
        runner = FakeCommandRunner(
            [
                {
                    "udid": EXISTING_UDID,
                    "name": name,
                    "state": "Booted",
                    "isAvailable": True,
                }
            ]
        )

        simulator_setup.validate_task_simulator(
            EXISTING_UDID,
            name,
            run_command=runner,
        )

        self.assertEqual(
            [call[1] for call, _check in runner.calls if call[0] == simulator_setup.SIMSLIM_PATH],
            ["verify"],
        )

    def test_inherited_simulator_cannot_target_a_different_codex_name(self) -> None:
        runner = FakeCommandRunner(
            [
                {
                    "udid": EXISTING_UDID,
                    "name": "Other Task - Codex abcdef12",
                    "state": "Booted",
                    "isAvailable": True,
                }
            ]
        )

        with self.assertRaisesRegex(
            simulator_setup.SimulatorSetupError,
            "does not match the task-owned simulator",
        ):
            simulator_setup.validate_task_simulator(
                EXISTING_UDID,
                "Device Hub Tests - Codex abcdef12",
                run_command=runner,
            )

        self.assertFalse(any(call[0] == simulator_setup.SIMSLIM_PATH for call, _ in runner.calls))

    def test_cleanup_restores_stock_before_shutdown_and_delete(self) -> None:
        name = "Device Hub Tests - Codex abcdef12"
        runner = FakeCommandRunner(
            [
                {
                    "udid": EXISTING_UDID,
                    "name": name,
                    "state": "Booted",
                    "isAvailable": True,
                }
            ]
        )

        simulator_setup.cleanup_task_simulator(
            EXISTING_UDID,
            name,
            run_command=runner,
        )

        operations = [
            call[1:3]
            for call, _check in runner.calls
            if call[0] == simulator_setup.SIMSLIM_PATH
        ]
        self.assertEqual(operations, [("off", EXISTING_UDID), ("status", "--json")])
        shutdown = next(
            index
            for index, (call, _check) in enumerate(runner.calls)
            if call[1:3] == ("simctl", "shutdown")
        )
        delete = next(
            index
            for index, (call, _check) in enumerate(runner.calls)
            if call[1:3] == ("simctl", "delete")
        )
        status = next(
            index
            for index, (call, _check) in enumerate(runner.calls)
            if call[0] == simulator_setup.SIMSLIM_PATH and call[1] == "status"
        )
        self.assertLess(status, shutdown)
        self.assertLess(shutdown, delete)
        self.assertEqual(runner.devices, [])

    def test_cleanup_refuses_to_delete_until_stock_state_is_verified(self) -> None:
        name = "Device Hub Tests - Codex abcdef12"
        runner = FakeCommandRunner(
            [
                {
                    "udid": EXISTING_UDID,
                    "name": name,
                    "state": "Booted",
                    "isAvailable": True,
                }
            ]
        )
        runner.managed_disabled = 1

        with self.assertRaisesRegex(
            simulator_setup.SimulatorSetupError,
            "could not verify stock simulator services",
        ):
            simulator_setup.cleanup_task_simulator(
                EXISTING_UDID,
                name,
                run_command=runner,
            )

        self.assertFalse(
            any(call[1:3] in {("simctl", "shutdown"), ("simctl", "delete")} for call, _ in runner.calls)
        )

    def test_hosted_ci_without_simslim_uses_exact_direct_lifecycle(self) -> None:
        self.simslim_path.unlink()
        self.profile_path.unlink()
        runner = FakeCommandRunner()

        prepared = simulator_setup.prepare_task_simulator(
            task_name="device-hub-test-app",
            run_command=runner,
        )

        self.assertEqual(prepared.identifier, CREATED_UDID)
        self.assertTrue(
            any(call[1:3] == ("simctl", "boot") for call, _ in runner.calls)
        )
        self.assertFalse(any(call[0] == simulator_setup.SIMSLIM_PATH for call, _ in runner.calls))

    def test_test_app_builds_for_generic_simulator_before_device_creation(self) -> None:
        contents = (ROOT / "Scripts" / "test-app.sh").read_text()

        self.assertLess(contents.index("Scripts/build-app.sh"), contents.index("devicehub_require_simulator"))
        self.assertIn('generic/platform=iOS Simulator', contents)
        self.assertIn('Library/Developer/Xcode/DerivedData/DeviceHub', contents)
        self.assertNotIn('RUN_ROOT/DerivedData', contents)
        self.assertIn('CODE_SIGNING_ALLOWED=YES', contents)
        self.assertIn('DEVICE_HUB_TEST_EVIDENCE_DIR', contents)
        self.assertIn('devicehub_run_xcodebuild_test', contents)
        self.assertLess(
            contents.index('command -v "$XCBEAUTIFY_COMMAND"'),
            contents.index("devicehub_require_simulator"),
        )
        self.assertNotIn("codex-simulator-lease", contents)

    def test_native_test_producers_retain_formatted_evidence_and_derived_data(self) -> None:
        live_tests = (ROOT / "Scripts" / "test-live-ios.sh").read_text()
        snapshots = (ROOT / "Scripts" / "test-app.sh").read_text()
        dead_code = (ROOT / "Scripts" / "lint-dead-code.sh").read_text()

        self.assertIn("devicehub_run_xcodebuild_test", live_tests)
        self.assertIn("devicehub-live-tests-$RUN_ID.xcresult", live_tests)
        self.assertIn("Library/Developer/Xcode/DerivedData/DeviceHub", live_tests)
        self.assertNotIn("-quiet", live_tests)
        self.assertIn("devicehub_run_xcodebuild_test", snapshots)
        self.assertIn("devicehub-ui-snapshot-$pass_name-$RUN_ID.xcresult", snapshots)
        self.assertIn('DERIVED_DATA_PATH="$DERIVED_DATA_PATH"', snapshots)
        self.assertNotIn("-quiet", snapshots)
        self.assertIn('PACKAGE_DERIVED_DATA="$DERIVED_DATA_PATH/Periphery/DeviceHubKit"', dead_code)
        self.assertNotIn('mktemp -d', dead_code)

    def test_ci_keeps_release_outputs_in_native_derived_data(self) -> None:
        contents = (ROOT / "ci" / "run_ci.sh").read_text()

        self.assertIn("Library/Developer/Xcode/DerivedData/DeviceHub", contents)
        self.assertNotIn("mktemp -d", contents)
        self.assertNotIn("rm -rf", contents)
        self.assertNotIn("codex-simulator-lease", contents)

    def test_simulator_guard_has_no_retired_shared_supervisor_path(self) -> None:
        contents = (ROOT / "BuildSupport" / "simulator_guard.sh").read_text()

        self.assertNotIn("codex-simulator-lease", contents)
        self.assertIn('"$ROOT/BuildSupport/simulator_setup.py" prepare --name', contents)
        self.assertIn('"$ROOT/BuildSupport/simulator_setup.py" validate-task', contents)
        self.assertIn('"$ROOT/BuildSupport/simulator_setup.py" cleanup', contents)


if __name__ == "__main__":
    unittest.main()
