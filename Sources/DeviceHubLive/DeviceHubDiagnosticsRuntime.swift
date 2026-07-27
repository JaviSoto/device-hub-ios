import DeviceHubDiagnostics
import Foundation
import OSLog

/// App lifecycle states accepted by the diagnostics wire contract.
public enum DeviceHubDiagnosticsLifecycleState: Sendable {
    case background
    case foreground
    case launched
    case terminated
}

/// An explicitly provisioned, validated diagnostics ingest destination.
public struct DeviceHubDiagnosticsUploadProvisioning: Sendable {
    fileprivate let bearerToken: DiagnosticBearerToken
    fileprivate let endpoint: URL

    public init(
        endpoint: URL,
        bearerToken: String
    ) throws(DiagnosticUploadFailure) {
        try DiagnosticHTTPUploadConfiguration.validate(
            endpoint: endpoint
        )
        let token = try DiagnosticBearerToken(validating: bearerToken)
        self.bearerToken = token
        self.endpoint = endpoint
    }
}

/// One validated remote upload boundary and the public identity shown in the
/// app before a user chooses whether to share diagnostics with it.
struct DeviceHubDiagnosticsUploadChannel: Sendable {
    let client: DiagnosticUploadClient
    let consentIdentity: String
    let destinationHost: String

    init(
        endpoint: URL,
        client: DiagnosticUploadClient
    ) throws(DiagnosticUploadFailure) {
        try DiagnosticHTTPUploadConfiguration.validate(endpoint: endpoint)
        guard
            let components = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            ),
            let host = components.host,
            !host.isEmpty
        else {
            throw .invalidConfiguration
        }
        self.client = client
        consentIdentity = endpoint.absoluteString
        destinationHost = components.port.map { "\(host):\($0)" } ?? host
    }
}

