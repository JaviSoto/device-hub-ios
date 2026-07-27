import DeviceHubCore
import DeviceHubFFI
import DeviceHubTransport
import Foundation

/// Unique serial owner of one native session handle.
///
/// Every C call executes on `queue`. Callback code may enqueue work here, but
/// this owner never waits on a native callback while holding a Swift lock.
/// Teardown frees and nulls the handle before releasing the retained callback
/// token or completing the public event streams.
final class DeviceHubNativeSessionExecutor: @unchecked Sendable {
    private struct TeardownResult: Sendable {
        let didFree: Bool
        let failure: NativeSessionFailure?
    }

    private let avConference: DeviceHubAVConferenceSession?
    private let cancellationLock = NSLock()
    private var cancellationTask: Task<NativeSessionFailure?, Never>?
    private let cleanupSurface: @Sendable () async -> Void
    private let context: DeviceHubNativeCallbackContext
    private let functions: DeviceHubNativeFunctionTable
    private let generation: SessionGeneration
    private var handle: OpaquePointer?
    private var hasAttemptedConstruction = false
    private var isClosing = false
    private var isFreed = false
    private let queue: DispatchQueue
    private var retainedContext: Unmanaged<DeviceHubNativeCallbackContext>?
    private let relay: DeviceHubNativeSessionRelay
    private var teardownFailure: NativeSessionFailure?

    /// Takes ownership of `retainedContext`.
    ///
    /// The token must have been created with `Unmanaged.passRetained` for the
    /// exact `context` instance and must not be released by the caller.
    init(
        generation: SessionGeneration,
        functions: DeviceHubNativeFunctionTable,
        context: DeviceHubNativeCallbackContext,
        retainedContext: Unmanaged<DeviceHubNativeCallbackContext>,
        relay: DeviceHubNativeSessionRelay,
        avConference: DeviceHubAVConferenceSession?,
        cleanupSurface: @escaping @Sendable () async -> Void
    ) {
        self.avConference = avConference
        self.cleanupSurface = cleanupSurface
        self.context = context
        self.functions = functions
        self.generation = generation
        queue = DispatchQueue(
            label:
            "\(Bundle.main.bundleIdentifier ?? "DeviceHub").native-session."
                + generation.rawValue.uuidString
        )
        self.relay = relay
        self.retainedContext = retainedContext
    }

    func createPairing(
        _ request: NativePairingSessionRequest
    ) async throws(NativeSessionFailure) {
        let result: Result<Void, NativeSessionFailure> =
            await perform { [self] in
                guard mayConstruct else {
                    return .failure(invalidStateFailure)
                }
                hasAttemptedConstruction = true

                var createdHandle: OpaquePointer?
                do {
                    try DeviceHubNativeInputMarshaller
                        .withPairingConfiguration(
                            request: request,
                            callback: deviceHubNativeControlCallback,
                            callbackContext: callbackContext
                        ) { configuration in
                            try DeviceHubNativeCall.invoke(
                                functions: functions
                            ) { error in
                                functions.createPairingSession(
                                    configuration,
                                    &createdHandle,
                                    error
                                )
                            }
                        }
                    guard createdHandle != nil else {
                        return .failure(nativeBoundaryFailure)
                    }
                    handle = createdHandle
                    return .success(())
                } catch let failure as NativeSessionFailure {
                    handle = createdHandle
                    return .failure(failure)
                } catch {
                    handle = createdHandle
                    return .failure(nativeBoundaryFailure)
                }
            }
        try unwrap(result)
    }

