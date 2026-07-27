import DeviceHubCore
import DeviceHubMedia
import Foundation

/// Single-consumer asynchronous view of native compressed-video events.
///
/// The producer owns backpressure: a full data-event buffer becomes one
/// explicit `.failed(.bufferSaturated)` terminal event. No configuration,
/// access unit, or discontinuity is silently evicted. A terminal event has one
/// reserved slot beyond `bufferCapacity`.
public struct NativeVideoEventStream: AsyncSequence, Sendable {
    public typealias Element = NativeVideoEvent

    private let storage: NativeVideoEventStorage

    fileprivate init(storage: NativeVideoEventStorage) {
        self.storage = storage
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            storage: storage.claimConsumer() ? storage : nil
        )
    }

    /// Suspends until the single consumer is actively awaiting delivery.
    ///
    /// Session startup uses this handshake before enabling native callbacks so
    /// an initial media burst cannot fill the bounded bridge before its
    /// consumer has started.
    func waitUntilConsumerReady() async {
        await storage.waitUntilConsumerReady()
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var storage: NativeVideoEventStorage?

        fileprivate init(storage: NativeVideoEventStorage?) {
            self.storage = storage
        }

        public mutating func next() async -> NativeVideoEvent? {
            guard let storage else {
                return nil
            }
            let event = await storage.next()
            if event == nil {
                self.storage = nil
            }
            return event
        }
    }
}

/// Synchronous callback bridge between an artifact and Swift async consumers.
///
/// Every borrowed byte buffer is copied and structurally validated before the
/// receive call returns. The bridge is permanently scoped to one generation,
/// enforces strictly increasing sequence numbers, requires a new configuration
/// after every discontinuity, and fails closed on malformed or saturated input.
///
/// `cancel()` and both terminal receive operations linearize against concurrent
/// producers. Once any call returns `.terminal`, no later call can enqueue an
/// event or report `.accepted`.
public final class NativeVideoEventBridge: Sendable {
    /// One second of a 60 fps stream, plus room for its decoder configuration.
    ///
    /// VideoToolbox pipeline construction can briefly block the first consumer
    /// while the native callback continues delivering complete access units.
    public static let defaultBufferCapacity = 64
    public static let maximumBufferCapacity = 256

    public let events: NativeVideoEventStream

    private let generation: SessionGeneration
    private let storage: NativeVideoEventStorage

    public convenience init(
        generation: SessionGeneration,
        bufferCapacity: Int = defaultBufferCapacity
    ) throws(NativeVideoContractError) {
        try self.init(
            generation: generation,
            bufferCapacity: bufferCapacity,
            synchronization: .none
        )
    }

    init(
        generation: SessionGeneration,
        bufferCapacity: Int = defaultBufferCapacity,
        synchronization: NativeVideoEventBridgeSynchronization
    ) throws(NativeVideoContractError) {
        guard
            (1 ... Self.maximumBufferCapacity).contains(bufferCapacity)
        else {
            throw .invalidBufferCapacity
        }

        let storage = NativeVideoEventStorage(
            generation: generation,
            bufferCapacity: bufferCapacity,
            synchronization: synchronization
        )
        events = NativeVideoEventStream(storage: storage)
        self.generation = generation
        self.storage = storage
    }

    deinit {
        storage.cancel()
    }

    /// Copies and accepts one VPS/SPS/PPS decoder configuration.
    @discardableResult
    public func receiveConfiguration(
        sequenceNumber: UInt64,
        videoParameterSet: UnsafeRawBufferPointer,
        sequenceParameterSet: UnsafeRawBufferPointer,
        pictureParameterSet: UnsafeRawBufferPointer
    ) -> NativeVideoIngressResult {
        if let terminal = storage.terminalResult() {
            return terminal
        }
        guard
            Self.isValidParameterSetBuffer(videoParameterSet),
            Self.isValidParameterSetBuffer(sequenceParameterSet),
            Self.isValidParameterSetBuffer(pictureParameterSet)
        else {
            return storage.fail(.invalidConfiguration)
        }

        let configuration: HEVCConfiguration
        do {
            configuration = try HEVCConfiguration(
                videoParameterSet: Self.copy(videoParameterSet),
                sequenceParameterSet: Self.copy(sequenceParameterSet),
                pictureParameterSet: Self.copy(pictureParameterSet)
            )
        } catch {
            return storage.fail(.invalidConfiguration)
        }

        return storage.receive(
            .configuration(
                NativeVideoConfiguration(
                    generation: generation,
                    sequenceNumber: sequenceNumber,
                    configuration: configuration
                )
            ),
            sequenceNumber: sequenceNumber,
            kind: .configuration
        )
    }

