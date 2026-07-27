import DeviceHubClient
import DeviceHubFFI
@testable import DeviceHubLive
import DeviceHubTransport
import Testing

@Suite("Native session client composition")
@MainActor
struct DeviceHubNativeSessionClientTests {
    @Test("pairing client owns its handle through public session teardown")
    func pairingSession() async throws {
        let fixture = NativeExecutorFixture()
        let factory = try DeviceHubNativeSessionFactory(
            environment: .test(functions: fixture.recorder.functions)
        )

        let session = try await factory.client.makePairingSession(
            fixture.pairingRequest
        )
        try await session.start()
        try await session.cancel()

        #expect(
            fixture.recorder.calls == [
                .createPairing,
                .start,
                .cancel,
                .free
            ]
        )
    }

    @Test("remote client exposes compressed video without AVConference")
    func remoteSessionVideoLifecycle() async throws {
        let fixture = NativeExecutorFixture()
        let factory = try DeviceHubNativeSessionFactory(
            environment: .test(functions: fixture.recorder.functions)
        )

        let session = try await factory.client.makeRemoteSession(
            fixture.remoteRequest
        )
        #expect(
            session.videoEvents != nil,
            "Remote sessions must expose compressed video to the app decoder"
        )

        try await session.cancel()

        #expect(
            fixture.recorder.remoteConfiguration
                == .init(
                    operation: DH_REMOTE_OPERATION_CONTROL_STREAM,
                    negotiatorOfferByteCount: 0,
                    hasMediaCallback: true,
                    hasMediaContext: true
                )
        )
        #expect(
            fixture.recorder.calls == [
                .createRemote,
                .cancel,
                .free
            ]
        )
    }

    @Test(
        "Pair Verify probe authenticates to completion without media setup"
    )
    func pairVerifyProbeLifecycle() async throws {
        let fixture = NativeExecutorFixture(
            remoteStartEvents: .authenticatedThenCompleted
        )
        let factory = try DeviceHubNativeSessionFactory(
            environment: .test(functions: fixture.recorder.functions)
        )

        do {
            try await factory.client.verifyRemotePairing(
                fixture.remoteRequest
            )
        } catch let failure as NativeSessionFailure {
            Issue.record(
                """
                Expected Pair Verify success, got code=\(failure.code) \
                stage=\(failure.stage)
                """
            )
        } catch {
            Issue.record("Expected only a sanitized native failure.")
        }

        #expect(
            fixture.recorder.remoteConfiguration
                == .init(
                    operation: DH_REMOTE_OPERATION_PAIR_VERIFY,
                    negotiatorOfferByteCount: 0,
                    hasMediaCallback: false,
                    hasMediaContext: false
                )
        )
        #expect(
            fixture.recorder.calls == [
                .createRemote,
                .start,
                .cancel,
                .free
            ]
        )
    }
}

private extension DeviceHubNativeSessionFactory.Environment {
    @MainActor
    static func test(
        functions: DeviceHubNativeFunctionTable
    ) -> Self {
        Self(
            functions: functions,
            makeVideoBridge: { generation in
                try NativeVideoEventBridge(generation: generation)
            }
        )
    }
}