    func createRemote(
        _ request: NativeRemoteSessionRequest,
        operation: DeviceHubNativeRemoteOperation
    ) async throws(NativeSessionFailure) {
        let result: Result<Void, NativeSessionFailure> =
            await perform { [self] in
                guard mayConstruct else {
                    return .failure(invalidStateFailure)
                }
                hasAttemptedConstruction = true

                var createdHandle: OpaquePointer?
                do {
                    try DeviceHubNativeInputMarshaller.withRemoteConfiguration(
                        request: request,
                        operation: operation,
                        callbacks: DeviceHubNativeRemoteCallbacks(
                            control: deviceHubNativeControlCallback,
                            controlContext: callbackContext,
                            media: deviceHubNativeMediaCallback,
                            mediaContext: callbackContext
                        )
                    ) { configuration in
                        try DeviceHubNativeCall.invoke(
                            functions: functions
                        ) { error in
                            functions.createRemoteSession(
                                configuration,
                                &createdHandle,
                                error
                            )
                        }
                    }
                    guard createdHandle != nil else {
                        return .failure(nativeBoundaryFailure)
                    }
                    handle = createdHandle
                    return .success(())
                } catch let failure as NativeSessionFailure {
                    handle = createdHandle
                    return .failure(failure)
                } catch {
                    handle = createdHandle
                    return .failure(nativeBoundaryFailure)
                }
            }
        try unwrap(result)
    }

    func start() async throws(NativeSessionFailure) {
        try await call { [functions] handle, error in
            functions.sessionStart(handle, error)
        }
    }

    func completePersistence(
        _ requestID: NativePersistenceRequestID,
        outcome: NativePersistenceOutcome
    ) async throws(NativeSessionFailure) {
        let nativeOutcome = switch outcome {
        case .failed:
            DH_PERSISTENCE_FAILED
        case .succeeded:
            DH_PERSISTENCE_SUCCEEDED
        }
        try await call { [functions] handle, error in
            functions.sessionCompletePersistence(
                handle,
                requestID.rawValue,
                nativeOutcome,
                error
            )
        }
    }

    func send(
        _ command: DeviceCommand
    ) async throws(NativeSessionFailure) {
        let pixelSize = context.pixelSizeForInput()
        let encoded: DeviceHubEncodedCommand
        do {
            encoded = try DeviceHubNativeCommandEncoder.encode(
                command,
                pixelSize: pixelSize
            )
        } catch {
            throw inputFailure
        }

        let result: Result<Void, NativeSessionFailure> =
            await perform { [self] in
                guard let handle, !isClosing, !isFreed else {
                    return .failure(invalidStateFailure)
                }
                return invoke {
                    try DeviceHubNativeCommandSender.send(
                        encoded,
                        to: handle,
                        generation: generation,
                        functions: functions
                    )
                }
            }
        try unwrap(result)
    }

    /// Enqueues one receiver-originated RTCP datagram without blocking the
    /// AVConference callback queue.
    func enqueueVideoControl(_ datagram: Data) {
        queue.async { [weak self] in
            guard
                let self,
                let handle,
                !isClosing,
                !isFreed
            else {
                return
            }
            guard
                !datagram.isEmpty,
                datagram.count <= Int(UInt16.max)
            else {
                context.reportFailure(videoControlFailure)
                return
            }

            let result = datagram.withUnsafeBytes { bytes in
                invoke {
                    var input = DhVideoControlDatagram()
                    input.struct_size = UInt32(
                        MemoryLayout<DhVideoControlDatagram>.size
                    )
                    input.abi_version = DeviceHubNativeABI.expectedVersion
                    input.generation =
                        DeviceHubNativeInputMarshaller.generation(generation)
                    input.bytes = DhBytes(
                        data: bytes.bindMemory(to: UInt8.self).baseAddress,
                        count: bytes.count
                    )
                    return try withUnsafePointer(to: &input) { pointer in
                        try DeviceHubNativeCall.invoke(
                            functions: functions
                        ) { error in
                            functions.sessionSendVideoControlDatagram(
                                handle,
                                pointer,
                                error
                            )
                        }
                    }
                }
            }
            if case let .failure(failure) = result {
                context.reportFailure(failure)
            }
        }
    }

    /// Enqueues the receiver's synchronous configure/start result in the same
    /// native lane as every other C call.
    func enqueueVideoNegotiationResult(succeeded: Bool) {
        queue.async { [weak self] in
            guard
                let self,
                let handle,
                !isClosing,
                !isFreed
            else {
                return
            }
            let outcome = succeeded
                ? DH_VIDEO_NEGOTIATION_SUCCEEDED
                : DH_VIDEO_NEGOTIATION_FAILED
            let result = invoke {
                try DeviceHubNativeCall.invoke(
                    functions: functions
                ) { error in
                    functions.sessionCompleteVideoNegotiation(
                        handle,
                        DeviceHubNativeInputMarshaller.generation(generation),
                        outcome,
                        error
                    )
                }
            }
            if case let .failure(failure) = result {
                context.reportFailure(failure)
            }
        }
    }

