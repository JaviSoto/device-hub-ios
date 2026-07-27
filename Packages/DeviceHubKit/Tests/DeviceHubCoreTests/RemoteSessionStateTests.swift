import CustomDump
import DeviceHubCore
import Foundation
import Testing

struct RemoteSessionStateTests {
    private let deviceID = DeviceID(rawValue: "test-phone")
    private let generation = SessionGeneration(
        rawValue: UUID(
            uuid: (
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 1
            )
        )
    )
    private let nextGeneration = SessionGeneration(
        rawValue: UUID(
            uuid: (
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 2
            )
        )
    )
    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    @Test
    func connectionPhasesExposeExactCalmUserCopy() {
        expectNoDifference(
            ConnectionPhase.allCases,
            [
                .locating,
                .verifyingPairing,
                .openingTunnel,
                .discoveringServices,
                .preparingDeveloperServices,
                .capturingScreenshot,
                .startingDisplay,
                .ready
            ]
        )
        expectNoDifference(
            ConnectionPhase.allCases.map(\.title),
            [
                "Locating device…",
                "Verifying pairing…",
                "Opening secure connection…",
                "Discovering capabilities…",
                "Preparing device…",
                "Loading screen…",
                "Starting live view…",
                "Live"
            ]
        )
    }
}

extension RemoteSessionStateTests {
    @Test
    func provisionalScreenshotWaitsForNativeMediaOutcome() {
        let metadata = ScreenMetadata.screenshot(
            ScreenshotMetadata(
                generation: generation,
                receivedAt: now,
                pixelSize: PixelSize(width: 1179, height: 2556),
                orientation: .portrait
            )
        )

        expectNoDifference(
            ScreenFreshness.evaluate(metadata: nil, at: now),
            .awaitingFirstImage
        )
        expectNoDifference(
            ScreenFreshness.evaluate(
                metadata: metadata,
                at: now.addingTimeInterval(0.999)
            ),
            .awaitingFirstImage
        )
        expectNoDifference(
            ScreenFreshness.evaluate(
                metadata: metadata,
                at: now.addingTimeInterval(1)
            ),
            .awaitingFirstImage
        )
        expectNoDifference(
            ScreenFreshness.evaluate(
                metadata: metadata,
                at: now.addingTimeInterval(2.999)
            ),
            .awaitingFirstImage
        )
        expectNoDifference(
            ScreenFreshness.evaluate(
                metadata: metadata,
                at: now.addingTimeInterval(3)
            ),
            .awaitingFirstImage
        )
        expectNoDifference(
            ScreenFreshness.evaluate(
                metadata: metadata,
                at: now.addingTimeInterval(-1)
            ),
            .awaitingFirstImage
        )
    }

    @Test
    func staticVideoFrameRemainsLiveUntilTheSessionEnds() {
        let metadata = ScreenMetadata.videoFrame(
            FrameMetadata(
                generation: generation,
                sequenceNumber: 42,
                receivedAt: now,
                pixelSize: PixelSize(width: 1179, height: 2556),
                orientation: .portrait
            )
        )

        expectNoDifference(
            ScreenFreshness.evaluate(
                metadata: metadata,
                at: now.addingTimeInterval(60)
            ),
            .live
        )
    }

