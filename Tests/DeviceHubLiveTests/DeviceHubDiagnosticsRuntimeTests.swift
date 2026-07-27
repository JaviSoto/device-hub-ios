import DeviceHubDiagnostics
@testable import DeviceHubLive
import Foundation
import Testing

@Suite("Production diagnostics composition")
struct DeviceHubDiagnosticsRuntimeTests {
    @Test("upload provisioning uses the shared endpoint security policy")
    func uploadProvisioningUsesSharedEndpointPolicy() throws {
        #expect(throws: DiagnosticUploadFailure.insecureEndpoint) {
            try DeviceHubDiagnosticsUploadProvisioning(
                endpoint: #require(
                    URL(
                        string:
                        "https://diagnostics.example.test/upload?device=1"
                    )
                ),
                bearerToken:
                "test-only-diagnostics-token-value-0001"
            )
        }

        _ = try DeviceHubDiagnosticsUploadProvisioning(
            endpoint: #require(
                URL(
                    string:
                    "https://diagnostics.example.test/v1/diagnostics"
                )
            ),
            bearerToken:
            "test-only-diagnostics-token-value-0001"
        )
    }

    @Test("installation identity is stable while every launch is a fresh session")
    func stableInstallationFreshSession() throws {
        let defaults = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName(defaults)
            )
        }
        let identifiers = UUIDSequence([
            uuid("11111111-1111-4111-8111-111111111111"),
            uuid("22222222-2222-4222-8222-222222222222"),
            uuid("33333333-3333-4333-8333-333333333333")
        ])
        let persistence = noOpPersistence()

        let first = try DeviceHubDiagnosticsRuntime(
            appVersion: "1.0.0",
            buildNumber: "42",
            userDefaults: defaults,
            makeUUID: identifiers.next,
            persistence: persistence,
            uploadChannel: nil,
            now: Date.init,
            reportFailure: { _ in }
        )
        let second = try DeviceHubDiagnosticsRuntime(
            appVersion: "1.0.0",
            buildNumber: "42",
            userDefaults: defaults,
            makeUUID: identifiers.next,
            persistence: persistence,
            uploadChannel: nil,
            now: Date.init,
            reportFailure: { _ in }
        )

        #expect(
            first.context.installationID
                == uuid("11111111-1111-4111-8111-111111111111")
        )
        #expect(
            second.context.installationID
                == first.context.installationID
        )
        #expect(
            first.context.sessionID
                == uuid("22222222-2222-4222-8222-222222222222")
        )
        #expect(
            second.context.sessionID
                == uuid("33333333-3333-4333-8333-333333333333")
        )
        #expect(first.context.sessionID != second.context.sessionID)
        #expect(
            first.context.installationID
                != first.context.sessionID
        )
        #expect(first.context.appVersion == "1.0.0")
        #expect(first.context.buildNumber == "42")
    }

    @Test("invalid stored installation identity is repaired with random v4 data")
    func invalidStoredInstallationIDIsRepaired() throws {
        let defaults = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName(defaults)
            )
        }
        defaults.set(
            "aaaaaaaa-aaaa-1aaa-8aaa-aaaaaaaaaaaa",
            forKey: "DeviceHub.Diagnostics.InstallationID.v1"
        )
        let repairedID = uuid(
            "44444444-4444-4444-8444-444444444444"
        )
        let runtime = try DeviceHubDiagnosticsRuntime(
            appVersion: "1.0.0",
            buildNumber: "42",
            userDefaults: defaults,
            makeUUID: UUIDSequence([
                repairedID,
                uuid("55555555-5555-4555-8555-555555555555")
            ]).next,
            persistence: noOpPersistence(),
            uploadChannel: nil,
            now: Date.init,
            reportFailure: { _ in }
        )

        #expect(runtime.context.installationID == repairedID)
        #expect(
            defaults.string(
                forKey: "DeviceHub.Diagnostics.InstallationID.v1"
            ) == repairedID.uuidString.lowercased()
        )
    }

    @Test("restore failures are observational")
    func restoreFailureIsObservational() async throws {
        let defaults = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName(defaults)
            )
        }
        let failures = StageProbe()
        let runtime = try makeRuntime(
            userDefaults: defaults,
            persistence: DiagnosticPersistenceClient(
                load: {
                    () async throws(DiagnosticPersistenceFailure) -> Data?
                    in
                    throw DiagnosticPersistenceFailure.loadingFailed
                },
                save: { _ in },
                clear: {}
            ),
            reportFailure: failures.record
        )

        await runtime.restoreBestEffort()
        await runtime.recordLifecycle(.launched)

        let snapshot = await runtime.recorder.snapshot()
        #expect(failures.values == [.inactive])
        #expect(snapshot.events.count == 1)
    }

    @Test("record failures are observational and preserve in-memory evidence")
    func recordFailureIsObservational() async throws {
        let defaults = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName(defaults)
            )
        }
        let failures = StageProbe()
        let runtime = try makeRuntime(
            userDefaults: defaults,
            persistence: DiagnosticPersistenceClient(
                load: { nil },
                save: { _ async throws(
                    DiagnosticPersistenceFailure
                ) in
                    throw DiagnosticPersistenceFailure.writingFailed
                },
                clear: {}
            ),
            reportFailure: failures.record
        )

        await runtime.recordLifecycle(.background)

        let firstEvent = await runtime.recorder.snapshot().events.first
        let event = try #require(firstEvent)
        #expect(failures.values == [.inactive])
        #expect(event.category == .lifecycle)
        #expect(event.stage == .inactive)
        #expect(event.kind == .stateChanged)
        #expect(event.fields.lifecycleState == .background)
    }

    @Test("configured upload remains off until the user consents")
    func configuredUploadRequiresConsent() async throws {
        let defaults = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName(defaults)
            )
        }
        let persistence = PersistenceProbe()
        let upload = UploadProbe()
        let runtime = try makeRuntime(
            userDefaults: defaults,
            persistence: persistence.client,
            uploader: upload.client
        )

        await runtime.recordLifecycle(.foreground)
        await runtime.flushOnForegroundBestEffort()
        await #expect(
            throws: DiagnosticError.upload(.invalidConfiguration)
        ) {
            try await runtime.recorder.flushOnForeground()
        }

        let snapshot = await runtime.recorder.snapshot()
        #expect(runtime.remoteDiagnosticsDestinationHost == "diagnostics.example.test")
        #expect(!runtime.isRemoteDiagnosticsSharingEnabled)
        #expect(upload.requestCount == 0)
        #expect(persistence.clearCount == 0)
        #expect(persistence.savedSnapshotCount == 1)
        #expect(snapshot.events.count == 1)
    }

    @Test("consent is persisted and permits configured uploads")
    func consentPersistsAndPermitsUploads() async throws {
        let defaults = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName(defaults)
            )
        }
        let upload = UploadProbe()
        let first = try makeRuntime(
            userDefaults: defaults,
            persistence: PersistenceProbe().client,
            uploader: upload.client
        )

        first.setRemoteDiagnosticsSharingEnabled(true)
        await first.recordLifecycle(.foreground)
        await first.flushOnForegroundBestEffort()

        let relaunched = try makeRuntime(
            userDefaults: defaults,
            persistence: PersistenceProbe().client,
            uploader: upload.client
        )
        #expect(first.isRemoteDiagnosticsSharingEnabled)
        #expect(relaunched.isRemoteDiagnosticsSharingEnabled)
        #expect(upload.requestCount == 1)
    }

    @Test("revocation prevents a scheduled upload from starting")
    func revocationPreventsFutureRequests() async throws {
        let defaults = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName(defaults)
            )
        }
        let persistence = PersistenceProbe()
        let sleep = PromptUploadSleepProbe()
        let upload = UploadProbe()
        let runtime = try makeRuntime(
            userDefaults: defaults,
            persistence: persistence.client,
            uploader: upload.client,
            promptUploadSleep: { duration in
                try await sleep.sleep(for: duration)
            }
        )

        runtime.setRemoteDiagnosticsSharingEnabled(true)
        await runtime.recordLifecycle(.foreground)
        await runtime.schedulePromptUploadBestEffort()
        let duration = await sleep.waitUntilSleeping()
        #expect(duration == .milliseconds(200))

        runtime.setRemoteDiagnosticsSharingEnabled(false)
        await sleep.resume()
        await runtime.waitForPromptUploadIdle()

        #expect(!runtime.isRemoteDiagnosticsSharingEnabled)
        #expect(upload.requestCount == 0)
        #expect(persistence.clearCount == 0)
        #expect(persistence.savedSnapshotCount == 1)
    }

    @Test("unconfigured builds remain local-only")
    func unconfiguredBuildRemainsLocalOnly() async throws {
        let defaults = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(
                forName: defaultsSuiteName(defaults)
            )
        }
        let persistence = PersistenceProbe()
        let runtime = try makeRuntime(
            userDefaults: defaults,
            persistence: persistence.client
        )

        runtime.setRemoteDiagnosticsSharingEnabled(true)
        await runtime.recordLifecycle(.foreground)
        await runtime.flushOnForegroundBestEffort()
        await runtime.schedulePromptUploadBestEffort()

        #expect(runtime.remoteDiagnosticsDestinationHost == nil)
        #expect(!runtime.isRemoteDiagnosticsSharingEnabled)
        #expect(persistence.clearCount == 0)
        #expect(persistence.savedSnapshotCount == 1)
        #expect(await runtime.recorder.snapshot().events.count == 1)
    }

    private func makeRuntime(
        userDefaults: UserDefaults,
        persistence: DiagnosticPersistenceClient,
        uploader: DiagnosticUploadClient? = nil,
        promptUploadSleep: @escaping @Sendable (Duration) async throws
            -> Void = {
                try await Task.sleep(for: $0)
            },
        reportFailure: @escaping @Sendable (DiagnosticStage) -> Void = { _ in }
    ) throws -> DeviceHubDiagnosticsRuntime {
        let uploadChannel = try uploader.map {
            try DeviceHubDiagnosticsUploadChannel(
                endpoint: URL(
                    string:
                    "https://diagnostics.example.test/v1/diagnostics"
                )!,
                client: $0
            )
        }
        return try DeviceHubDiagnosticsRuntime(
            appVersion: "1.0.0",
            buildNumber: "42",
            userDefaults: userDefaults,
            makeUUID: UUIDSequence([
                uuid("66666666-6666-4666-8666-666666666666"),
                uuid("77777777-7777-4777-8777-777777777777")
            ]).next,
            persistence: persistence,
            uploadChannel: uploadChannel,
            now: Date.init,
            promptUploadSleep: promptUploadSleep,
            reportFailure: reportFailure
        )
    }
}

