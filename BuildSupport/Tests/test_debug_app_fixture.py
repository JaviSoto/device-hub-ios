from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class DeviceHubDebugAppFixtureTests(unittest.TestCase):
    def test_live_session_streams_end_only_when_the_fixture_disconnects(self) -> None:
        source = (REPOSITORY_ROOT / "Sources/DeviceHubApp/DeviceHubDebugAppFixture.swift").read_text(
            encoding="utf-8"
        )
        start = source.index("private static func makeSession(")
        end = source.index("private static func makeRemoteScreenImage(", start)
        session_factory = source[start:end]
        disconnect = session_factory.index("disconnect: {")
        setup = session_factory[:disconnect]
        teardown = session_factory[disconnect:]

        self.assertIn("AsyncThrowingStream<SessionUpdate, Error>.makeStream()", setup)
        self.assertIn("AsyncStream<RemoteDisplayFrame>.makeStream()", setup)
        self.assertNotIn("continuation.finish()", setup)
        self.assertIn("eventSource.continuation.finish()", teardown)
        self.assertIn("frameSource.continuation.finish()", teardown)


if __name__ == "__main__":
    unittest.main()