    @Test
    func staleGenerationUpdatesCannotChangeSessionState() throws {
        var state = RemoteSessionState(
            deviceID: deviceID,
            generation: generation
        )
        let staleGeneration = try SessionGeneration(
            rawValue: #require(UUID(
                uuidString: "00000000-0000-0000-0000-000000000099"
            ))
        )

        let disposition = state.apply(
            SessionUpdate(
                generation: staleGeneration,
                event: .phaseChanged(.ready)
            )
        )

        expectNoDifference(disposition, .rejectedStaleGeneration)
        expectNoDifference(state.connection, .connecting(.locating))
    }

    @Test
    func reconnectRotatesGenerationAndClearsPixelsAndInputReadiness() {
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
        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .videoFrame(
                    FrameMetadata(
                        generation: generation,
                        sequenceNumber: 1,
                        receivedAt: now,
                        pixelSize: PixelSize(width: 1179, height: 2556),
                        orientation: .portrait
                    )
                )
            )
        )

        let disposition = state.apply(
            SessionUpdate(
                generation: generation,
                event: .reconnected(nextGeneration)
            )
        )

        expectNoDifference(disposition, .accepted)
        expectNoDifference(state.generation, nextGeneration)
        expectNoDifference(state.connection, .connecting(.locating))
        expectNoDifference(state.hidReadiness, .connecting)
        #expect(state.latestScreen == nil)
    }

    @Test
    func metadataFromAnotherGenerationIsRejectedEvenInACurrentEnvelope() {
        var state = RemoteSessionState(
            deviceID: deviceID,
            generation: generation
        )
        let staleFrame = FrameMetadata(
            generation: nextGeneration,
            sequenceNumber: 1,
            receivedAt: now,
            pixelSize: PixelSize(width: 1179, height: 2556),
            orientation: .portrait
        )

        let disposition = state.apply(
            SessionUpdate(
                generation: generation,
                event: .videoFrame(staleFrame)
            )
        )

        expectNoDifference(disposition, .rejectedStaleGeneration)
        #expect(state.latestScreen == nil)
    }

    @Test
    func outOfOrderMediaCannotReplaceANewerFrame() {
        var state = readyState()
        let existingScreen = state.latestScreen
        let olderFrame = FrameMetadata(
            generation: generation,
            sequenceNumber: 0,
            receivedAt: now.addingTimeInterval(0.5),
            pixelSize: PixelSize(width: 1179, height: 2556),
            orientation: .portrait
        )
        let lateScreenshot = ScreenshotMetadata(
            generation: generation,
            receivedAt: now.addingTimeInterval(1),
            pixelSize: PixelSize(width: 1179, height: 2556),
            orientation: .portrait
        )

        expectNoDifference(
            state.apply(
                SessionUpdate(
                    generation: generation,
                    event: .videoFrame(olderFrame)
                )
            ),
            .rejectedOutOfOrderMedia
        )
        expectNoDifference(
            state.apply(
                SessionUpdate(
                    generation: generation,
                    event: .screenshot(lateScreenshot)
                )
            ),
            .rejectedOutOfOrderMedia
        )
        expectNoDifference(state.latestScreen, existingScreen)
    }

    @Test
    func presentationKeepsStaticVideoLiveWhileTransportIsOwned() {
        var state = readyState()

        expectNoDifference(state.presentation(at: now), .viewingOnly)
        expectNoDifference(state.presentation(at: now).title, "Viewing only")

        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .hidReadinessChanged(.ready)
            )
        )
        expectNoDifference(state.presentation(at: now), .live)
        expectNoDifference(state.presentation(at: now).title, "Live")
        expectNoDifference(
            state.presentation(at: now.addingTimeInterval(1)),
            .live
        )
        expectNoDifference(
            state.presentation(at: now.addingTimeInterval(1)).title,
            "Live"
        )
        expectNoDifference(
            state.presentation(at: now.addingTimeInterval(3)),
            .live
        )
        expectNoDifference(
            state.presentation(at: now.addingTimeInterval(3)).title,
            "Live"
        )
    }

    @Test
    func inputRequiresCurrentGenerationReadyHIDAndALiveFrame() {
        var state = readyState()
        let currentCommand = SessionCommand(
            generation: generation,
            command: .button(.home, phase: .press)
        )
        let staleCommand = SessionCommand(
            generation: nextGeneration,
            command: .button(.home, phase: .press)
        )

        #expect(!state.acceptsInput(currentCommand, at: now))
        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .hidReadinessChanged(.ready)
            )
        )
        #expect(state.acceptsInput(currentCommand, at: now))
        #expect(!state.acceptsInput(staleCommand, at: now))
        #expect(state.acceptsInput(
            currentCommand,
            at: now.addingTimeInterval(60)
        ))

        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .reachabilityChanged(.unavailable)
            )
        )
        #expect(!state.acceptsInput(currentCommand, at: now))
        expectNoDifference(state.presentation(at: now), .offline)
    }

    @Test
    func aFreshFrameAndReadyHIDStillCannotBypassConnectionSetup() {
        var state = RemoteSessionState(
            deviceID: deviceID,
            generation: generation
        )
        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .hidReadinessChanged(.ready)
            )
        )
        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .videoFrame(
                    FrameMetadata(
                        generation: generation,
                        sequenceNumber: 1,
                        receivedAt: now,
                        pixelSize: PixelSize(width: 1179, height: 2556),
                        orientation: .portrait
                    )
                )
            )
        )

        #expect(
            !state.acceptsInput(
                SessionCommand(
                    generation: generation,
                    command: .button(.home, phase: .press)
                ),
                at: now
            )
        )
    }

    @Test
    func screenshotIsAValidFirstVisualButConnectionCopyWinsUntilReady() {
        var state = RemoteSessionState(
            deviceID: deviceID,
            generation: generation
        )
        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .screenshot(
                    ScreenshotMetadata(
                        generation: generation,
                        receivedAt: now,
                        pixelSize: PixelSize(width: 1179, height: 2556),
                        orientation: .portrait
                    )
                )
            )
        )

        expectNoDifference(
            state.presentation(at: now),
            .connecting(.locating)
        )
        #expect(state.latestScreen?.kind == .screenshot)
    }

    @Test
    func anEndedSessionCannotAcceptInput() {
        var state = readyState()
        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .hidReadinessChanged(.ready)
            )
        )
        _ = state.apply(
            SessionUpdate(
                generation: generation,
                event: .ended(.deviceLocked)
            )
        )

        expectNoDifference(state.connection, .ended(.deviceLocked))
        expectNoDifference(
            state.presentation(at: now),
            .ended(.deviceLocked)
        )
        #expect(
            !state.acceptsInput(
                SessionCommand(
                    generation: generation,
                    command: .button(.home, phase: .press)
                ),
                at: now
            )
        )
    }

    private func readyState() -> RemoteSessionState {
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
                event: .videoFrame(
                    FrameMetadata(
                        generation: generation,
                        sequenceNumber: 1,
                        receivedAt: now,
                        pixelSize: PixelSize(width: 1179, height: 2556),
                        orientation: .portrait
                    )
                )
            )
        )
        return state
    }
}
