@testable import DeviceHubLive
import Foundation
import Testing

@Suite("Native ABI validation")
struct DeviceHubNativeABITests {
    @Test
    func acceptsCurrentShippingRuntime() throws {
        let runtime = try DeviceHubNativeABI(
            version: DeviceHubNativeABI.expectedVersion,
            capabilities: .requiredShipping
        )

        #expect(runtime.version == DeviceHubNativeABI.expectedVersion)
        #expect(runtime.capabilities == .requiredShipping)
    }

    @Test
    func rejectsUnsupportedVersion() {
        #expect(throws: DeviceHubNativeABIError.unsupportedVersion) {
            try DeviceHubNativeABI(
                version: DeviceHubNativeABI.expectedVersion + 1,
                capabilities: .requiredShipping
            )
        }
    }

    @Test(
        arguments: [
            DeviceHubNativeCapabilities.sessionLifecycle,
            .generationTaggedEvents,
            .sensitiveInputCopy,
            .pairableHost,
            .acknowledgedPairRecords,
            .authenticatedReconnect,
            .remoteServiceDiscoveryMetadata,
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
    )
    func rejectsEachMissingRequiredCapability(
        missingCapability: DeviceHubNativeCapabilities
    ) {
        #expect(
            throws: DeviceHubNativeABIError.missingRequiredCapabilities(
                missingCapability
            )
        ) {
            try DeviceHubNativeABI(
                version: DeviceHubNativeABI.expectedVersion,
                capabilities: .requiredShipping.subtracting(
                    missingCapability
                )
            )
        }
    }

    @Test
    func capabilityGroupsMatchTheNativeABIContract() {
        #expect(
            DeviceHubNativeCapabilities.requiredPairing == [
                .sessionLifecycle,
                .generationTaggedEvents,
                .sensitiveInputCopy,
                .pairableHost,
                .acknowledgedPairRecords
            ]
        )
        #expect(
            DeviceHubNativeCapabilities.requiredScreenshot == [
                .sessionLifecycle,
                .generationTaggedEvents,
                .sensitiveInputCopy,
                .authenticatedReconnect,
                .remoteServiceDiscoveryMetadata,
                .pngScreenshot,
                .developerReadiness
            ]
        )
        #expect(
            DeviceHubNativeCapabilities.requiredLiveControl == [
                .sessionLifecycle,
                .generationTaggedEvents,
                .sensitiveInputCopy,
                .authenticatedReconnect,
                .remoteServiceDiscoveryMetadata,
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
        )
        #expect(
            DeviceHubNativeCapabilities.requiredShipping == [
                .sessionLifecycle,
                .generationTaggedEvents,
                .sensitiveInputCopy,
                .pairableHost,
                .acknowledgedPairRecords,
                .authenticatedReconnect,
                .remoteServiceDiscoveryMetadata,
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
        )
    }

    @Test
    func linkedRuntimeSatisfiesReviewedShippingContract() throws {
        let runtime = try DeviceHubNativeABI()

        #expect(runtime.version == DeviceHubNativeABI.expectedVersion)
        #expect(
            runtime.capabilities.isSuperset(of: .requiredShipping)
        )
    }

    @Test("UUID generations preserve their canonical network-byte order")
    func generationMapping() throws {
        let uuid = try #require(
            UUID(
                uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
            )
        )

        let generation = DeviceHubNativeGeneration(uuid)

        #expect(generation.high == 0x0011_2233_4455_6677)
        #expect(generation.low == 0x8899_AABB_CCDD_EEFF)
    }

    @Test("native error JSON is reduced to the closed Swift vocabulary")
    func nativeFailureDecoding() {
        let known = DeviceHubNativeFailureDecoder.decode(
            Data(
                """
                {
                  "code": "pair_verify_failed",
                  "stage": "pair_verify",
                  "retryable": true,
                  "message": "redacted"
                }
                """.utf8
            )
        )
        #expect(known.code == "pair_verify_failed")
        #expect(known.stage == "pair_verify")
        #expect(known.retryable)

        let unknown = DeviceHubNativeFailureDecoder.decode(
            Data(
                """
                {
                  "code": "device-specific-secret",
                  "stage": "192.168.1.10",
                  "retryable": true
                }
                """.utf8
            )
        )
        #expect(unknown.code == "native_failure")
        #expect(unknown.stage == "native_boundary")
        #expect(!unknown.retryable)

        let malformed = DeviceHubNativeFailureDecoder.decode(
            Data("not-json".utf8)
        )
        #expect(malformed.code == "native_failure")
        #expect(malformed.stage == "native_boundary")
        #expect(!malformed.retryable)

        let oversized = DeviceHubNativeFailureDecoder.decode(
            Data(repeating: 0x41, count: 16 * 1024 + 1)
        )
        #expect(oversized.code == "native_failure")
        #expect(oversized.stage == "native_boundary")
        #expect(!oversized.retryable)

        let nonUTF8 = DeviceHubNativeFailureDecoder.decode(
            Data([0xFF, 0xFE, 0xFD])
        )
        #expect(nonUTF8.code == "native_failure")
        #expect(nonUTF8.stage == "native_boundary")
        #expect(!nonUTF8.retryable)

        let extraKey = DeviceHubNativeFailureDecoder.decode(
            Data(
                """
                {
                  "code": "pair_verify_failed",
                  "stage": "pair_verify",
                  "retryable": false,
                  "unexpected": "discarded"
                }
                """.utf8
            )
        )
        #expect(extraKey.code == "pair_verify_failed")
        #expect(extraKey.stage == "pair_verify")
        #expect(!extraKey.retryable)
    }
}