/// Suspends the coordinator's debounce until the test explicitly resumes it.
private actor PromptUploadSleepProbe {
    private var duration: Duration?
    private var durationWaiters: [CheckedContinuation<Duration, Never>] = []
    private var isResumed = false
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func sleep(for duration: Duration) async throws {
        self.duration = duration
        let waiters = durationWaiters
        durationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: duration)
        }

        if !isResumed {
            await withCheckedContinuation { continuation in
                resumeWaiter = continuation
            }
        }
        try Task.checkCancellation()
    }

    func waitUntilSleeping() async -> Duration {
        if let duration {
            return duration
        }
        return await withCheckedContinuation { continuation in
            durationWaiters.append(continuation)
        }
    }

    func resume() {
        isResumed = true
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            precondition(!values.isEmpty)
            return values.removeFirst()
        }
    }
}

private final class StageProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DiagnosticStage] = []

    var values: [DiagnosticStage] {
        lock.withLock { storage }
    }

    func record(_ stage: DiagnosticStage) {
        lock.withLock {
            storage.append(stage)
        }
    }
}

private final class PersistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var clearStorage = 0
    private var snapshots: [Data] = []

    var clearCount: Int {
        lock.withLock { clearStorage }
    }

    var savedSnapshotCount: Int {
        lock.withLock { snapshots.count }
    }

    var client: DiagnosticPersistenceClient {
        DiagnosticPersistenceClient(
            load: { nil },
            save: { [self] data in
                lock.withLock {
                    snapshots.append(data)
                }
            },
            clear: { [self] in
                lock.withLock {
                    clearStorage += 1
                }
            }
        )
    }
}

private final class UploadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.withLock { requests }
    }

    var client: DiagnosticUploadClient {
        DiagnosticUploadClient { [self] _ in
            lock.withLock {
                requests += 1
            }
        }
    }
}

private func makeUserDefaults() -> UserDefaults {
    let suiteName = "DeviceHubDiagnosticsRuntimeTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(suiteName, forKey: "test-suite-name")
    return defaults
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "test-suite-name")!
}

private func noOpPersistence() -> DiagnosticPersistenceClient {
    DiagnosticPersistenceClient(
        load: { nil },
        save: { _ in },
        clear: {}
    )
}

private func uuid(_ value: String) -> UUID {
    UUID(uuidString: value)!
}
