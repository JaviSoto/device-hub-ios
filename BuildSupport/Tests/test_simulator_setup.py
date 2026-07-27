from __future__ import annotations

import importlib
import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "BuildSupport"))
simulator_setup = importlib.import_module("simulator_setup")
sys.path.pop(0)


class FakeCommandRunner:
    def __init__(self, devices: list[dict[str, object]]) -> None:
        self.devices = devices
        self.calls: list[tuple[tuple[str, ...], bool]] = []
        self.fail_registration = False
        self.hide_created_simulator = False

    def __call__(self, arguments: tuple[str, ...], check: bool = True) -> str:
        self.calls.append((arguments, check))
        if arguments[1:5] == ("simctl", "list", "devices", "available"):
            devices = (
                [
                    device
                    for device in self.devices
                    if device["udid"] != "11111111-2222-3333-4444-555555555555"
                ]
                if self.hide_created_simulator
                else self.devices
            )
            return json.dumps({"devices": {"iOS 27.0": devices}})
        if arguments[1:4] == ("simctl", "list", "runtimes"):
            return json.dumps(
                {
                    "runtimes": [
                        {
                            "identifier": (
                                "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
                            ),
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
                            "identifier": (
                                "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
                            ),
                        }
                    ]
                }
            )
        if arguments[1:3] == ("simctl", "create"):
            identifier = "11111111-2222-3333-4444-555555555555"
            self.devices.append(
                {
                    "udid": identifier,
                    "name": simulator_setup.MANAGED_SIMULATOR_NAME,
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            )
            return identifier
        if arguments[1:3] == ("simctl", "shutdown"):
            identifier = arguments[3]
            for device in self.devices:
                if device["udid"] == identifier:
                    device["state"] = "Shutdown"
            return ""
        if arguments[1:3] == ("simctl", "delete"):
            identifier = arguments[3]
            self.devices = [
                device for device in self.devices if device["udid"] != identifier
            ]
            return ""
        if arguments[1] == "register":
            if self.fail_registration:
                raise simulator_setup.CommandError("registration failed")
            return ""
        if arguments[1] == "boot":
            return ""
        if arguments[1:3] == ("simctl", "boot"):
            return ""
        if arguments[1:3] == ("simctl", "bootstatus"):
            return ""
        if arguments[1:3] == ("status", "--json"):
            return json.dumps(
                {
                    "active": True,
                    "active_udid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                }
            )
        raise AssertionError(f"unexpected command: {arguments}")


class SimulatorSetupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = {
            "CODEX_SIMULATOR_LEASE_ID": "lease-id",
            "CODEX_SIMULATOR_LEASE_COMMAND": "/tmp/codex-simulator-lease",
        }

    def test_reuses_one_exact_managed_simulator(self) -> None:
        identifier = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        runner = FakeCommandRunner(
            [
                {
                    "udid": identifier,
                    "name": simulator_setup.MANAGED_SIMULATOR_NAME,
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            ]
        )

        result = simulator_setup.prepare_simulator(
            environment=self.environment,
            run_command=runner,
        )

        self.assertEqual(result, identifier)
        register = next(call for call, _check in runner.calls if call[1] == "register")
        self.assertNotIn("--created", register)
        self.assertEqual(runner.calls[-1][0][1:], ("boot", "--udid", identifier))

    def test_creates_registers_and_boots_when_no_managed_simulator_exists(
        self,
    ) -> None:
        runner = FakeCommandRunner([])

        result = simulator_setup.prepare_simulator(
            environment=self.environment,
            run_command=runner,
        )

        self.assertEqual(result, "11111111-2222-3333-4444-555555555555")
        register = next(call for call, _check in runner.calls if call[1] == "register")
        self.assertIn("--created", register)
        register_index = next(
            index
            for index, (call, _check) in enumerate(runner.calls)
            if call[1] == "register"
        )
        boot_index = next(
            index
            for index, (call, _check) in enumerate(runner.calls)
            if call[1] == "boot"
        )
        self.assertLess(register_index, boot_index)

    def test_ambiguous_managed_simulators_fail_without_mutation(self) -> None:
        devices = [
            {
                "udid": identifier,
                "name": simulator_setup.MANAGED_SIMULATOR_NAME,
                "state": "Shutdown",
                "isAvailable": True,
            }
            for identifier in (
                "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            )
        ]
        runner = FakeCommandRunner(devices)

        with self.assertRaisesRegex(
            simulator_setup.SimulatorSetupError,
            "exactly one",
        ):
            simulator_setup.prepare_simulator(
                environment=self.environment,
                run_command=runner,
            )

        self.assertFalse(
            any(call[1] in {"create", "register", "boot"} for call, _ in runner.calls)
        )

    def test_forged_lease_environment_cannot_skip_supervisor_validation(self) -> None:
        runner = FakeCommandRunner([])
        runner.fail_registration = True

        with self.assertRaisesRegex(
            simulator_setup.CommandError,
            "registration failed",
        ):
            simulator_setup.prepare_simulator(
                environment=self.environment,
                run_command=runner,
            )

        self.assertTrue(any(call[1] == "register" for call, _ in runner.calls))

    def test_registration_failure_removes_only_the_just_created_simulator(
        self,
    ) -> None:
        runner = FakeCommandRunner([])
        runner.fail_registration = True

        with self.assertRaises(simulator_setup.CommandError):
            simulator_setup.prepare_simulator(
                environment=self.environment,
                run_command=runner,
            )

        delete_calls = [
            call for call, _check in runner.calls if call[1:3] == ("simctl", "delete")
        ]
        self.assertEqual(
            delete_calls,
            [
                (
                    simulator_setup.XCRUN,
                    "simctl",
                    "delete",
                    "11111111-2222-3333-4444-555555555555",
                )
            ],
        )
        self.assertEqual(runner.devices, [])

    def test_unverified_creation_is_removed_before_failing(self) -> None:
        runner = FakeCommandRunner([])
        runner.hide_created_simulator = True

        with self.assertRaisesRegex(
            simulator_setup.SimulatorSetupError,
            "could not be verified",
        ):
            simulator_setup.prepare_simulator(
                environment=self.environment,
                run_command=runner,
            )

        self.assertTrue(
            any(call[1:3] == ("simctl", "delete") for call, _ in runner.calls)
        )

    def test_nested_shared_uuid_is_checked_against_supervisor_state(self) -> None:
        runner = FakeCommandRunner([])

        simulator_setup.validate_shared_simulator(
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            environment=self.environment,
            run_command=runner,
        )

        self.assertEqual(
            runner.calls[-1][0],
            ("/tmp/codex-simulator-lease", "status", "--json"),
        )

    def test_entrypoints_use_the_shared_supervisor_contract(self) -> None:
        for relative_path in (
            Path("Scripts/test-app.sh"),
            Path("Sources/DeviceHubPrivateMedia/Tests/run-tests.sh"),
        ):
            with self.subTest(path=relative_path):
                contents = (ROOT / relative_path).read_text()

                self.assertIn("devicehub_require_simulator", contents)
                self.assertNotIn("BuildSupport/simulator_lease.py", contents)
                self.assertNotIn("DEVICE_HUB_SIMULATOR_LEASE_HELD", contents)
                self.assertNotIn("CI_SIMULATOR_UDID", contents)

    def test_outer_wrapper_discards_stale_project_udid(self) -> None:
        contents = (ROOT / "BuildSupport" / "simulator_guard.sh").read_text()

        self.assertIn("unset DEVICE_HUB_SIMULATOR_UDID", contents)
        self.assertIn("CODEX_SIMULATOR_LEASE_ID", contents)
        self.assertIn("CODEX_SIMULATOR_LEASE_COMMAND", contents)
        self.assertIn("DEVICE_HUB_SIMULATOR_CLEANUP_REQUIRED", contents)


if __name__ == "__main__":
    unittest.main()
