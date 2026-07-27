import DeviceHubCore
import Foundation
import Testing

struct RemoteSessionInputAuthorizationTests {
    @Test("A screenshot never authorizes input")
    func screenshotNeverAuthorizesInput() {
        let fixture = InputAuthorizationFixture()
        var state = fixture.readyState()
        _ = state.apply(
            SessionUpdate(
                generation: fixture.generation,
                event: .screenshot(
                    ScreenshotMetadata(
                        generation: fixture.generation,
                        receivedAt: fixture.now,
                        pixelSize: fixture.pixelSize,
                        orientation: .portrait
                    )
                )
            )
        )

        #expect(
            !state.acceptsInput(
                fixture.command,
                at: fixture.now
            )
        )
    }

    @Test("Connection readiness without a decoded video frame rejects input")
    func readinessWithoutVideoRejectsInput() {
        let fixture = InputAuthorizationFixture()
        var state = fixture.readyState()

        #expect(!state.acceptsInput(fixture.command, at: fixture.now))
        _ = state.apply(
            SessionUpdate(
                generation: fixture.generation,
                event: .displayReady
            )
        )
        #expect(!state.acceptsInput(fixture.command, at: fixture.now))
    }

    @Test("Cleanup is never accepted through the ordinary input gate")
    func cleanupBypassesOrdinaryInputAuthorization() {
        let fixture = InputAuthorizationFixture()
        var state = fixture.readyState()
        _ = state.apply(
            SessionUpdate(
                generation: fixture.generation,
                event: .videoFrame(fixture.frameMetadata)
            )
        )

        #expect(
            !state.acceptsInput(
                SessionCommand(
                    generation: fixture.generation,
                    command: .releaseAllInput
                ),
                at: fixture.now
            )
        )
    }
}

private struct InputAuthorizationFixture {
    let deviceID = DeviceID(rawValue: "test-phone")
    let generation = SessionGeneration(
        rawValue: UUID(
            uuid: (
                40, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        )
    )
    let now = Date(timeIntervalSince1970: 10000)
    let pixelSize = PixelSize(width: 1179, height: 2556)

    var frameMetadata: FrameMetadata {
        FrameMetadata(
            generation: generation,
            sequenceNumber: 1,
            receivedAt: now,
            pixelSize: pixelSize,
            orientation: .portrait
        )
    }

    var command: SessionCommand {
        SessionCommand(
            generation: generation,
            command: .button(.home, phase: .press)
        )
    }

    func readyState() -> RemoteSessionState {
        var state = RemoteSessionState(
            deviceID: deviceID,
            generation: generation
        )
        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .phaseChanged(.ready)
            )
        )
        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .hidReadinessChanged(.ready)
            )
        )
        return state
    }
}
