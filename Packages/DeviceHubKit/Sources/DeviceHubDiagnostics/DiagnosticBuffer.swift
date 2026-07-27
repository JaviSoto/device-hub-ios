/// A value-type retention buffer ordered from oldest to newest event.
public struct DiagnosticBuffer: Equatable, Sendable {
    /// The currently retained events in chronological append order.
    public var events: [DiagnosticEvent] {
        snapshot.events
    }

    /// The exact deterministic JSON size of the persisted local outbox.
    public private(set) var encodedByteCount: Int

    private let policy: DiagnosticRetentionPolicy
    private(set) var snapshot: DiagnosticSnapshot

    public init(policy: DiagnosticRetentionPolicy) throws {
        let emptySnapshot = DiagnosticSnapshot(events: [])
        let emptySnapshotByteCount = try emptySnapshot.encoded().count
        guard
            policy.maximumEventCount > 0,
            policy.maximumEncodedByteCount >= emptySnapshotByteCount
        else {
            throw DiagnosticError.invalidRetentionPolicy
        }

        snapshot = emptySnapshot
        encodedByteCount = emptySnapshotByteCount
        self.policy = policy
    }

    /// Appends an event and evicts the oldest entries needed to satisfy both
    /// retention bounds.
    @discardableResult
    public mutating func append(
        _ event: DiagnosticEvent
    ) throws -> DiagnosticRetentionResult {
        try append(event, context: nil)
    }

    init(
        policy: DiagnosticRetentionPolicy,
        snapshot: DiagnosticSnapshot
    ) throws {
        try self.init(policy: policy)
        for segment in snapshot.segments {
            for event in segment.events {
                _ = try append(event, context: segment.context)
            }
        }
    }

    @discardableResult
    mutating func append(
        _ event: DiagnosticEvent,
        context: DiagnosticWireContext
    ) throws -> DiagnosticRetentionResult {
        try append(event, context: Optional(context))
    }

    private mutating func append(
        _ event: DiagnosticEvent,
        context: DiagnosticWireContext?
    ) throws -> DiagnosticRetentionResult {
        let incomingSnapshotByteCount = try DiagnosticSnapshot(
            events: []
        )
        .appending(event, context: context)
        .encoded()
        .count
        guard incomingSnapshotByteCount <= policy.maximumEncodedByteCount else {
            return DiagnosticRetentionResult(
                evictedEventCount: 0,
                droppedIncomingEvent: true
            )
        }

        var retainedSnapshot = snapshot.appending(
            event,
            context: context
        )
        var retainedByteCount = try retainedSnapshot.encoded().count
        var evictionCount = 0
        var exceedsRetentionPolicy =
            retainedSnapshot.events.count > policy.maximumEventCount
                || retainedByteCount > policy.maximumEncodedByteCount

        while exceedsRetentionPolicy {
            retainedSnapshot = retainedSnapshot.droppingFirstEvent()
            evictionCount += 1
            retainedByteCount = try retainedSnapshot.encoded().count
            exceedsRetentionPolicy =
                retainedSnapshot.events.count > policy.maximumEventCount
                    || retainedByteCount > policy.maximumEncodedByteCount
        }

        snapshot = retainedSnapshot
        encodedByteCount = retainedByteCount

        return DiagnosticRetentionResult(
            evictedEventCount: evictionCount,
            droppedIncomingEvent: false
        )
    }
}
