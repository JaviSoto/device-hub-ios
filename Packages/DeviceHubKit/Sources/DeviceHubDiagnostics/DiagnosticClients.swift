import Foundation

/// The persistence boundary used by `DiagnosticRecorder`.
///
/// Implementations must replace the complete snapshot transactionally. The
/// typed failures deliberately exclude arbitrary error text.
public struct DiagnosticPersistenceClient: Sendable {
    public var load: @Sendable () async throws(DiagnosticPersistenceFailure) -> Data?
    public var save: @Sendable (Data) async throws(DiagnosticPersistenceFailure) -> Void
    public var clear: @Sendable () async throws(DiagnosticPersistenceFailure) -> Void

    public init(
        load: @escaping @Sendable () async throws(DiagnosticPersistenceFailure) -> Data?,
        save: @escaping @Sendable (Data) async throws(DiagnosticPersistenceFailure) -> Void,
        clear: @escaping @Sendable () async throws(DiagnosticPersistenceFailure) -> Void
    ) {
        self.load = load
        self.save = save
        self.clear = clear
    }
}

/// The foreground-upload boundary used by `DiagnosticRecorder`.
///
/// The supplied data is a complete versioned local outbox, including the
/// capture-time contexts required to reproduce stable server batch IDs.
public struct DiagnosticUploadClient: Sendable {
    public var upload: @Sendable (Data) async throws(DiagnosticUploadFailure) -> Void

    public init(
        upload: @escaping @Sendable (Data) async throws(DiagnosticUploadFailure) -> Void
    ) {
        self.upload = upload
    }
}