    /// Copies and accepts one complete, four-byte-length-prefixed access unit.
    @discardableResult
    public func receiveAccessUnit(
        sequenceNumber: UInt64,
        receivedAt: Date,
        orientation: ScreenOrientation,
        pixelSize: PixelSize,
        bytes: UnsafeRawBufferPointer
    ) -> NativeVideoIngressResult {
        if let terminal = storage.terminalResult() {
            return terminal
        }
        guard
            bytes.baseAddress != nil,
            !bytes.isEmpty,
            bytes.count <= HEVCCompressedSample.maximumSampleSize,
            pixelSize.width > 0,
            pixelSize.height > 0,
            pixelSize.width <= HEVCCompressedSample.maximumDimension,
            pixelSize.height <= HEVCCompressedSample.maximumDimension,
            receivedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            return storage.fail(.invalidAccessUnit)
        }

        let sample: HEVCCompressedSample
        do {
            sample = try HEVCCompressedSample(
                generation: generation,
                sequenceNumber: sequenceNumber,
                receivedAt: receivedAt,
                orientation: orientation,
                pixelSize: pixelSize,
                bytes: Self.copy(bytes)
            )
        } catch {
            return storage.fail(.invalidAccessUnit)
        }

        return storage.receive(
            .accessUnit(NativeVideoAccessUnit(sample: sample)),
            sequenceNumber: sequenceNumber,
            kind: .accessUnit
        )
    }

    /// Invalidates the active decoder configuration at an ordered boundary.
    @discardableResult
    public func receiveDiscontinuity(
        sequenceNumber: UInt64
    ) -> NativeVideoIngressResult {
        storage.receive(
            .discontinuity(
                NativeVideoDiscontinuity(
                    generation: generation,
                    sequenceNumber: sequenceNumber
                )
            ),
            sequenceNumber: sequenceNumber,
            kind: .discontinuity
        )
    }

    /// Ends the stream with one sanitized native failure event.
    @discardableResult
    public func receiveFailure(
        _ failure: NativeSessionFailure
    ) -> NativeVideoIngressResult {
        storage.fail(.native(failure))
    }

    /// Ends the stream normally after all already accepted events.
    @discardableResult
    public func finish() -> NativeVideoIngressResult {
        storage.finish()
    }

    /// Cancels immediately, discarding buffered events and waking the consumer.
    @discardableResult
    public func cancel() -> NativeVideoIngressResult {
        storage.cancel()
    }

    private static func isValidParameterSetBuffer(
        _ buffer: UnsafeRawBufferPointer
    ) -> Bool {
        buffer.baseAddress != nil
            && buffer.count >= 2
            && buffer.count <= HEVCConfiguration.maximumParameterSetSize
    }

    private static func copy(_ buffer: UnsafeRawBufferPointer) -> Data {
        Data(
            bytes: buffer.baseAddress!,
            count: buffer.count
        )
    }
}

/// Deterministic observation points for exercising callback interleavings.
///
/// Production uses ``none``; tests can pause a callback without adding sleeps
/// or relying on scheduler timing.
struct NativeVideoEventBridgeSynchronization: Sendable {
    let didRegisterWaiter: @Sendable () -> Void
    let beforeResumingDelivery: @Sendable () -> Void

    static let none = Self(
        didRegisterWaiter: {},
        beforeResumingDelivery: {}
    )
}

private enum NativeVideoIncomingKind: Equatable {
    case accessUnit
    case configuration
    case discontinuity
}