/// Process composition for bounded, local-first structured diagnostics.
///
/// Identity is installation-scoped and random, never device-derived. Runtime
/// persistence and upload failures are observational and cannot enter the
/// product's control path.
public struct DeviceHubDiagnosticsRuntime: Sendable {
    private static let installationIDKey =
        "DeviceHub.Diagnostics.InstallationID.v1"
    private static let installationIDLock = NSLock()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DeviceHub",
        category: "diagnostics-runtime"
    )

    public let recorder: DiagnosticRecorder
    public let remoteDiagnosticsDestinationHost: String?

    private let consentStore: DeviceHubDiagnosticsConsentStore
    let context: DiagnosticWireContext
    private let uploadConsentIdentity: String?
    private let promptUploadCoordinator:
        DeviceHubPromptUploadCoordinator?
    private let reportFailure: @Sendable (DiagnosticStage) -> Void

    /// Whether this installation has explicitly opted in to the currently
    /// configured destination.
    ///
    /// Consent is tied to the complete endpoint identity, so changing a
    /// destination requires a fresh choice.
    public var isRemoteDiagnosticsSharingEnabled: Bool {
        consentStore.isEnabled(for: uploadConsentIdentity)
    }

    /// Persists the user's choice for the current configured destination.
    ///
    /// Enabling has no effect in an unconfigured build. Disabling takes effect
    /// before this method returns and prevents later upload attempts.
    public func setRemoteDiagnosticsSharingEnabled(_ isEnabled: Bool) {
        consentStore.setEnabled(
            isEnabled,
            for: uploadConsentIdentity
        )
    }

    /// Creates the shipping local-first recorder.
    ///
    /// Construction stores only the random installation identifier. It does
    /// not create diagnostic files or contact the network, and throws only
    /// when supplied metadata or provisioning violates the contract.
    public static func live(
        userDefaults: UserDefaults = .standard,
        applicationSupportDirectory: URL,
        bundle: Bundle = .main,
        upload: DeviceHubDiagnosticsUploadProvisioning? = nil
    ) throws -> Self {
        guard
            let appVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            let buildNumber = bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        else {
            throw DiagnosticUploadFailure.invalidConfiguration
        }
        return try live(
            userDefaults: userDefaults,
            applicationSupportDirectory: applicationSupportDirectory,
            appVersion: appVersion,
            buildNumber: buildNumber,
            upload: upload
        )
    }

    /// Creates a recorder with explicit metadata for tests and non-bundle
    /// composition hosts.
    public static func live(
        userDefaults: UserDefaults = .standard,
        applicationSupportDirectory: URL,
        appVersion: String,
        buildNumber: String,
        upload: DeviceHubDiagnosticsUploadProvisioning? = nil
    ) throws -> Self {
        let installationID = try installationID(
            userDefaults: userDefaults,
            makeUUID: UUID.init
        )
        let sessionID = try sessionID(
            distinctFrom: installationID,
            makeUUID: UUID.init
        )
        let context = try DiagnosticWireContext(
            installationID: installationID,
            sessionID: sessionID,
            appVersion: appVersion,
            buildNumber: buildNumber
        )
        let directory = applicationSupportDirectory
            .appending(
                path: "DeviceHub",
                directoryHint: .isDirectory
            )
            .appending(
                path: "Diagnostics",
                directoryHint: .isDirectory
            )
        let persistence = try DiagnosticPersistenceClient.rotatingFiles(
            directory: directory,
            maximumSnapshotCount: 3
        )
        let uploadChannel: DeviceHubDiagnosticsUploadChannel? = try upload.map {
            let configuration = try DiagnosticHTTPUploadConfiguration(
                endpoint: $0.endpoint,
                bearerToken: $0.bearerToken,
                context: context
            )
            return try DeviceHubDiagnosticsUploadChannel(
                endpoint: $0.endpoint,
                client: DiagnosticUploadClient.urlSession(
                    configuration: configuration
                )
            )
        }
        return try Self(
            context: context,
            userDefaults: userDefaults,
            persistence: persistence,
            uploadChannel: uploadChannel,
            now: Date.init,
            promptUploadSleep: {
                try await Task.sleep(for: $0)
            },
            reportFailure: logFailure
        )
    }

    init(
        appVersion: String,
        buildNumber: String,
        userDefaults: UserDefaults,
        makeUUID: @escaping @Sendable () -> UUID,
        persistence: DiagnosticPersistenceClient,
        uploadChannel: DeviceHubDiagnosticsUploadChannel?,
        now: @escaping @Sendable () -> Date,
        promptUploadSleep: @escaping @Sendable (Duration) async throws
            -> Void = {
                try await Task.sleep(for: $0)
            },
        reportFailure: @escaping @Sendable (DiagnosticStage) -> Void
    ) throws {
        let installationID = try Self.installationID(
            userDefaults: userDefaults,
            makeUUID: makeUUID
        )
        let sessionID = try Self.sessionID(
            distinctFrom: installationID,
            makeUUID: makeUUID
        )
        let context = try DiagnosticWireContext(
            installationID: installationID,
            sessionID: sessionID,
            appVersion: appVersion,
            buildNumber: buildNumber
        )
        try self.init(
            context: context,
            userDefaults: userDefaults,
            persistence: persistence,
            uploadChannel: uploadChannel,
            now: now,
            promptUploadSleep: promptUploadSleep,
            reportFailure: reportFailure
        )
    }

    private init(
        context: DiagnosticWireContext,
        userDefaults: UserDefaults,
        persistence: DiagnosticPersistenceClient,
        uploadChannel: DeviceHubDiagnosticsUploadChannel?,
        now: @escaping @Sendable () -> Date,
        promptUploadSleep: @escaping @Sendable (Duration) async throws
            -> Void,
        reportFailure: @escaping @Sendable (DiagnosticStage) -> Void
    ) throws {
        self.context = context
        let consentStore = DeviceHubDiagnosticsConsentStore(
            userDefaults: userDefaults
        )
        self.consentStore = consentStore
        remoteDiagnosticsDestinationHost = uploadChannel?.destinationHost
        uploadConsentIdentity = uploadChannel?.consentIdentity

        @Sendable
        func consentGatedUpload(
            _ payload: Data
        ) async throws(DiagnosticUploadFailure) {
            guard
                let uploadChannel,
                consentStore.isEnabled(
                    for: uploadChannel.consentIdentity
                )
            else {
                throw .invalidConfiguration
            }
            try await uploadChannel.client.upload(payload)
        }

        let consentGatedUploader = DiagnosticUploadClient(
            upload: consentGatedUpload
        )
        let recorder = try DiagnosticRecorder(
            context: context,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 500,
                maximumEncodedByteCount: 512 * 1024
            ),
            persistence: persistence,
            uploader: consentGatedUploader,
            now: now
        )
        self.recorder = recorder
        promptUploadCoordinator = uploadChannel.map { uploadChannel in
            DeviceHubPromptUploadCoordinator(
                flush: {
                    guard
                        consentStore.isEnabled(
                            for: uploadChannel.consentIdentity
                        )
                    else {
                        return
                    }
                    do {
                        _ = try await recorder.flushOnForeground()
                    } catch {
                        reportFailure(.inactive)
                    }
                },
                sleep: promptUploadSleep,
                reportFailure: reportFailure
            )
        }
        self.reportFailure = reportFailure
    }

    /// Restores the latest local snapshot without surfacing telemetry failure.
    public func restoreBestEffort() async {
        do {
            try await recorder.restore()
        } catch {
            reportFailure(.inactive)
        }
    }

    /// Persists one closed-vocabulary lifecycle transition.
    public func recordLifecycle(
        _ state: DeviceHubDiagnosticsLifecycleState
    ) async {
        do {
            try await recorder.record(
                level: .info,
                category: .lifecycle,
                stage: .inactive,
                kind: .stateChanged,
                fields: DiagnosticFields(
                    lifecycleState: state.diagnosticState
                )
            )
        } catch {
            reportFailure(.inactive)
        }
    }

    /// Uploads a foreground snapshot only when an ingest endpoint and token
    /// were deliberately provisioned and the user has opted in.
    public func flushOnForegroundBestEffort() async {
        guard isRemoteDiagnosticsSharingEnabled else {
            return
        }
        do {
            _ = try await recorder.flushOnForeground()
        } catch {
            reportFailure(.inactive)
        }
    }

    /// Schedules a bounded upload without awaiting network work.
    public func schedulePromptUploadBestEffort() async {
        guard isRemoteDiagnosticsSharingEnabled else {
            return
        }
        await promptUploadCoordinator?.schedule()
    }

    /// Waits until the scheduled prompt-upload burst becomes idle.
    ///
    /// This internal completion seam makes coalescing tests deterministic;
    /// production callers should continue scheduling without awaiting upload.
    func waitForPromptUploadIdle() async {
        await promptUploadCoordinator?.waitUntilIdle()
    }

    private static func installationID(
        userDefaults: UserDefaults,
        makeUUID: @escaping @Sendable () -> UUID
    ) throws -> UUID {
        try installationIDLock.withLock {
            if
                let value = userDefaults.string(
                    forKey: installationIDKey
                ),
                let identifier = UUID(uuidString: value),
                isRandomVersion4(identifier)
            {
                return identifier
            }

            let identifier = makeUUID()
            guard isRandomVersion4(identifier) else {
                throw DiagnosticUploadFailure.invalidConfiguration
            }
            userDefaults.set(
                identifier.uuidString.lowercased(),
                forKey: installationIDKey
            )
            return identifier
        }
    }

    private static func sessionID(
        distinctFrom installationID: UUID,
        makeUUID: @escaping @Sendable () -> UUID
    ) throws -> UUID {
        for _ in 0 ..< 8 {
            let identifier = makeUUID()
            if
                identifier != installationID,
                isRandomVersion4(identifier)
            {
                return identifier
            }
        }
        throw DiagnosticUploadFailure.invalidConfiguration
    }

    private static func isRandomVersion4(_ identifier: UUID) -> Bool {
        var bytes = identifier.uuid
        return withUnsafeBytes(of: &bytes) { rawBytes in
            rawBytes[6] >> 4 == 4 && rawBytes[8] >> 6 == 2
        }
    }

    private static func logFailure(_ stage: DiagnosticStage) {
        logger.error(
            "Diagnostics failed at stage: \(stage.rawValue, privacy: .public)"
        )
    }
}

