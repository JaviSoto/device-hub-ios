@testable import DeviceHubDiagnostics
import Foundation
import Testing

func diagnosticContext(
    sessionID: String = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    appVersion: String = "1.0.0",
    buildNumber: String = "42"
) throws -> DiagnosticWireContext {
    try DiagnosticWireContext(
        installationID: #require(
            UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        ),
        sessionID: #require(UUID(uuidString: sessionID)),
        appVersion: appVersion,
        buildNumber: buildNumber
    )
}

extension DiagnosticEvent {
    static func fixture(sequence: UInt64) -> Self {
        Self(
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            level: .info,
            category: .lifecycle,
            stage: .inactive,
            kind: .stateChanged
        )
    }
}

actor PersistenceProbe {
    var savedPayloads: [Data] = []
    var clearCount = 0

    private let saveFailure: DiagnosticPersistenceFailure?
    private let clearFailure: DiagnosticPersistenceFailure?
    private let loadFailure: DiagnosticPersistenceFailure?
    private let loadedPayload: Data?

    init(
        loadedPayload: Data? = nil,
        saveFailure: DiagnosticPersistenceFailure? = nil,
        clearFailure: DiagnosticPersistenceFailure? = nil,
        loadFailure: DiagnosticPersistenceFailure? = nil
    ) {
        self.loadedPayload = loadedPayload
        self.saveFailure = saveFailure
        self.clearFailure = clearFailure
        self.loadFailure = loadFailure
    }

    nonisolated var client: DiagnosticPersistenceClient {
        DiagnosticPersistenceClient(
            load: { [self] () async throws(DiagnosticPersistenceFailure) in
                try await load()
            },
            save: { [self] data async throws(DiagnosticPersistenceFailure) in
                try await save(data)
            },
            clear: { [self] () async throws(DiagnosticPersistenceFailure) in
                try await clear()
            }
        )
    }

    private func save(
        _ data: Data
    ) throws(DiagnosticPersistenceFailure) {
        if let saveFailure {
            throw saveFailure
        }
        savedPayloads.append(data)
    }

    private func load() throws(DiagnosticPersistenceFailure) -> Data? {
        if let loadFailure {
            throw loadFailure
        }
        return loadedPayload
    }

    private func clear() throws(DiagnosticPersistenceFailure) {
        if let clearFailure {
            throw clearFailure
        }
        clearCount += 1
    }
}

actor UploadProbe {
    var uploadedPayloads: [Data] = []

    private let failure: DiagnosticUploadFailure?

    init(failure: DiagnosticUploadFailure? = nil) {
        self.failure = failure
    }

    nonisolated var client: DiagnosticUploadClient {
        DiagnosticUploadClient { [self] data async throws(DiagnosticUploadFailure) in
            try await upload(data)
        }
    }

    private func upload(
        _ data: Data
    ) throws(DiagnosticUploadFailure) {
        if let failure {
            throw failure
        }
        uploadedPayloads.append(data)
    }
}

actor WireUploadProbe {
    nonisolated let client: DiagnosticUploadClient
    private let storage: LockIsolated<[Data]>

    init(
        runtimeContext: DiagnosticWireContext,
        now: Date
    ) {
        let capturedEnvelopes = LockIsolated<[Data]>([])
        storage = capturedEnvelopes
        client = DiagnosticUploadClient { data async throws(DiagnosticUploadFailure) in
            let snapshot: DiagnosticSnapshot
            do {
                snapshot = try DiagnosticSnapshot.decode(data)
            } catch {
                throw .invalidPayload
            }
            let envelopes = try DiagnosticWireBatchEncoder(
                context: runtimeContext
            ).envelopes(from: snapshot, now: now)
            var canonical: [Data] = []
            for envelope in envelopes {
                try canonical.append(
                    envelope.canonicalJSON()
                )
            }
            capturedEnvelopes.withValue {
                $0.append(contentsOf: canonical)
            }
        }
    }

    var canonicalEnvelopes: [Data] {
        storage.value
    }
}

private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func withValue(_ operation: (inout Value) -> Void) {
        lock.withLock {
            operation(&storedValue)
        }
    }
}

actor BlockingUploadProbe {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var uploadContinuation: CheckedContinuation<Void, Never>?

    nonisolated var client: DiagnosticUploadClient {
        DiagnosticUploadClient { [self] _ async throws(DiagnosticUploadFailure) in
            await upload()
        }
    }

    func waitUntilStarted() async {
        guard !didStart else {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        uploadContinuation?.resume()
        uploadContinuation = nil
    }

    private func upload() async {
        didStart = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()

        await withCheckedContinuation { continuation in
            uploadContinuation = continuation
        }
    }
}