private final class NativeVideoEventStorage: @unchecked Sendable {
    private struct State {
        var buffer: NativeVideoEventRingBuffer
        var consumerClaimed = false
        var hasConfiguration = false
        var lastSequenceNumber: UInt64?
        var nextDeliveryID: UInt64 = 1
        var pendingDelivery: Delivery?
        var termination: NativeVideoStreamTermination?
        var waiter: CheckedContinuation<NativeVideoEvent?, Never>?

        init(bufferCapacity: Int) {
            buffer = NativeVideoEventRingBuffer(
                capacity: bufferCapacity + 1
            )
        }
    }

    private struct Delivery {
        let id: UInt64
        let continuation: CheckedContinuation<NativeVideoEvent?, Never>
        let event: NativeVideoEvent?
    }

    private let bufferCapacity: Int
    private let consumerReadiness: AsyncStream<Void>
    private let consumerReadinessContinuation:
        AsyncStream<Void>.Continuation
    private let generation: SessionGeneration
    private let lock = NSLock()
    private let synchronization: NativeVideoEventBridgeSynchronization
    private var state: State

    init(
        generation: SessionGeneration,
        bufferCapacity: Int,
        synchronization: NativeVideoEventBridgeSynchronization
    ) {
        let readiness = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.bufferCapacity = bufferCapacity
        consumerReadiness = readiness.stream
        consumerReadinessContinuation = readiness.continuation
        self.generation = generation
        self.synchronization = synchronization
        state = State(bufferCapacity: bufferCapacity)
    }

    func claimConsumer() -> Bool {
        lock.lock()
        if !state.consumerClaimed {
            state.consumerClaimed = true
            lock.unlock()
            return true
        }

        let delivery = transitionToFailureLocked(
            .multipleConsumers,
            discardBuffered: false
        )
        lock.unlock()
        resume(delivery)
        return false
    }

    func terminalResult() -> NativeVideoIngressResult? {
        lock.lock()
        defer { lock.unlock() }
        return state.termination.map(NativeVideoIngressResult.terminal)
    }

    func waitUntilConsumerReady() async {
        var iterator = consumerReadiness.makeAsyncIterator()
        _ = await iterator.next()
    }

    func receive(
        _ event: NativeVideoEvent,
        sequenceNumber: UInt64,
        kind: NativeVideoIncomingKind
    ) -> NativeVideoIngressResult {
        lock.lock()
        if let termination = state.termination {
            lock.unlock()
            return .terminal(termination)
        }
        guard
            state.lastSequenceNumber.map({ sequenceNumber > $0 }) ?? true
        else {
            let delivery = transitionToFailureLocked(
                .invalidSequence,
                discardBuffered: false
            )
            lock.unlock()
            resume(delivery)
            return .terminal(.failed(.invalidSequence))
        }
        guard kind != .accessUnit || state.hasConfiguration else {
            let delivery = transitionToFailureLocked(
                .missingConfiguration,
                discardBuffered: false
            )
            lock.unlock()
            resume(delivery)
            return .terminal(.failed(.missingConfiguration))
        }
        guard state.waiter != nil || state.buffer.count < bufferCapacity else {
            let delivery = transitionToFailureLocked(
                .bufferSaturated,
                discardBuffered: true
            )
            lock.unlock()
            resume(delivery)
            return .terminal(.failed(.bufferSaturated))
        }

        state.lastSequenceNumber = sequenceNumber
        switch kind {
        case .accessUnit:
            break
        case .configuration:
            state.hasConfiguration = true
        case .discontinuity:
            state.hasConfiguration = false
        }
        let delivery = enqueueLocked(event)
        lock.unlock()
        if let termination = resume(delivery) {
            return .terminal(termination)
        }
        return .accepted
    }

    func fail(
        _ reason: NativeVideoFailureReason
    ) -> NativeVideoIngressResult {
        lock.lock()
        if let termination = state.termination {
            lock.unlock()
            return .terminal(termination)
        }
        let delivery = transitionToFailureLocked(
            reason,
            discardBuffered: false
        )
        lock.unlock()
        resume(delivery)
        return .terminal(.failed(reason))
    }

    func finish() -> NativeVideoIngressResult {
        lock.lock()
        if let termination = state.termination {
            lock.unlock()
            return .terminal(termination)
        }
        state.termination = .finished
        let delivery = enqueueLocked(.finished(generation: generation))
        lock.unlock()
        resume(delivery)
        return .terminal(.finished)
    }

