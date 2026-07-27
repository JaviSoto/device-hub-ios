import CustomDump
import DeviceHubCore
@testable import DeviceHubTransport
import Dispatch
import Foundation
import Testing

@Suite("Native video boundary")
struct NativeVideoBoundaryTests {
    @Test("accepted native callbacks are copied and consumed in order")
    func acceptedCallbacksAreCopiedAndOrdered() async throws {
        let generation = SessionGeneration(
            rawValue: UUID(
                uuid: (
                    0, 0, 0, 0,
                    0, 0,
                    0, 0,
                    0, 0,
                    0, 0, 0, 0, 0, 1
                )
            )
        )
        let bridge = try NativeVideoEventBridge(
            generation: generation,
            bufferCapacity: 4
        )
        var videoParameterSet = [UInt8](arrayLiteral: 0x40, 0x01)
        var sequenceParameterSet = [UInt8](arrayLiteral: 0x42, 0x01)
        var pictureParameterSet = [UInt8](arrayLiteral: 0x44, 0x01)
        var accessUnit = lengthPrefixedNALUnit([0x26, 0x01])

        let configurationResult = withUnsafeBuffers(
            &videoParameterSet,
            &sequenceParameterSet,
            &pictureParameterSet
        ) { video, sequence, picture in
            bridge.receiveConfiguration(
                sequenceNumber: 10,
                videoParameterSet: video,
                sequenceParameterSet: sequence,
                pictureParameterSet: picture
            )
        }
        let accessUnitResult = accessUnit.withUnsafeBytes { bytes in
            bridge.receiveAccessUnit(
                sequenceNumber: 11,
                receivedAt: Date(timeIntervalSinceReferenceDate: 123),
                orientation: .portrait,
                pixelSize: PixelSize(width: 1179, height: 2556),
                bytes: bytes
            )
        }
        let discontinuityResult = bridge.receiveDiscontinuity(
            sequenceNumber: 12
        )
        let finishResult = bridge.finish()

        videoParameterSet[0] = 0
        sequenceParameterSet[0] = 0
        pictureParameterSet[0] = 0
        accessUnit[4] = 0

        expectNoDifference(configurationResult, .accepted)
        expectNoDifference(accessUnitResult, .accepted)
        expectNoDifference(discontinuityResult, .accepted)
        expectNoDifference(finishResult, .terminal(.finished))

        var iterator = bridge.events.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        let fourth = await iterator.next()
        let end = await iterator.next()

        guard case let .configuration(configuration) = first else {
            Issue.record("Expected configuration first")
            return
        }
        #expect(configuration.generation == generation)
        #expect(configuration.sequenceNumber == 10)
        #expect(configuration.configuration.videoParameterSet[0] == 0x40)

        guard case let .accessUnit(sample) = second else {
            Issue.record("Expected access unit second")
            return
        }
        #expect(sample.generation == generation)
        #expect(sample.sequenceNumber == 11)
        #expect(sample.sample.bytes[4] == 0x26)

        expectNoDifference(
            third,
            .discontinuity(
                NativeVideoDiscontinuity(
                    generation: generation,
                    sequenceNumber: 12
                )
            )
        )
        expectNoDifference(fourth, .finished(generation: generation))
        #expect(end == nil)
    }

