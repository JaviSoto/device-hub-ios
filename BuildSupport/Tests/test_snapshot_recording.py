from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SnapshotRecordingTests(unittest.TestCase):
    def test_one_method_recording_does_not_narrow_verification(self) -> None:
        contents = (ROOT / "Scripts" / "test-app.sh").read_text()

        self.assertIn('RECORD_SNAPSHOT_TEST="${DEVICE_HUB_RECORD_SNAPSHOT_TEST:-}"', contents)
        self.assertIn('if [[ "$record_mode" == "1" && -n "$RECORD_SNAPSHOT_TEST" ]]', contents)
        self.assertIn('snapshot_tests=("-only-testing:DeviceHubUITests/$RECORD_SNAPSHOT_TEST")', contents)
        self.assertIn('"${snapshot_tests[@]}"', contents)
        self.assertIn('-only-testing:DeviceHubUITests/DeviceHubVisualSnapshotTests', contents)
        self.assertIn('-only-testing:DeviceHubUITests/RemoteSessionFoldedControlsSnapshotTests', contents)
        self.assertIn('run_ui_snapshot_tests 0', contents)
