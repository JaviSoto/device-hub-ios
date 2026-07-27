@testable import DeviceHubLive
import DeviceHubPrivateMedia
import DeviceHubTransport
import Foundation
import Testing

@Suite("Native callback failure classification")
struct DeviceHubNativeCallbackFailureTests {
    @Test(
        "AVConference failures retain the exact safe operation",
        arguments: [
            ("applyNegotiatorAnswer", "video_apply_answer"),
            ("generateStreamConfiguration", "video_generate_configuration"),
            ("generateStreamOptions", "video_generate_options"),
            ("validateInProcessMode", "video_validate_receiver"),
            ("createVideoStream", "video_create_receiver"),
            ("configureVideoStream", "video_configure_receiver"),
            ("start", "video_start_receiver")
        ]
    )
    func negotiationOperation(
        operation: String,
        expectedStage: String
    ) {
        let error = NSError(
            domain: DHAVConferenceErrorDomain,
            code: DHAVConferenceError.negotiationFailed.rawValue,
            userInfo: [DHAVConferenceErrorOperationKey: operation]
        )

        #expect(
            videoNegotiationFailure(for: error)
                == .init(
                    code: "video_receiver_rejected",
                    stage: expectedStage,
                    retryable: false
                )
        )
    }

    @Test("foreign and unknown failures remain closed and generic")
    func unknownOperation() {
        let foreign = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue
        )
        let unknown = NSError(
            domain: DHAVConferenceErrorDomain,
            code: DHAVConferenceError.negotiationFailed.rawValue,
            userInfo: [DHAVConferenceErrorOperationKey: "futureOperation"]
        )
        let expected = NativeSessionFailure(
            code: "video_receiver_rejected",
            stage: "video_negotiation",
            retryable: false
        )

        #expect(videoNegotiationFailure(for: foreign) == expected)
        #expect(videoNegotiationFailure(for: unknown) == expected)
    }
}
