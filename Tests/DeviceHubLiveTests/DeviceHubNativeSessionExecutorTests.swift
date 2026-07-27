import DeviceHubCore
import DeviceHubFFI
@testable import DeviceHubLive
import DeviceHubTransport
import Foundation
import Testing

@Suite("Native session handle ownership")
struct DeviceHubNativeSessionExecutorTests {
    @Test("one handle stays serialized through cancellation and free")
    func ownsHandleUntilFree() async throws {
        let fixture = NativeExecutorFixture()
        let executor = fixture.makeExecutor()

        try await executor.createPairing(fixture.pairingRequest)
        try await executor.start()
        try await executor.completePersistence(
            #require(NativePersistenceRequestID(rawValue: 7)),
            outcome: .succeeded
        )
        try await executor.send(.buttonTap(.home))
        try await executor.cancel()
        try await executor.cancel()

        #expect(
            fixture.recorder.calls == [
                .createPairing,
                .start,
                .persistence(requestID: 7, succeeded: true),
                .button(button: DH_HARDWARE_BUTTON_HOME, phase: DH_BUTTON_PHASE_TAP),
                .cancel,
                .free
            ]
        )
        #expect(fixture.cleanup.count == 1)
    }

    @Test("constructor passes one retained context to both callback planes")
    func oneCallbackContextForRemoteSession() async throws {
        let fixture = NativeExecutorFixture()
        let executor = fixture.makeExecutor()

        try await executor.createRemote(
            fixture.remoteRequest,
            operation: .controlStream
        )
        try await executor.cancel()

        let contexts = try #require(fixture.recorder.callbackContexts)
        #expect(contexts.control != 0)
        #expect(contexts.control == contexts.media)
    }

    @Test("queued receiver datagrams retain their callback order")
    func videoControlOrdering() async throws {
        let fixture = NativeExecutorFixture()
        let executor = fixture.makeExecutor()
        try await executor.createPairing(fixture.pairingRequest)

        executor.enqueueVideoControl(Data([1, 2, 3]))
        executor.enqueueVideoControl(Data([4, 5, 6]))
        try await executor.cancel()

        #expect(
            fixture.recorder.calls == [
                .createPairing,
                .videoControl(Data([1, 2, 3])),
                .videoControl(Data([4, 5, 6])),
                .cancel,
                .free
            ]
        )
    }

    @Test("free still runs when native cancellation reports a failure")
    func cancellationFailureStillFrees() async throws {
        let fixture = NativeExecutorFixture(cancelStatus: DH_STATUS_INTERNAL)
        let executor = fixture.makeExecutor()
        try await executor.createPairing(fixture.pairingRequest)

        do {
            try await executor.cancel()
            Issue.record("Expected native cancellation to fail.")
        } catch {
            #expect(error.code == "native_failure")
        }

        #expect(
            fixture.recorder.calls == [
                .createPairing,
                .cancel,
                .free
            ]
        )
        #expect(fixture.cleanup.count == 1)
    }
}

final class NativeExecutorFixture: @unchecked Sendable {
    let cleanup = LockedCounter()
    let recorder: NativeFunctionRecorder

    init(
        cancelStatus: DhStatus = DH_STATUS_OK,
        remoteStartEvents: NativeFunctionRecorder.RemoteStartEvents = .none
    ) {
        recorder = NativeFunctionRecorder(
            cancelStatus: cancelStatus,
            remoteStartEvents: remoteStartEvents
        )
    }

    var pairingRequest: NativePairingSessionRequest {
        get throws {
            try NativePairingSessionRequest(
                generation: generation,
                controller: controller,
                displayName: "Device Hub",
                model: "iPhone"
            )
        }
    }

    var remoteRequest: NativeRemoteSessionRequest {
        get throws {
            try NativeRemoteSessionRequest(
                generation: generation,
                controller: controller,
                target: NativeTargetPairingRecord(
                    deviceID: DeviceID(rawValue: "test-phone"),
                    accountIdentifier: "account",
                    peerIdentifier: "peer",
                    peerPublicKey: Data(repeating: 0x33, count: 32),
                    peerAlternateIRK: Data(repeating: 0x44, count: 16),
                    displayName: "Test iPhone",
                    productType: "iPhone18,2",
                    completion: .committed
                ),
                service: NativeRemoteService(
                    endpoint: NativeResolvedEndpoint(
                        family: .ipv4,
                        address: Data([192, 168, 1, 25]),
                        scopeID: 0,
                        port: 58783
                    ),
                    identifier: UUID(
                        uuidString: "AABBCCDD-EEFF-4011-9234-556677889900"
                    )!,
                    authTags: [Data([1, 2, 3, 4, 5, 6])]
                )
            )
        }
    }