    @discardableResult
    func cancel() -> NativeVideoIngressResult {
        lock.lock()
        if let termination = state.termination {
            lock.unlock()
            return .terminal(termination)
        }
        state.termination = .cancelled
        state.buffer.removeAll()
        let pendingDelivery = state.pendingDelivery
        state.pendingDelivery = nil
        let waiter = state.waiter
        state.waiter = nil
        lock.unlock()
        consumerReadinessContinuation.finish()
        pendingDelivery?.continuation.resume(returning: nil)
        waiter?.resume(returning: nil)
        return .terminal(.cancelled)
    }

    func next() async -> NativeVideoEvent? {
        await withTaskCancellationHandler {
            if Task.isCancelled {
                cancel()
                return nil
            }
            return await withCheckedContinuation { continuation in
                register(continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func register(
        _ continuation: CheckedContinuation<NativeVideoEvent?, Never>
    ) {
        lock.lock()
        if let event = state.buffer.removeFirst() {
            lock.unlock()
            signalConsumerReadiness()
            continuation.resume(returning: event)
            return
        }
        if state.termination != nil {
            lock.unlock()
            signalConsumerReadiness()
            continuation.resume(returning: nil)
            return
        }
        guard state.waiter == nil else {
            let delivery = transitionToFailureLocked(
                .multipleConsumers,
                discardBuffered: false
            )
            lock.unlock()
            resume(delivery)
            continuation.resume(returning: nil)
            return
        }
        state.waiter = continuation
        lock.unlock()
        signalConsumerReadiness()
        synchronization.didRegisterWaiter()
    }

    private func signalConsumerReadiness() {
        consumerReadinessContinuation.yield()
        consumerReadinessContinuation.finish()
    }

    private func transitionToFailureLocked(
        _ reason: NativeVideoFailureReason,
        discardBuffered: Bool
    ) -> Delivery? {
        if state.termination != nil {
            return nil
        }
        state.termination = .failed(reason)
        if discardBuffered {
            state.buffer.removeAll()
        }
        return enqueueLocked(
            .failed(
                NativeVideoTerminalFailure(
                    generation: generation,
                    reason: reason
                )
            )
        )
    }

    private func enqueueLocked(
        _ event: NativeVideoEvent
    ) -> Delivery? {
        if let waiter = state.waiter {
            state.waiter = nil
            let delivery = Delivery(
                id: state.nextDeliveryID,
                continuation: waiter,
                event: event
            )
            state.nextDeliveryID &+= 1
            state.pendingDelivery = delivery
            return delivery
        }
        state.buffer.append(event)
        return nil
    }

    @discardableResult
    private func resume(
        _ delivery: Delivery?
    ) -> NativeVideoStreamTermination? {
        guard let delivery else {
            return lock.withLock {
                if case .cancelled? = state.termination {
                    return .cancelled
                }
                return nil
            }
        }
        synchronization.beforeResumingDelivery()

        lock.lock()
        guard state.pendingDelivery?.id == delivery.id else {
            let termination = state.termination
            lock.unlock()
            return termination
        }
        state.pendingDelivery = nil
        delivery.continuation.resume(returning: delivery.event)
        lock.unlock()
        return nil
    }
}

private struct NativeVideoEventRingBuffer {
    private var countStorage = 0
    private var head = 0
    private var slots: [NativeVideoEvent?]
    private var tail = 0

    init(capacity: Int) {
        slots = Array(repeating: nil, count: capacity)
    }

    var count: Int {
        countStorage
    }

    mutating func append(_ event: NativeVideoEvent) {
        precondition(countStorage < slots.count)
        slots[tail] = event
        tail = (tail + 1) % slots.count
        countStorage += 1
    }

    mutating func removeFirst() -> NativeVideoEvent? {
        guard countStorage > 0 else {
            return nil
        }
        let event = slots[head]
        slots[head] = nil
        head = (head + 1) % slots.count
        countStorage -= 1
        return event
    }

    mutating func removeAll() {
        for index in slots.indices {
            slots[index] = nil
        }
        countStorage = 0
        head = 0
        tail = 0
    }
}
