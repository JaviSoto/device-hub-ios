import DeviceHubCore
@testable import DeviceHubMedia
import Foundation
import Testing

struct HEVCFixture {
    let configuration: HEVCConfiguration
    let sample: HEVCCompressedSample

    var input: HEVCDecodeInput {
        HEVCDecodeInput(
            configuration: configuration,
            sample: sample
        )
    }

    static func load(
        named name: String,
        generation: SessionGeneration,
        sequenceNumber: UInt64,
        receivedAt: Date,
        pixelSize: PixelSize
    ) throws -> Self {
        let configuration = try HEVCConfiguration(
            videoParameterSet: resource(named: "\(name)-vps"),
            sequenceParameterSet: resource(named: "\(name)-sps"),
            pictureParameterSet: resource(named: "\(name)-pps")
        )
        let sample = try HEVCCompressedSample(
            generation: generation,
            sequenceNumber: sequenceNumber,
            receivedAt: receivedAt,
            orientation: .portrait,
            pixelSize: pixelSize,
            bytes: resource(named: "\(name)-sample")
        )
        return Self(
            configuration: configuration,
            sample: sample
        )
    }

    private static func resource(named name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "base64"
        ) else {
            throw FixtureError.resourceMissing
        }
        let encoded = try String(
            contentsOf: url,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else {
            throw FixtureError.invalidBase64
        }
        return data
    }

    private enum FixtureError: Error {
        case invalidBase64
        case resourceMissing
    }
}

struct HEVCConfigurationCase {
    let video: Data
    let sequence: Data
    let picture: Data
    let expected: MediaDecoderError
}

struct HEVCSampleCase {
    let bytes: Data
    let pixelSize: PixelSize
    let receivedAt: Date
    let expected: MediaDecoderError
}

func captureMediaError(
    _ operation: () throws -> Void
) -> MediaDecoderError? {
    do {
        try operation()
        Issue.record("Expected a media decoder error")
        return nil
    } catch let error as MediaDecoderError {
        return error
    } catch {
        Issue.record("Unexpected error type")
        return nil
    }
}

func captureMediaError(
    _ operation: () async throws -> Void
) async -> MediaDecoderError? {
    do {
        try await operation()
        Issue.record("Expected a media decoder error")
        return nil
    } catch let error as MediaDecoderError {
        return error
    } catch {
        Issue.record("Unexpected error type")
        return nil
    }
}

extension SessionGeneration {
    static func fixture() -> Self {
        Self(
            rawValue: UUID(
                uuid: (
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 1
                )
            )
        )
    }
}

extension ScreenMetadata {
    var videoSequenceNumber: UInt64? {
        guard case let .videoFrame(metadata) = self else {
            return nil
        }
        return metadata.sequenceNumber
    }
}
