import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Native session contract vocabulary")
struct NativeSessionContractVocabularyTests {
    @Test("base capabilities are explicit and artifact independent")
    func baseCapabilities() {
        let base: NativeSessionCapabilities = [
            .sessionLifecycle,
            .generationTaggedEvents,
            .sensitiveInputCopy,
            .pairableHost,
            .acknowledgedPairRecords,
            .authenticatedReconnect,
            .rsdMetadata,
            .pngScreenshot
        ]

        #expect(base.contains(.requiredPairing))
        #expect(!base.contains(.requiredLiveControl))
        #expect(!base.contains(.init(rawValue: 1 << 63)))
    }

    @Test("live-control capabilities fail closed across every ABI group")
    func liveControlCapabilities() {
        let live = NativeSessionCapabilities.requiredLiveControl
        let expected: NativeSessionCapabilities = [
            .sessionLifecycle,
            .generationTaggedEvents,
            .sensitiveInputCopy,
            .authenticatedReconnect,
            .rsdMetadata,
            .pngScreenshot,
            .developerReadiness,
            .controlStream,
            .videoNegotiation,
            .rawVideoDatagrams,
            .hevcAccessUnits,
            .touchInput,
            .keyboardInput,
            .hardwareButtonInput,
            .rotation,
            .splitMediaCallback,
            .releaseAllInput,
            .mediaGeometrySnapshots,
            .pairVerifyDiscovery
        ]

        #expect(live == expected)
        #expect(!live.contains(.pairableHost))
        #expect(!live.contains(.acknowledgedPairRecords))
        #expect(NativeSessionCapabilities.developerReadiness.rawValue == 1 << 8)
        #expect(NativeSessionCapabilities.releaseAllInput.rawValue == 1 << 18)
        #expect(NativeSessionCapabilities.mediaGeometrySnapshots.rawValue == 1 << 19)
        #expect(NativeSessionCapabilities.pairVerifyDiscovery.rawValue == 1 << 20)
    }

    @Test("sensitive values and events are universally redacted")
    func redaction() throws {
        let controller = try NativeControllerIdentity(
            identifier: #require(
                UUID(uuidString: "D0A4A010-580E-4C4E-A9E1-06EE86ED79E2")
            ),
            udid: "secret-controller-udid",
            longTermSecretKey: Data(repeating: 1, count: 32),
            alternateIRK: Data(repeating: 2, count: 16)
        )
        let peer = try NativeVerifiedPeer(
            deviceID: DeviceID(rawValue: "secret-device"),
            accountIdentifier: "secret-account",
            peerIdentifier: "secret-peer",
            peerPublicKey: Data(repeating: 3, count: 32),
            peerAlternateIRK: Data(repeating: 4, count: 16),
            displayName: "Secret Phone",
            productType: "SecretModel"
        )
        let failure = NativeSessionFailure(
            code: "secret-code",
            stage: "secret-stage",
            retryable: false
        )
        let event = try NativeSessionEvent.pairingCode(
            #require(PairingCode("123456"))
        )

