import CustomDump
@testable import DeviceHubDiagnostics
import Foundation
import Testing

struct DiagnosticBufferTests {
    @Test func retainingNewestEventsHonorsTheEventCountLimit() throws {
        var buffer = try DiagnosticBuffer(
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 2,
                maximumEncodedByteCount: 4096
            )
        )

        _ = try buffer.append(.fixture(sequence: 1))
        _ = try buffer.append(.fixture(sequence: 2))
        let result = try buffer.append(.fixture(sequence: 3))

        expectNoDifference(buffer.events.map(\.sequence), [2, 3])
        expectNoDifference(
            result,
            DiagnosticRetentionResult(
                evictedEventCount: 1,
                droppedIncomingEvent: false
            )
        )
    }

    @Test func retainingNewestEventsHonorsTheEncodedByteLimit() throws {
        let firstEvent = DiagnosticEvent.fixture(sequence: 1)
        let secondEvent = DiagnosticEvent.fixture(sequence: 2)
        let singleEventByteCount = try DiagnosticSnapshot(
            events: [firstEvent]
        ).encoded().count
        var buffer = try DiagnosticBuffer(
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: singleEventByteCount
            )
        )

        _ = try buffer.append(firstEvent)
        let result = try buffer.append(secondEvent)

        expectNoDifference(buffer.events, [secondEvent])
        #expect(buffer.encodedByteCount <= singleEventByteCount)
        expectNoDifference(
            result,
            DiagnosticRetentionResult(
                evictedEventCount: 1,
                droppedIncomingEvent: false
            )
        )
    }

    @Test func anOversizedIncomingEventDoesNotEraseRetainedHistory() throws {
        let retainedEvent = DiagnosticEvent.fixture(sequence: 1)
        let oversizedEvent = DiagnosticEvent.fixture(sequence: .max)
        let retainedEventByteCount = try DiagnosticSnapshot(
            events: [retainedEvent]
        ).encoded().count
        var buffer = try DiagnosticBuffer(
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: retainedEventByteCount
            )
        )
        _ = try buffer.append(retainedEvent)

        let result = try buffer.append(oversizedEvent)

        expectNoDifference(buffer.events, [retainedEvent])
        expectNoDifference(
            result,
            DiagnosticRetentionResult(
                evictedEventCount: 0,
                droppedIncomingEvent: true
            )
        )
    }

    @Test func captureContextBytesAreIncludedInTheExactRetentionLimit() throws {
        let event = DiagnosticEvent.fixture(sequence: 1)
        let context = try diagnosticContext()
        let contextlessByteCount = try DiagnosticSnapshot(
            events: [event]
        ).encoded().count
        let contextualByteCount = try DiagnosticSnapshot(
            context: context,
            events: [event]
        ).encoded().count
        #expect(contextualByteCount > contextlessByteCount)
        var buffer = try DiagnosticBuffer(
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: contextualByteCount - 1
            )
        )

        let result = try buffer.append(event, context: context)

        expectNoDifference(
            result,
            DiagnosticRetentionResult(
                evictedEventCount: 0,
                droppedIncomingEvent: true
            )
        )
        expectNoDifference(buffer.events, [])
    }

    @Test func aPolicyMustBeAbleToRetainItsEmptyEnvelope() throws {
        let emptySnapshotByteCount = try DiagnosticSnapshot(events: []).encoded().count

        #expect(throws: DiagnosticError.invalidRetentionPolicy) {
            _ = try DiagnosticBuffer(
                policy: DiagnosticRetentionPolicy(
                    maximumEventCount: 1,
                    maximumEncodedByteCount: emptySnapshotByteCount - 1
                )
            )
        }
    }

    @Test func typedFieldsRoundTripWithoutAFreeFormSensitiveValueChannel() throws {
        let event = DiagnosticEvent(
            sequence: 42,
            timestamp: Date(timeIntervalSince1970: 42),
            level: .warning,
            category: .media,
            stage: .startingDisplay,
            kind: .operationFailed,
            fields: DiagnosticFields(
                attempt: 2,
                durationMilliseconds: 350,
                retryAfterMilliseconds: 1000,
                frameAgeMilliseconds: 125,
                sampleCount: 60,
                deviceSlot: 1,
                outcome: .failed,
                failureCode: .mediaStalled,
                retryability: .automatic,
                transport: .peerToPeerWiFi,
                addressFamily: .ipv6,
                mediaCodec: .hevc,
                lifecycleState: .foreground,
                service: .screenSharing
            )
        )

        let data = try DiagnosticSnapshot(events: [event]).encoded()
        let decoded = try DiagnosticSnapshot.decode(data)
        let serialized = try #require(String(bytes: data, encoding: .utf8))

        expectNoDifference(decoded.events, [event])
        #expect(!serialized.contains("message"))
        #expect(!serialized.contains("networkAddress"))
        #expect(!serialized.contains("payload"))
        #expect(!serialized.contains("privateKey"))
        #expect(!serialized.contains("pairRecord"))
        #expect(!serialized.contains("pin"))
        #expect(!serialized.contains("psk"))
    }

    @Test func captureContextRoundTripsAsPartOfTheLocalOutbox() throws {
        let context = try diagnosticContext()
        let snapshot = DiagnosticSnapshot(
            context: context,
            events: [.fixture(sequence: 1)]
        )

        let decoded = try DiagnosticSnapshot.decode(snapshot.encoded())

        expectNoDifference(decoded, snapshot)
        expectNoDifference(
            decoded.resolvedSegments(fallbackContext: context)
                .map(\.context),
            [context]
        )
    }

    @Test func invalidPersistedCaptureContextCollapsesToASafeDomainError() throws {
        let snapshot = try DiagnosticSnapshot(
            context: diagnosticContext(),
            events: [.fixture(sequence: 1)]
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: snapshot.encoded()
            ) as? [String: Any]
        )
        var segments = try #require(
            object["segments"] as? [[String: Any]]
        )
        var context = try #require(
            segments[0]["context"] as? [String: Any]
        )
        context["sessionID"] =
            "00000000-0000-0000-0000-000000000000"
        segments[0]["context"] = context
        object["segments"] = segments
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DiagnosticError.decodingFailed) {
            _ = try DiagnosticSnapshot.decode(corrupted)
        }
    }

    @Test func legacySnapshotSchemaMigratesWithoutInventingCaptureContext() throws {
        let legacy = Data(
            #"{"events":[],"schemaVersion":1}"#.utf8
        )

        let snapshot = try DiagnosticSnapshot.decode(legacy)

        expectNoDifference(snapshot.schemaVersion, 2)
        expectNoDifference(snapshot.events, [])
    }

    @Test func unsupportedSnapshotSchemaIsRejected() {
        let data = Data(#"{"segments":[],"schemaVersion":3}"#.utf8)

        #expect(throws: DiagnosticError.decodingFailed) {
            _ = try DiagnosticSnapshot.decode(data)
        }
    }
}