    /// Drains callbacks, frees the unique handle, removes the rendering
    /// surface, and only then completes the public streams.
    func cancel() async throws(NativeSessionFailure) {
        let task = cancellationLock.withLock {
            if let cancellationTask {
                return cancellationTask
            }
            let task = Task { [self] in
                let result = await perform { [self] in
                    teardownNative()
                }
                if result.didFree {
                    await cleanupSurface()
                    context.finishAfterTeardown()
                }
                return result.failure
            }
            cancellationTask = task
            return task
        }
        if let failure = await task.value {
            throw failure
        }
    }

    private var callbackContext: UnsafeMutableRawPointer? {
        retainedContext?.toOpaque()
    }

    private var mayConstruct: Bool {
        !hasAttemptedConstruction
            && !isClosing
            && !isFreed
            && handle == nil
            && retainedContext != nil
    }

    private func call(
        _ operation:
        @escaping @Sendable (
            OpaquePointer,
            UnsafeMutablePointer<OpaquePointer?>
        ) -> DhStatus
    ) async throws(NativeSessionFailure) {
        let result: Result<Void, NativeSessionFailure> =
            await perform { [self] in
                guard let handle, !isClosing, !isFreed else {
                    return .failure(invalidStateFailure)
                }
                return invoke {
                    try DeviceHubNativeCall.invoke(
                        functions: functions
                    ) { error in
                        operation(handle, error)
                    }
                }
            }
        try unwrap(result)
    }

    private func teardownNative() -> TeardownResult {
        if isFreed {
            return TeardownResult(
                didFree: true,
                failure: teardownFailure
            )
        }

        isClosing = true
        context.beginClosing()
        avConference?.invalidate()

        var firstFailure = teardownFailure
        if let handle {
            let cancellation = invoke {
                try DeviceHubNativeCall.invoke(
                    functions: functions
                ) { error in
                    functions.sessionCancel(handle, error)
                }
            }
            if case let .failure(failure) = cancellation,
               failure.code != "invalid_state"
            {
                firstFailure = firstFailure ?? failure
            }
        }

        context.cancelVideoAfterNativeCancellation()

        let status = functions.sessionFree(&handle)
        guard status == DH_STATUS_OK, handle == nil else {
            let failure = firstFailure ?? nativeBoundaryFailure
            teardownFailure = failure
            return TeardownResult(didFree: false, failure: failure)
        }

        isFreed = true
        relay.unbind()
        retainedContext?.release()
        retainedContext = nil
        teardownFailure = firstFailure
        return TeardownResult(didFree: true, failure: firstFailure)
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    private func invoke(
        _ operation: () throws -> Void
    ) -> Result<Void, NativeSessionFailure> {
        do {
            try operation()
            return .success(())
        } catch let failure as NativeSessionFailure {
            return .failure(failure)
        } catch {
            return .failure(nativeBoundaryFailure)
        }
    }

    private func unwrap(
        _ result: Result<Void, NativeSessionFailure>
    ) throws(NativeSessionFailure) {
        switch result {
        case .success:
            return
        case let .failure(failure):
            throw failure
        }
    }

    private var inputFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "invalid_argument",
            stage: "input",
            retryable: false
        )
    }

    private var invalidStateFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "invalid_state",
            stage: "session_lifecycle",
            retryable: false
        )
    }

    private var nativeBoundaryFailure: NativeSessionFailure {
        DeviceHubNativeFailureDecoder.genericFailure
    }

    private var videoControlFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "video_control_delivery_failed",
            stage: "video_control",
            retryable: true
        )
    }
}

private let deviceHubNativeControlCallback: DhEventCallback = { event, context in
    guard let context else {
        return
    }
    Unmanaged<DeviceHubNativeCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handleControl(event)
}

private let deviceHubNativeMediaCallback: DhMediaEventCallback = { event, context in
    guard let context else {
        return
    }
    Unmanaged<DeviceHubNativeCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handleMedia(event)
}