    func makeExecutor() -> DeviceHubNativeSessionExecutor {
        let relay = DeviceHubNativeSessionRelay()
        let pipe = AsyncThrowingStream<
            NativeSessionEvent,
            Error
        >.makeStream(bufferingPolicy: .bufferingOldest(8))
        let context = DeviceHubNativeCallbackContext(
            generation: generation,
            controlContinuation: pipe.continuation,
            relay: relay
        )
        let retainedContext = Unmanaged.passRetained(context)
        let executor = DeviceHubNativeSessionExecutor(
            generation: generation,
            functions: recorder.functions,
            context: context,
            retainedContext: retainedContext,
            relay: relay,
            avConference: nil,
            cleanupSurface: { [cleanup] in
                cleanup.increment()
            }
        )
        let didBind = relay.bind(
            receiverEvent: { [weak context] event in
                context?.handleReceiverEvent(event)
            },
            videoControl: { [weak executor] data in
                executor?.enqueueVideoControl(data)
            },
            videoNegotiation: { [weak executor] succeeded in
                executor?.enqueueVideoNegotiationResult(
                    succeeded: succeeded
                )
            }
        )
        #expect(didBind)
        return executor
    }

    private var controller: NativeControllerIdentity {
        get throws {
            try NativeControllerIdentity(
                identifier: UUID(
                    uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F"
                )!,
                udid: "controller-udid",
                longTermSecretKey: Data(repeating: 0x11, count: 32),
                alternateIRK: Data(repeating: 0x22, count: 16)
            )
        }
    }

    var generation: SessionGeneration {
        SessionGeneration(
            rawValue: UUID(
                uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
            )!
        )
    }
}

final class NativeFunctionRecorder: @unchecked Sendable {
    enum Call: Equatable {
        case button(button: DhHardwareButton, phase: DhButtonPhase)
        case cancel
        case createPairing
        case createRemote
        case free
        case persistence(requestID: UInt64, succeeded: Bool)
        case start
        case videoControl(Data)
    }

    enum RemoteStartEvents {
        case authenticatedThenCompleted
        case completedWithoutAuthentication
        case failed
        case none
    }

    struct RemoteConfiguration: Equatable {
        let operation: DhRemoteOperation
        let negotiatorOfferByteCount: Int
        let hasMediaCallback: Bool
        let hasMediaContext: Bool
    }

    private struct RemoteCallback {
        let callback: DhEventCallback
        let context: UnsafeMutableRawPointer
        let generation: DhGeneration
    }

    private struct State {
        var callbackContexts: (control: UInt, media: UInt)?
        var calls: [Call] = []
        var remoteCallback: RemoteCallback?
        var remoteConfiguration: RemoteConfiguration?
    }

    private let cancelStatus: DhStatus
    private let handle = OpaquePointer(bitPattern: 0xD00D)!
    private let lock = NSLock()
    private let remoteStartEvents: RemoteStartEvents
    private var state = State()

    init(
        cancelStatus: DhStatus,
        remoteStartEvents: RemoteStartEvents = .none
    ) {
        self.cancelStatus = cancelStatus
        self.remoteStartEvents = remoteStartEvents
    }

    var callbackContexts: (control: UInt, media: UInt)? {
        lock.withLock { state.callbackContexts }
    }

    var calls: [Call] {
        lock.withLock { state.calls }
    }

    var remoteConfiguration: RemoteConfiguration? {
        lock.withLock { state.remoteConfiguration }
    }

