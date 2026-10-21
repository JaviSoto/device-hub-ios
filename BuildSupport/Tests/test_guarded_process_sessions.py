from __future__ import annotations

import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from guarded_process_test_support import (
    GuardedProcessTestCase,
    RUNNER,
    different_group_descendant_program,
    guarded_process,
    process_exists,
)



class GuardedProcessSessionTests(GuardedProcessTestCase):
    def test_test_service_cleanup_reports_the_inspection_failure(self) -> None:
        with (
            mock.patch.object(
                guarded_process,
                "cleanup_selected_xcode_test_service_hub",
                side_effect=OSError("process inspection timed out after 2 seconds"),
            ),
            mock.patch("sys.stderr") as stderr,
        ):
            status = guarded_process.main([
                "--cleanup-selected-xcode-test-service-hub",
                "--developer-dir", "/Applications/Xcode.app/Contents/Developer",
            ])

        self.assertEqual(status, 1)
        self.assertIn("process inspection timed out after 2 seconds", str(stderr.write.call_args_list))

    def test_session_inspection_fetches_commands_only_for_session_members(self) -> None:
        inspection_results = (
            subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout="101 1\n202 1\n303 202\n",
                stderr="",
            ),
            subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout="101 1 /usr/bin/one\n303 202 /usr/bin/three\n",
                stderr="",
            ),
        )
        with (
            mock.patch.object(
                guarded_process,
                "process_status_executable",
                return_value=Path("/bin/ps"),
            ),
            mock.patch.object(
                guarded_process.subprocess,
                "run",
                side_effect=inspection_results,
            ) as run_process_inspection,
            mock.patch.object(
                guarded_process.os,
                "getsid",
                side_effect=lambda process_id: {
                    101: 101,
                    202: 202,
                    303: 101,
                }[process_id],
            ) as get_session_id,
        ):
            members = guarded_process.process_session_members(101)

        self.assertEqual(
            members,
            (
                guarded_process.ProcessSessionMember(
                    process_id=101,
                    parent_process_id=1,
                    executable_path=Path("/usr/bin/one"),
                ),
                guarded_process.ProcessSessionMember(
                    process_id=303,
                    parent_process_id=202,
                    executable_path=Path("/usr/bin/three"),
                ),
            ),
        )
        self.assertEqual(
            get_session_id.call_args_list,
            [
                mock.call(101),
                mock.call(202),
                mock.call(303),
                mock.call(101),
                mock.call(303),
            ],
        )
        calls = run_process_inspection.call_args_list
        self.assertEqual(calls[0].args[0], ["/bin/ps", "-axo", "pid=,ppid="])
        self.assertEqual(
            calls[1].args[0],
            ["/bin/ps", "-p", "101,303", "-o", "pid=,ppid=,comm="],
        )

    def test_session_inspection_tolerates_members_exiting_before_detail_query(
        self,
    ) -> None:
        with (
            mock.patch.object(
                guarded_process,
                "process_status_executable",
                return_value=Path("/bin/ps"),
            ),
            mock.patch.object(
                guarded_process.subprocess,
                "run",
                side_effect=(
                    subprocess.CompletedProcess([], 0, "101 1\n", ""),
                    subprocess.CompletedProcess([], 1, "", ""),
                ),
            ) as run_process_inspection,
            mock.patch.object(
                guarded_process.os,
                "getsid",
                side_effect=(101, ProcessLookupError()),
            ) as get_session_id,
        ):
            members = guarded_process.process_session_members(101)

        self.assertEqual(members, ())
        self.assertEqual(
            get_session_id.call_args_list,
            [mock.call(101), mock.call(101)],
        )
        self.assertEqual(
            run_process_inspection.call_args_list[1].args[0],
            ["/bin/ps", "-p", "101", "-o", "pid=,ppid=,comm="],
        )

    def test_session_inspection_revalidates_ownership_after_detail_query(self) -> None:
        with (
            mock.patch.object(
                guarded_process,
                "process_status_executable",
                return_value=Path("/bin/ps"),
            ),
            mock.patch.object(
                guarded_process.subprocess,
                "run",
                side_effect=(
                    subprocess.CompletedProcess([], 0, "101 1\n", ""),
                    subprocess.CompletedProcess(
                        [], 0, "101 1 /usr/bin/reused-pid\n", ""
                    ),
                ),
            ),
            mock.patch.object(
                guarded_process.os,
                "getsid",
                side_effect=(101, 202),
            ),
        ):
            members = guarded_process.process_session_members(101)

        self.assertEqual(members, ())

    def test_session_inspection_fails_when_process_status_omits_live_member(
        self,
    ) -> None:
        with (
            mock.patch.object(
                guarded_process,
                "process_status_executable",
                return_value=Path("/bin/ps"),
            ),
            mock.patch.object(
                guarded_process.subprocess,
                "run",
                side_effect=(
                    subprocess.CompletedProcess([], 0, "101 1\n", ""),
                    subprocess.CompletedProcess([], 1, "", ""),
                ),
            ),
            mock.patch.object(
                guarded_process.os,
                "getsid",
                return_value=101,
            ),
        ):
            with self.assertRaisesRegex(
                OSError,
                "process inspection omitted live session members",
            ):
                guarded_process.process_session_members(101)

    def test_session_inventory_does_not_treat_no_match_as_an_empty_session(
        self,
    ) -> None:
        with (
            mock.patch.object(
                guarded_process,
                "process_status_executable",
                return_value=Path("/bin/ps"),
            ),
            mock.patch.object(
                guarded_process.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 1, "", ""),
            ),
        ):
            with self.assertRaisesRegex(OSError, "exited with status 1"):
                guarded_process.process_session_members(101)

    def test_session_inspection_distinguishes_timeout_from_exit_status(self) -> None:
        failures = (
            (
                subprocess.TimeoutExpired(["/bin/ps"], 2.0),
                "timed out",
            ),
            (
                subprocess.CompletedProcess(["/bin/ps"], 9, "", ""),
                "exited with status 9",
            ),
        )
        for failure, message in failures:
            with self.subTest(message=message):
                side_effect = (
                    failure
                    if isinstance(failure, BaseException)
                    else lambda *_args, **_kwargs: failure
                )
                with (
                    mock.patch.object(
                        guarded_process,
                        "process_status_executable",
                        return_value=Path("/bin/ps"),
                    ),
                    mock.patch.object(
                        guarded_process.subprocess,
                        "run",
                        side_effect=side_effect,
                    ),
                ):
                    with self.assertRaisesRegex(OSError, message):
                        guarded_process.process_session_members(101)

    @unittest.skipUnless(
        sys.platform == "darwin",
        "CoreSimulator runtime services exist only on macOS",
    )
    def test_managed_simulator_runtime_is_not_a_background_leak(self) -> None:
        runtime_service = guarded_process.ProcessSessionMember(
            process_id=53742,
            parent_process_id=53308,
            executable_path=Path(
                "/Library/Developer/CoreSimulator/Volumes/iOS_24A5380g/"
                "Library/Developer/CoreSimulator/Profiles/Runtimes/"
                "iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/"
                "System/Library/PrivateFrameworks/"
                "DVTInstrumentsFoundation.framework/DTServiceHub"
            ),
        )
        leaked_build_tools = (
            guarded_process.ProcessSessionMember(
                process_id=61001,
                parent_process_id=1,
                executable_path=Path("/usr/bin/xcodebuild"),
            ),
            guarded_process.ProcessSessionMember(
                process_id=61002,
                parent_process_id=1,
                executable_path=Path("/usr/bin/swift"),
            ),
            guarded_process.ProcessSessionMember(
                process_id=61003,
                parent_process_id=1,
                executable_path=Path("/Users/example/.cargo/bin/cargo"),
            ),
            guarded_process.ProcessSessionMember(
                process_id=61004,
                parent_process_id=1,
                executable_path=Path(
                    "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl"
                ),
            ),
            guarded_process.ProcessSessionMember(
                process_id=61005,
                parent_process_id=1,
                executable_path=Path(
                    "/Library/Developer/CoreSimulator/Volumes-untrusted/" "DTServiceHub"
                ),
            ),
        )

        remaining = guarded_process.background_processes_requiring_cleanup(
            (runtime_service, *leaked_build_tools),
            preserve_managed_simulator_services=True,
        )
        interrupted_cleanup = guarded_process.background_processes_requiring_cleanup(
            (runtime_service, *leaked_build_tools),
            preserve_managed_simulator_services=False,
        )

        self.assertEqual(remaining, leaked_build_tools)
        self.assertEqual(
            interrupted_cleanup,
            (runtime_service, *leaked_build_tools),
        )

    def test_selected_xcode_test_service_hub_matches_only_exact_toolchain(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            developer_directory = root / "Xcode-beta.app" / "Contents" / "Developer"
            service_hub = (
                developer_directory.parent
                / "SharedFrameworks"
                / "DVTInstrumentsFoundation.framework"
                / "Resources"
                / "DTServiceHub"
            )
            service_hub.parent.mkdir(parents=True)
            service_hub.touch()

            selected = guarded_process.ProcessSessionMember(
                process_id=62001,
                parent_process_id=1,
                executable_path=service_hub,
            )
            other_toolchain = guarded_process.ProcessSessionMember(
                process_id=62002,
                parent_process_id=1,
                executable_path=(
                    root
                    / "Other-Xcode.app"
                    / "Contents"
                    / "SharedFrameworks"
                    / "DVTInstrumentsFoundation.framework"
                    / "Resources"
                    / "DTServiceHub"
                ),
            )
            similarly_named = guarded_process.ProcessSessionMember(
                process_id=62003,
                parent_process_id=1,
                executable_path=developer_directory.parent / "DTServiceHub",
            )

            self.assertTrue(
                guarded_process.is_selected_xcode_test_service_hub(
                    selected,
                    developer_directory=developer_directory,
                )
            )
            self.assertFalse(
                guarded_process.is_selected_xcode_test_service_hub(
                    other_toolchain,
                    developer_directory=developer_directory,
                )
            )
            self.assertFalse(
                guarded_process.is_selected_xcode_test_service_hub(
                    similarly_named,
                    developer_directory=developer_directory,
                )
            )

    def test_cleanup_selected_xcode_test_service_hub_targets_only_service(
        self,
    ) -> None:
        developer_directory = Path("/Applications/Xcode-beta.app/Contents/Developer")
        service_hub = guarded_process.ProcessSessionMember(
            process_id=63001,
            parent_process_id=1,
            executable_path=(
                developer_directory.parent
                / "SharedFrameworks"
                / "DVTInstrumentsFoundation.framework"
                / "Resources"
                / "DTServiceHub"
            ),
        )
        unrelated = guarded_process.ProcessSessionMember(
            process_id=63002,
            parent_process_id=1,
            executable_path=Path("/Users/example/.cargo/bin/cargo"),
        )

        with (
            mock.patch.object(
                guarded_process,
                "process_session_members",
                side_effect=((service_hub, unrelated), (unrelated,)),
            ),
            mock.patch.object(
                guarded_process,
                "signal_process_session_members",
            ) as signal_members,
            mock.patch.object(
                guarded_process,
                "wait_for_known_session_members",
            ) as wait_for_members,
        ):
            cleaned = guarded_process.cleanup_selected_xcode_test_service_hub(
                424242,
                developer_directory=developer_directory,
                grace_seconds=0.25,
            )

        self.assertTrue(cleaned)
        signal_members.assert_called_once_with(
            424242,
            (service_hub,),
            signal.SIGTERM,
        )
        wait_for_members.assert_called_once()