        for value in [
            String(describing: controller),
            String(reflecting: controller),
            String(describing: peer),
            String(reflecting: peer),
            String(describing: failure),
            String(reflecting: failure),
            String(describing: event),
            String(reflecting: event)
        ] {
            #expect(!value.contains("secret"))
            #expect(!value.contains("123456"))
            #expect(value.contains("redacted"))
        }
    }

    @Test("native failure tokens are closed and unknown values become generic")
    func failureVocabulary() {
        let known = NativeSessionFailure(
            code: "pair_verify_failed",
            stage: "pair_verify",
            retryable: false
        )
        #expect(known.code == "pair_verify_failed")
        #expect(known.stage == "pair_verify")

        for stage in [
            "pair_verify_m2_authentication",
            "pair_verify_m2_decryption",
            "pair_verify_m2_identifier",
            "pair_verify_m2_shape",
            "pair_verify_m2_signature",
            "pair_verify_m4_completion",
            "pair_verify_peer_rejection",
            "pair_verify_protocol",
            "pair_verify_timeout",
            "pair_verify_transport"
        ] {
            let checkpoint = NativeSessionFailure(
                code: "pair_verify_failed",
                stage: stage,
                retryable: false
            )
            #expect(checkpoint.code == "pair_verify_failed")
            #expect(checkpoint.stage == stage)
        }

        let rejected = NativeSessionFailure(
            code: "unknown_private_code",
            stage: "192_168_1_20",
            retryable: true
        )
        #expect(rejected.code == "native_failure")
        #expect(rejected.stage == "native_boundary")
        #expect(!rejected.retryable)
    }

    @Test("native failure vocabulary accepts proven Rust producer omissions")
    func missingRustProducerFailureVocabulary() {
        let failures = [
            NativeSessionFailure(
                code: "control_channel_closed",
                stage: "control_stream",
                retryable: false
            ),
            NativeSessionFailure(
                code: "control_channel_closed",
                stage: "video_negotiation",
                retryable: false
            ),
            NativeSessionFailure(
                code: "video_receiver_rejected",
                stage: "video_negotiation",
                retryable: false
            ),
            NativeSessionFailure(
                code: "video_configuration_missing",
                stage: "video_stream",
                retryable: false
            ),
            NativeSessionFailure(
                code: "unsupported_device_orientation",
                stage: "rotation",
                retryable: false
            ),
            NativeSessionFailure(
                code: "unsupported_protocol_version",
                stage: "video_answer_extraction",
                retryable: false
            ),
            NativeSessionFailure(
                code: "unsupported_protocol_version",
                stage: "video_answer_parse",
                retryable: false
            ),
            NativeSessionFailure(
                code: "unsupported_protocol_version",
                stage: "video_stream_selection_ambiguous",
                retryable: false
            )
        ]

        #expect(failures.map(\.code) == [
            "control_channel_closed",
            "control_channel_closed",
            "video_receiver_rejected",
            "video_configuration_missing",
            "unsupported_device_orientation",
            "unsupported_protocol_version",
            "unsupported_protocol_version",
            "unsupported_protocol_version"
        ])
        #expect(failures.map(\.stage) == [
            "control_stream",
            "video_negotiation",
            "video_negotiation",
            "video_stream",
            "rotation",
            "video_answer_extraction",
            "video_answer_parse",
            "video_stream_selection_ambiguous"
        ])
        #expect(failures.map(\.retryable) == [
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false
        ])
    }

    @Test("video stream selection failures retain their redacted wire stage")
    func videoStreamSelectionFailureStages() {
        let stages = [
            "video_stream_group_missing",
            "video_stream_payload_missing",
            "video_stream_payload_invalid",
            "video_stream_payload_encrypted",
            "video_stream_ssrc_invalid",
            "video_stream_ssrc_missing",
            "video_stream_ssrc_zero",
            "video_stream_selection_ambiguous",

            "video_stream_ssrc_mismatch"
        ]

        #expect(stages.map {
            NativeSessionFailure(
                code: "unsupported_protocol_version",
                stage: $0,
                retryable: false
            ).stage
        } == stages)
    }

    @Test("developer-readiness probe failures retain their redacted wire code")
    func developerReadinessProbeFailureVocabulary() {
        let failures = [
            NativeSessionFailure(
                code: "developer_mode_status_unsupported",
                stage: "developer_readiness",
                retryable: false
            ),
            NativeSessionFailure(
                code: "developer_image_lookup_unsupported",
                stage: "developer_readiness",
                retryable: false
            ),
            NativeSessionFailure(
                code: "developer_image_lookup_presence_malformed",
                stage: "developer_readiness",
                retryable: false
            ),
            NativeSessionFailure(
                code: "developer_image_lookup_signature_array_malformed",
                stage: "developer_readiness",
                retryable: false
            ),
            NativeSessionFailure(
                code: "developer_image_lookup_signature_malformed",
                stage: "developer_readiness",
                retryable: false
            ),
            NativeSessionFailure(
                code: "developer_image_lookup_signature_empty",
                stage: "developer_readiness",
                retryable: false
            ),
            NativeSessionFailure(
                code: "developer_image_lookup_signature_array_empty",
                stage: "developer_readiness",
                retryable: false
            ),
            NativeSessionFailure(
                code: "developer_image_lookup_signature_type_unsupported",
                stage: "developer_readiness",
                retryable: false
            ),
            NativeSessionFailure(
                code: "developer_image_lookup_signature_missing",
                stage: "developer_readiness",
                retryable: false
            )
        ]

        #expect(failures.map(\.code) == [
            "developer_mode_status_unsupported",
            "developer_image_lookup_unsupported",
            "developer_image_lookup_presence_malformed",
            "developer_image_lookup_signature_array_malformed",
            "developer_image_lookup_signature_malformed",
            "developer_image_lookup_signature_empty",
            "developer_image_lookup_signature_array_empty",
            "developer_image_lookup_signature_type_unsupported",
            "developer_image_lookup_signature_missing"
        ])
    }
}