    @Test("saturation fails closed exactly once without dropping silently")
    func saturationFailsClosed() async throws {
        let generation = testGeneration(2)
        let bridge = try NativeVideoEventBridge(
            generation: generation,
            bufferCapacity: 2
        )

        expectNoDifference(
            receiveValidConfiguration(on: bridge, sequenceNumber: 1),
            .accepted
        )
        expectNoDifference(
            receiveValidAccessUnit(on: bridge, sequenceNumber: 2),
            .accepted
        )
        expectNoDifference(
            bridge.receiveDiscontinuity(sequenceNumber: 3),
            .terminal(.failed(.bufferSaturated))
        )
        expectNoDifference(
            bridge.receiveDiscontinuity(sequenceNumber: 4),
            .terminal(.failed(.bufferSaturated))
        )
        expectNoDifference(
            bridge.finish(),
            .terminal(.failed(.bufferSaturated))
        )

        var iterator = bridge.events.makeAsyncIterator()
        let terminalEvent = await iterator.next()
        expectNoDifference(
            terminalEvent,
            .failed(
                NativeVideoTerminalFailure(
                    generation: generation,
                    reason: .bufferSaturated
                )
            )
        )
        #expect(await iterator.next() == nil)
        #expect(await iterator.next() == nil)
    }

    @Test("default capacity absorbs one second of decoder cold start")
    func defaultCapacityAbsorbsDecoderColdStart() throws {
        let bridge = try NativeVideoEventBridge(
            generation: testGeneration(13)
        )
        expectNoDifference(
            receiveValidConfiguration(on: bridge, sequenceNumber: 1),
            .accepted
        )

        for sequenceNumber in 2 ... 61 {
            expectNoDifference(
                receiveValidAccessUnit(
                    on: bridge,
                    sequenceNumber: UInt64(sequenceNumber)
                ),
                .accepted
            )
        }
    }

    @Test("sequence and configuration violations terminate deterministically")
    func orderingViolationsTerminate() throws {
        let duplicateSequenceBridge = try NativeVideoEventBridge(
            generation: testGeneration(3)
        )
        expectNoDifference(
            receiveValidConfiguration(
                on: duplicateSequenceBridge,
                sequenceNumber: 8
            ),
            .accepted
        )
        expectNoDifference(
            receiveValidAccessUnit(
                on: duplicateSequenceBridge,
                sequenceNumber: 8
            ),
            .terminal(.failed(.invalidSequence))
        )

        let missingConfigurationBridge = try NativeVideoEventBridge(
            generation: testGeneration(4)
        )
        expectNoDifference(
            receiveValidAccessUnit(
                on: missingConfigurationBridge,
                sequenceNumber: 1
            ),
            .terminal(.failed(.missingConfiguration))
        )

        let discontinuityBridge = try NativeVideoEventBridge(
            generation: testGeneration(5)
        )
        expectNoDifference(
            receiveValidConfiguration(
                on: discontinuityBridge,
                sequenceNumber: 1
            ),
            .accepted
        )
        expectNoDifference(
            discontinuityBridge.receiveDiscontinuity(sequenceNumber: 2),
            .accepted
        )
        expectNoDifference(
            receiveValidAccessUnit(
                on: discontinuityBridge,
                sequenceNumber: 3
            ),
            .terminal(.failed(.missingConfiguration))
        )
    }

    @Test("malformed bytes and dimensions fail before reaching a decoder")
    func malformedPayloadsTerminate() throws {
        let invalidConfigurationBridge = try NativeVideoEventBridge(
            generation: testGeneration(6)
        )
        var invalidVideo = [UInt8](arrayLiteral: 0x42, 0x01)
        var sequence = [UInt8](arrayLiteral: 0x42, 0x01)
        var picture = [UInt8](arrayLiteral: 0x44, 0x01)
        let invalidConfiguration = withUnsafeBuffers(
            &invalidVideo,
            &sequence,
            &picture
        ) {
            invalidConfigurationBridge.receiveConfiguration(
                sequenceNumber: 1,
                videoParameterSet: $0,
                sequenceParameterSet: $1,
                pictureParameterSet: $2
            )
        }
        expectNoDifference(
            invalidConfiguration,
            .terminal(.failed(.invalidConfiguration))
        )

        let invalidAccessUnitBridge = try NativeVideoEventBridge(
            generation: testGeneration(7)
        )
        expectNoDifference(
            receiveValidConfiguration(
                on: invalidAccessUnitBridge,
                sequenceNumber: 1
            ),
            .accepted
        )
        let truncatedAccessUnit = [UInt8](
            arrayLiteral: 0, 0, 0, 4, 0x26, 0x01
        )
        let invalidAccessUnit = truncatedAccessUnit.withUnsafeBytes {
            invalidAccessUnitBridge.receiveAccessUnit(
                sequenceNumber: 2,
                receivedAt: Date(timeIntervalSinceReferenceDate: 123),
                orientation: .portrait,
                pixelSize: PixelSize(width: 0, height: 2556),
                bytes: $0
            )
        }
        expectNoDifference(
            invalidAccessUnit,
            .terminal(.failed(.invalidAccessUnit))
        )
    }

