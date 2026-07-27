import DeviceHubCore
import DeviceHubDiagnostics
import Foundation
import OSLog

private let transportLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "DeviceHub",
    category: "transport-diagnostics"
)

/// One already-redacted event queued for ordered persistence and upload.
struct TransportDiagnosticSubmission: Sendable {
    let category: DiagnosticCategory
    let fields: DiagnosticFields
    let kind: DiagnosticEventKind
    let level: DiagnosticLevel
    let stage: DiagnosticStage

    static func failure(
        _ error: DeviceHubError,
        stage: DiagnosticStage
    ) -> Self {
        Self(
            category: diagnosticCategory(for: stage),
            fields: DiagnosticFields(
                outcome: .failed,
                failureCode: diagnosticFailureCode(for: error),
                retryability: diagnosticRetryability(for: error),
                transport: .localNetwork,
                service: diagnosticService(for: stage)
            ),
            kind: .operationFailed,
            level: .error,
            stage: stage
        )
    }

    static func milestone(_ milestone: PairingDiagnosticMilestone) -> Self {
        Self(
            category: .pairing,
            fields: DiagnosticFields(
                outcome: milestone.outcome,
                transport: .localNetwork,
                service: .remotePairing
            ),
            kind: milestone.outcome == .succeeded
                ? .operationSucceeded
                : .stateChanged,
            level: .info,
            stage: milestone.stage
        )
    }
}

/// Serial, bounded shell that keeps diagnostics I/O out of transport control
/// flow while preserving event order.
final class DeviceHubTransportDiagnosticsPipeline: @unchecked Sendable {
    typealias RequestUpload = @Sendable () async -> Void

    private let continuation:
        AsyncStream<TransportDiagnosticSubmission>.Continuation
    private let reportFailure: @Sendable (DiagnosticStage) -> Void
    private let worker: Task<Void, Never>

    init(
        recorder: DiagnosticRecorder,
        requestUpload: @escaping RequestUpload,
        reportFailure: @escaping @Sendable (DiagnosticStage) -> Void =
            reportTransportDiagnosticsFailure
    ) {
        let channel = AsyncStream<TransportDiagnosticSubmission>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        continuation = channel.continuation
        self.reportFailure = reportFailure
        worker = Task {
            for await submission in channel.stream {
                do {
                    try await recorder.record(
                        level: submission.level,
                        category: submission.category,
                        stage: submission.stage,
                        kind: submission.kind,
                        fields: submission.fields
                    )
                    await requestUpload()
                } catch {
                    reportFailure(submission.stage)
                }
            }
        }
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }

    func submit(_ submission: TransportDiagnosticSubmission) {
        DeviceHubTransportTrace.emit(submission)
        if case let .dropped(dropped) = continuation.yield(submission) {
            reportFailure(dropped.stage)
        }
    }
}

/// Mirrors only the already-redacted diagnostic vocabulary to an attached
/// device console when explicitly enabled for live protocol debugging.
private enum DeviceHubTransportTrace {
    static func emit(_ submission: TransportDiagnosticSubmission) {
        guard
            ProcessInfo.processInfo.environment[
                "DEVICE_HUB_BOOTSTRAP_TRACE"
            ] == "1"
        else {
            return
        }
        let failureCode =
            submission.fields.failureCode?.rawValue ?? "none"
        FileHandle.standardOutput.write(
            Data(
                (
                    "devicehub.transport stage="
                        + submission.stage.rawValue
                        + " failure="
                        + failureCode
                        + "\n"
                ).utf8
            )
        )
    }
}

/// Sanitized lifecycle checkpoints emitted while a peer completes pairing.
enum PairingDiagnosticMilestone: Equatable, Sendable {
    case advertisementPublished
    case listenerReady
    case pairingCompleted
    case peerConnected
    case savingPairing
    case waitingForPairingCode

    var stage: DiagnosticStage {
        switch self {
        case .advertisementPublished, .listenerReady:
            .advertisingPairing
        case .peerConnected:
            .pairing
        case .waitingForPairingCode:
            .waitingForPairingCode
        case .savingPairing:
            .savingPairing
        case .pairingCompleted:
            .pairingComplete
        }
    }

    var outcome: DiagnosticOutcome {
        switch self {
        case .advertisementPublished, .pairingCompleted:
            .succeeded
        case .listenerReady,
             .peerConnected,
             .savingPairing,
             .waitingForPairingCode:
            .started
        }
    }
}

/// Reports only a sanitized lifecycle stage when diagnostic recording fails.
func reportTransportDiagnosticsFailure(_ stage: DiagnosticStage) {
    transportLogger.error(
        "Diagnostic recording failed at stage: \(stage.rawValue, privacy: .public)"
    )
}
