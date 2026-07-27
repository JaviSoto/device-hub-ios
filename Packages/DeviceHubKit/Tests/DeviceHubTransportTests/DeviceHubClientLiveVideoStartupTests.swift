import CustomDump
import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Live Device Hub video startup")
struct DeviceHubClientLiveVideoStartupTests {
    private let generation = SessionGeneration(
        rawValue: UUID(uuid: (
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 9
        ))
    )

    @Test("video consumption starts before the native callback burst")
    func videoConsumptionStartsBeforeNativeCallbacks() async throws {
        let ingress = VideoIngressProbe()
        let videoBridge = try NativeVideoEventBridge(
            generation: generation,
            bufferCapacity: 1
        )
        let controlEvents = AsyncThrowingStream<
            NativeSessionEvent,
            Error
        >.makeStream()
        let nativeSession = NativeSession(
            events: controlEvents.stream,
            videoEvents: videoBridge.events,
            start: {
                for sequenceNumber in 1 ... 3 {
                    await ingress.record(
                        receiveStartupVideoConfiguration(
                            on: videoBridge,
                            sequenceNumber: UInt64(sequenceNumber)
                        )
                    )
                    await Task.yield()
                }
            },
            completePersistence: { _, _ in },
            send: { _ in },
            cancel: {
                _ = videoBridge.cancel()
                controlEvents.continuation.finish()
            }
        )
        let native = NativeSessionClient(
            capabilities: .requiredLiveControl,
            makePairingSession: { _ async throws(NativeSessionFailure) in
                throw NativeSessionFailure(
                    code: "invalid_state",
                    stage: "session_lifecycle",
                    retryable: false
                )
            },
            makeRemoteSession: { _ async throws(NativeSessionFailure) in
                nativeSession
            }
        )
        let persistence = try PersistenceProbe(
            records: [fixtureRecord()]
        )
        let bonjour = try BonjourClientProbe(
            availability: [],
            resolvedService: fixtureRemoteService()
        )
        let client = try makeClient(
            nativeSessions: native,
            persistence: persistence.client,
            bonjour: bonjour.client
        )

        let session = try await client.connect(deviceID)
        let results = await ingress.results
        await session.disconnect()

        expectNoDifference(
            results,
            [.accepted, .accepted, .accepted]
        )
    }
}

private actor VideoIngressProbe {
    private(set) var results: [NativeVideoIngressResult] = []

    func record(_ result: NativeVideoIngressResult) {
        results.append(result)
    }
}

private func receiveStartupVideoConfiguration(
    on bridge: NativeVideoEventBridge,
    sequenceNumber: UInt64
) -> NativeVideoIngressResult {
    let video = [UInt8](arrayLiteral: 0x40, 0x01)
    let sequence = [UInt8](arrayLiteral: 0x42, 0x01)
    let picture = [UInt8](arrayLiteral: 0x44, 0x01)
    return video.withUnsafeBytes { videoBytes in
        sequence.withUnsafeBytes { sequenceBytes in
            picture.withUnsafeBytes { pictureBytes in
                bridge.receiveConfiguration(
                    sequenceNumber: sequenceNumber,
                    videoParameterSet: videoBytes,
                    sequenceParameterSet: sequenceBytes,
                    pictureParameterSet: pictureBytes
                )
            }
        }
    }
}
