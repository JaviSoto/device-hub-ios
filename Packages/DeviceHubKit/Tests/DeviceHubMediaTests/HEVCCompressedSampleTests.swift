import CustomDump
import DeviceHubCore
@testable import DeviceHubMedia
import Foundation
import Testing

struct HEVCCompressedSampleTests {
    @Test func rejectsATruncatedLengthPrefixedNALUnit() {
        let bytes = Data([
            0, 0, 0, 4,
            0x28, 0x01
        ])

        do {
            _ = try HEVCCompressedSample(
                generation: .fixture(),
                sequenceNumber: 1,
                receivedAt: Date(timeIntervalSince1970: 1),
                orientation: .portrait,
                pixelSize: PixelSize(width: 64, height: 64),
                bytes: bytes
            )
            Issue.record("Expected a truncated NAL unit to be rejected")
        } catch let error as MediaDecoderError {
            expectNoDifference(
                error,
                .invalidSample(.truncatedNALUnit)
            )
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test func validatesEveryAccessUnitBoundary() {
        let cases = [
            HEVCSampleCase(
                bytes: Data(),
                pixelSize: PixelSize(width: 64, height: 64),
                receivedAt: Date(timeIntervalSince1970: 1),
                expected: .invalidSample(.empty)
            ),
            HEVCSampleCase(
                bytes: Data([0, 0, 0]),
                pixelSize: PixelSize(width: 64, height: 64),
                receivedAt: Date(timeIntervalSince1970: 1),
                expected: .invalidSample(.truncatedLengthPrefix)
            ),
            HEVCSampleCase(
                bytes: Data([0, 0, 0, 0]),
                pixelSize: PixelSize(width: 64, height: 64),
                receivedAt: Date(timeIntervalSince1970: 1),
                expected: .invalidSample(.zeroLengthNALUnit)
            ),
            HEVCSampleCase(
                bytes: Data([0, 0, 0, 1, 0x02]),
                pixelSize: PixelSize(width: 64, height: 64),
                receivedAt: Date(timeIntervalSince1970: 1),
                expected: .invalidSample(.malformedNALUnitHeader)
            ),
            HEVCSampleCase(
                bytes: Data([0, 0, 0, 2, 0x4E, 0x01]),
                pixelSize: PixelSize(width: 64, height: 64),
                receivedAt: Date(timeIntervalSince1970: 1),
                expected: .invalidSample(
                    .missingVideoCodingLayerNALUnit
                )
            ),
            HEVCSampleCase(
                bytes: Data([0, 0, 0, 2, 0x02, 0x01]),
                pixelSize: PixelSize(width: 0, height: 64),
                receivedAt: Date(timeIntervalSince1970: 1),
                expected: .invalidSample(.invalidPixelSize)
            ),
            HEVCSampleCase(
                bytes: Data([0, 0, 0, 2, 0x02, 0x01]),
                pixelSize: PixelSize(
                    width: HEVCCompressedSample.maximumDimension + 1,
                    height: 64
                ),
                receivedAt: Date(timeIntervalSince1970: 1),
                expected: .invalidSample(.invalidPixelSize)
            ),
            HEVCSampleCase(
                bytes: Data([0, 0, 0, 2, 0x02, 0x01]),
                pixelSize: PixelSize(width: 64, height: 64),
                receivedAt: Date(
                    timeIntervalSinceReferenceDate: .infinity
                ),
                expected: .invalidSample(.invalidTimestamp)
            )
        ]

        for testCase in cases {
            let error = captureMediaError {
                _ = try HEVCCompressedSample(
                    generation: .fixture(),
                    sequenceNumber: 1,
                    receivedAt: testCase.receivedAt,
                    orientation: .portrait,
                    pixelSize: testCase.pixelSize,
                    bytes: testCase.bytes
                )
            }
            expectNoDifference(error, testCase.expected)
        }
    }

    @Test func enforcesSampleSizeAndNALUnitCountLimits() {
        let oversizedError = captureMediaError {
            _ = try HEVCCompressedSample(
                generation: .fixture(),
                sequenceNumber: 1,
                receivedAt: Date(timeIntervalSince1970: 1),
                orientation: .portrait,
                pixelSize: PixelSize(width: 64, height: 64),
                bytes: Data(
                    count: HEVCCompressedSample.maximumSampleSize + 1
                )
            )
        }
        expectNoDifference(
            oversizedError,
            .invalidSample(.exceedsSizeLimit)
        )

        let nalUnit = Data([0, 0, 0, 2, 0x02, 0x01])
        var tooManyNALUnits = Data()
        for _ in 0 ... HEVCCompressedSample.maximumNALUnitCount {
            tooManyNALUnits.append(nalUnit)
        }
        let countError = captureMediaError {
            _ = try HEVCCompressedSample(
                generation: .fixture(),
                sequenceNumber: 1,
                receivedAt: Date(timeIntervalSince1970: 1),
                orientation: .portrait,
                pixelSize: PixelSize(width: 64, height: 64),
                bytes: tooManyNALUnits
            )
        }
        expectNoDifference(
            countError,
            .invalidSample(.tooManyNALUnits)
        )
    }

    @Test func identifiesSyncAndDependentAccessUnits() throws {
        let sync = try HEVCCompressedSample(
            generation: .fixture(),
            sequenceNumber: 1,
            receivedAt: Date(timeIntervalSince1970: 1),
            orientation: .portrait,
            pixelSize: PixelSize(width: 64, height: 64),
            bytes: Data([0, 0, 0, 2, 0x28, 0x01])
        )
        let dependent = try HEVCCompressedSample(
            generation: .fixture(),
            sequenceNumber: 2,
            receivedAt: Date(timeIntervalSince1970: 2),
            orientation: .portrait,
            pixelSize: PixelSize(width: 64, height: 64),
            bytes: Data([0, 0, 0, 2, 0x02, 0x01])
        )

        #expect(sync.isSync)
        #expect(!dependent.isSync)
    }
}