    @Test("cancel wakes the consumer and permanently closes ingress")
    func cancellationIsTerminal() async throws {
        let bridge = try NativeVideoEventBridge(
            generation: testGeneration(8)
        )
        let consumer = Task {
            var iterator = bridge.events.makeAsyncIterator()
            return await iterator.next()
        }
        await Task.yield()

        expectNoDifference(bridge.cancel(), .terminal(.cancelled))
        #expect(await consumer.value == nil)
        expectNoDifference(
            bridge.receiveDiscontinuity(sequenceNumber: 1),
            .terminal(.cancelled)
        )
        expectNoDifference(bridge.finish(), .terminal(.cancelled))
    }

    @Test(
        "cancel wins before a removed waiter is resumed",
        .timeLimit(.minutes(1))
    )
    func cancellationLinearizesAgainstPendingDelivery() async throws {
        let waiterRegistered = TestSignal()
        let deliveryPaused = BlockingSynchronizationPoint()
        let bridge = try NativeVideoEventBridge(
            generation: testGeneration(11),
            synchronization: NativeVideoEventBridgeSynchronization(
                didRegisterWaiter: {
                    waiterRegistered.signal()
                },
                beforeResumingDelivery: {
                    deliveryPaused.arriveAndWait()
                }
            )
        )
        let consumer = Task {
            var iterator = bridge.events.makeAsyncIterator()
            return await iterator.next()
        }
        await waiterRegistered.wait()

        let producer = Task.detached {
            bridge.receiveDiscontinuity(sequenceNumber: 1)
        }
        await deliveryPaused.waitUntilReached()

        expectNoDifference(bridge.cancel(), .terminal(.cancelled))
        deliveryPaused.release()

        let producerResult = await producer.value
        expectNoDifference(
            producerResult,
            .terminal(.cancelled)
        )
        let consumerResult = await consumer.value
        #expect(consumerResult == nil)
    }

    @Test("configuration and access-unit descriptions never reveal bytes")
    func compressedBytesAreRedacted() async throws {
        let generation = testGeneration(9)
        let bridge = try NativeVideoEventBridge(generation: generation)
        var video = [UInt8](arrayLiteral: 0x40, 0x01)
            + Array("video-secret".utf8)
        var sequence = [UInt8](arrayLiteral: 0x42, 0x01)
            + Array("sequence-secret".utf8)
        var picture = [UInt8](arrayLiteral: 0x44, 0x01)
            + Array("picture-secret".utf8)
        _ = withUnsafeBuffers(&video, &sequence, &picture) {
            bridge.receiveConfiguration(
                sequenceNumber: 1,
                videoParameterSet: $0,
                sequenceParameterSet: $1,
                pictureParameterSet: $2
            )
        }
        let sampleBytes = lengthPrefixedNALUnit(
            [0x26, 0x01] + Array("frame-secret".utf8)
        )
        _ = sampleBytes.withUnsafeBytes {
            bridge.receiveAccessUnit(
                sequenceNumber: 2,
                receivedAt: Date(timeIntervalSinceReferenceDate: 123),
                orientation: .portrait,
                pixelSize: PixelSize(width: 1179, height: 2556),
                bytes: $0
            )
        }
        _ = bridge.finish()

        var iterator = bridge.events.makeAsyncIterator()
        let configuration = await iterator.next()
        let accessUnit = await iterator.next()

        for value in [
            String(describing: configuration),
            String(reflecting: configuration),
            String(describing: accessUnit),
            String(reflecting: accessUnit)
        ] {
            #expect(!value.contains("secret"))
            #expect(!value.contains("video-secret"))
            #expect(!value.contains("frame-secret"))
            #expect(value.contains("redacted"))
        }
    }