    var functions: DeviceHubNativeFunctionTable {
        DeviceHubNativeFunctionTable(
            abiVersion: { DeviceHubNativeABI.expectedVersion },
            capabilities: {
                DeviceHubNativeCapabilities.requiredShipping.rawValue
            },
            createPairingSession: { [self] configuration, output, _ in
                guard let configuration, let output else {
                    return DH_STATUS_INVALID_ARGUMENT
                }
                record(.createPairing)
                lock.withLock {
                    state.callbackContexts = (
                        UInt(bitPattern: configuration.pointee.callback_context),
                        0
                    )
                }
                output.pointee = handle
                return DH_STATUS_OK
            },
            createRemoteSession: { [self] configuration, output, _ in
                guard let configuration, let output else {
                    return DH_STATUS_INVALID_ARGUMENT
                }
                let value = configuration.pointee
                record(.createRemote)
                lock.withLock {
                    state.callbackContexts = (
                        UInt(bitPattern: value.callback_context),
                        UInt(
                            bitPattern:
                            value.media_callback_context
                        )
                    )
                    state.remoteConfiguration = RemoteConfiguration(
                        operation: value.operation,
                        negotiatorOfferByteCount:
                        value.video_negotiator_offer.count,
                        hasMediaCallback: value.media_callback != nil,
                        hasMediaContext:
                        value.media_callback_context != nil
                    )
                    if let callback = value.callback,
                       let context = value.callback_context
                    {
                        state.remoteCallback = RemoteCallback(
                            callback: callback,
                            context: context,
                            generation: value.generation
                        )
                    }
                }
                output.pointee = handle
                return DH_STATUS_OK
            },
            errorFree: { error in
                error?.pointee = nil
            },
            errorJSON: { _ in nil },
            sessionCancel: { [self] session, _ in
                guard session == handle else {
                    return DH_STATUS_INVALID_ARGUMENT
                }
                record(.cancel)
                return cancelStatus
            },
            sessionCompletePersistence: completePersistence,
            sessionCompleteVideoNegotiation: { [self] session, _, _, _ in
                session == handle
                    ? DH_STATUS_OK
                    : DH_STATUS_INVALID_ARGUMENT
            },
            sessionFree: { [self] storage in
                guard let storage, storage.pointee == handle else {
                    return DH_STATUS_INVALID_ARGUMENT
                }
                record(.free)
                storage.pointee = nil
                return DH_STATUS_OK
            },
            sessionReleaseAllInput: { [self] session, _, _ in
                session == handle
                    ? DH_STATUS_OK
                    : DH_STATUS_INVALID_ARGUMENT
            },
            sessionRotate: { [self] session, _, _ in
                session == handle
                    ? DH_STATUS_OK
                    : DH_STATUS_INVALID_ARGUMENT
            },
            sessionSendHardwareButton: { [self] session, input, _ in
                guard session == handle, let input else {
                    return DH_STATUS_INVALID_ARGUMENT
                }
                record(.button(
                    button: input.pointee.button,
                    phase: input.pointee.phase
                ))
                return DH_STATUS_OK
            },
            sessionSendKeyboard: { [self] session, _, _ in
                session == handle
                    ? DH_STATUS_OK
                    : DH_STATUS_INVALID_ARGUMENT
            },
            sessionSendTouch: { [self] session, _, _ in
                session == handle
                    ? DH_STATUS_OK
                    : DH_STATUS_INVALID_ARGUMENT
            },
            sessionSendVideoControlDatagram: sendVideoControl,
            sessionStart: { [self] session, _ in
                guard session == handle else {
                    return DH_STATUS_INVALID_ARGUMENT
                }
                record(.start)
                emitRemoteStartEvents()
                return DH_STATUS_OK
            }
        )
    }

    private func record(_ call: Call) {
        lock.withLock {
            state.calls.append(call)
        }
    }

    private func emitRemoteStartEvents() {
        switch remoteStartEvents {
        case .authenticatedThenCompleted:
            emitRemoteEvent(DH_EVENT_SESSION_STARTED, sequence: 1)
            emitRemoteEvent(DH_EVENT_AUTHENTICATED, sequence: 2)
            emitRemoteEvent(DH_EVENT_SESSION_COMPLETED, sequence: 3)

        case .completedWithoutAuthentication:
            emitRemoteEvent(DH_EVENT_SESSION_STARTED, sequence: 1)
            emitRemoteEvent(DH_EVENT_SESSION_COMPLETED, sequence: 2)

        case .failed:
            emitRemoteEvent(DH_EVENT_SESSION_STARTED, sequence: 1)
            emitRemoteEvent(
                DH_EVENT_SESSION_FAILED,
                sequence: 2,
                payload: Data(
                    """
                    {
                      "code": "pair_verify_failed",
                      "stage": "pair_verify",
                      "retryable": false
                    }
                    """.utf8
                )
            )

        case .none:
            return
        }
    }

    private func emitRemoteEvent(
        _ kind: DhEventKind,
        sequence: UInt64,
        payload: Data = Data()
    ) {
        guard let remoteCallback = lock.withLock({
            state.remoteCallback
        }) else {
            return
        }
        payload.withUnsafeBytes { bytes in
            var event = DhEvent()
            event.struct_size = UInt32(MemoryLayout<DhEvent>.size)
            event.abi_version = DeviceHubNativeABI.expectedVersion
            event.generation = remoteCallback.generation
            event.sequence = sequence
            event.kind = kind
            event.payload = DhBytes(
                data: bytes.bindMemory(to: UInt8.self).baseAddress,
                count: bytes.count
            )
            withUnsafePointer(to: &event) { event in
                remoteCallback.callback(event, remoteCallback.context)
            }
        }
    }

    private func completePersistence(
        _ session: OpaquePointer?,
        _ requestID: UInt64,
        _ outcome: DhPersistenceOutcome,
        _: UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus {
        guard session == handle else {
            return DH_STATUS_INVALID_ARGUMENT
        }
        record(.persistence(
            requestID: requestID,
            succeeded: outcome == DH_PERSISTENCE_SUCCEEDED
        ))
        return DH_STATUS_OK
    }

    private func sendVideoControl(
        _ session: OpaquePointer?,
        _ datagram: UnsafePointer<DhVideoControlDatagram>?,
        _: UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus {
        guard session == handle, let datagram else {
            return DH_STATUS_INVALID_ARGUMENT
        }
        let bytes = datagram.pointee.bytes
        guard let data = bytes.data, bytes.count >= 1 else {
            return DH_STATUS_INVALID_ARGUMENT
        }
        record(.videoControl(Data(bytes: data, count: bytes.count)))
        return DH_STATUS_OK
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock {
            value += 1
        }
    }
}