/// Stores only the endpoint identity a user explicitly approved. Tokens,
/// diagnostic contents, and device identifiers never enter preferences.
private final class DeviceHubDiagnosticsConsentStore: @unchecked Sendable {
    private static let endpointKey =
        "DeviceHub.Diagnostics.ConsentedRemoteEndpoint.v1"

    private let lock = NSLock()
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func isEnabled(for endpointIdentity: String?) -> Bool {
        guard let endpointIdentity else {
            return false
        }
        return lock.withLock {
            userDefaults.string(forKey: Self.endpointKey)
                == endpointIdentity
        }
    }

    func setEnabled(
        _ isEnabled: Bool,
        for endpointIdentity: String?
    ) {
        lock.withLock {
            guard isEnabled, let endpointIdentity else {
                userDefaults.removeObject(forKey: Self.endpointKey)
                return
            }
            userDefaults.set(endpointIdentity, forKey: Self.endpointKey)
        }
    }
}

/// Coalesces foreground pairing bursts while keeping network I/O detached from
/// the protocol control path.
private actor DeviceHubPromptUploadCoordinator {
    typealias Flush = @Sendable () async -> Void
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let flush: Flush
    private let reportFailure: @Sendable (DiagnosticStage) -> Void
    private let sleep: Sleep
    private var pending = false
    private var worker: Task<Void, Never>?

    init(
        flush: @escaping Flush,
        sleep: @escaping Sleep,
        reportFailure: @escaping @Sendable (DiagnosticStage) -> Void
    ) {
        self.flush = flush
        self.reportFailure = reportFailure
        self.sleep = sleep
    }

    func schedule() {
        pending = true
        guard worker == nil else {
            return
        }
        worker = Task { [weak self] in
            await self?.run()
        }
    }

    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func run() async {
        while pending, !Task.isCancelled {
            pending = false
            do {
                try await sleep(.milliseconds(200))
            } catch is CancellationError {
                break
            } catch {
                reportFailure(.inactive)
                break
            }

            // Requests received during the coalescing window are covered by
            // this flush because callers persist each event before scheduling.
            pending = false
            await flush()
        }

        worker = nil
        if pending, !Task.isCancelled {
            schedule()
        }
    }
}

private extension DeviceHubDiagnosticsLifecycleState {
    var diagnosticState: DiagnosticLifecycleState {
        switch self {
        case .background:
            .background
        case .foreground:
            .foreground
        case .launched:
            .launched
        case .terminated:
            .terminated
        }
    }
}