    @Test("buffer capacity is bounded at construction")
    func bufferCapacityValidation() {
        #expect(throws: NativeVideoContractError.self) {
            try NativeVideoEventBridge(
                generation: testGeneration(10),
                bufferCapacity: 0
            )
        }
        #expect(throws: NativeVideoContractError.self) {
            try NativeVideoEventBridge(
                generation: testGeneration(10),
                bufferCapacity:
                NativeVideoEventBridge.maximumBufferCapacity + 1
            )
        }
    }
}

private func lengthPrefixedNALUnit(_ bytes: [UInt8]) -> [UInt8] {
    let count = UInt32(bytes.count)
    return [
        UInt8((count >> 24) & 0xFF),
        UInt8((count >> 16) & 0xFF),
        UInt8((count >> 8) & 0xFF),
        UInt8(count & 0xFF)
    ] + bytes
}

private func withUnsafeBuffers<Result>(
    _ first: inout [UInt8],
    _ second: inout [UInt8],
    _ third: inout [UInt8],
    perform:
    (
        UnsafeRawBufferPointer,
        UnsafeRawBufferPointer,
        UnsafeRawBufferPointer
    ) -> Result
) -> Result {
    first.withUnsafeBytes { firstBuffer in
        second.withUnsafeBytes { secondBuffer in
            third.withUnsafeBytes { thirdBuffer in
                perform(firstBuffer, secondBuffer, thirdBuffer)
            }
        }
    }
}

private func receiveValidConfiguration(
    on bridge: NativeVideoEventBridge,
    sequenceNumber: UInt64
) -> NativeVideoIngressResult {
    var video = [UInt8](arrayLiteral: 0x40, 0x01)
    var sequence = [UInt8](arrayLiteral: 0x42, 0x01)
    var picture = [UInt8](arrayLiteral: 0x44, 0x01)
    return withUnsafeBuffers(&video, &sequence, &picture) {
        bridge.receiveConfiguration(
            sequenceNumber: sequenceNumber,
            videoParameterSet: $0,
            sequenceParameterSet: $1,
            pictureParameterSet: $2
        )
    }
}

private func receiveValidAccessUnit(
    on bridge: NativeVideoEventBridge,
    sequenceNumber: UInt64
) -> NativeVideoIngressResult {
    let accessUnit = lengthPrefixedNALUnit([0x26, 0x01])
    return accessUnit.withUnsafeBytes {
        bridge.receiveAccessUnit(
            sequenceNumber: sequenceNumber,
            receivedAt: Date(timeIntervalSinceReferenceDate: 123),
            orientation: .portrait,
            pixelSize: PixelSize(width: 1179, height: 2556),
            bytes: $0
        )
    }
}

private func testGeneration(_ byte: UInt8) -> SessionGeneration {
    SessionGeneration(
        rawValue: UUID(
            uuid: (
                0, 0, 0, 0,
                0, 0,
                0, 0,
                0, 0,
                0, 0, 0, 0, 0, byte
            )
        )
    )
}

private final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending = lock.withLock {
            guard !signaled else {
                return [CheckedContinuation<Void, Never>]()
            }
            signaled = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if signaled {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private final class BlockingSynchronizationPoint: @unchecked Sendable {
    private let reached = TestSignal()
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func arriveAndWait() {
        reached.signal()
        releaseSemaphore.wait()
    }

    func waitUntilReached() async {
        await reached.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}
