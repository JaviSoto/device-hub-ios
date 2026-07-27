import DeviceHubClient
import DeviceHubCore
import DeviceHubDiagnostics
import DeviceHubMedia
import Foundation

extension RemoteSessionOperation {
    func startDecoder() {
        let decoder = HEVCVideoDecoder(generation: generation)
        self.decoder = decoder
        frameTask = Task {
            await consumeFrames(decoder.frames)
        }
    }

    func consumeVideo(_ events: NativeVideoEventStream) async {
        do {
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case let .configuration(configuration):
                    decoderConfiguration = configuration.configuration

                case let .accessUnit(accessUnit):
                    guard
                        let decoder,
                        let decoderConfiguration
                    else {
                        throw DeviceHubError.decoderFailed
                    }
                    try await decoder.decode(
                        HEVCDecodeInput(
                            configuration: decoderConfiguration,
                            sample: accessUnit.sample
                        )
                    )

                case .discontinuity:
                    try await resetDecoder()

                case .failed:
                    throw DeviceHubError.decoderFailed

                case .finished:
                    return
                }
            }
            throw DeviceHubError.decoderFailed
        } catch is CancellationError {
            return
        } catch let error as MediaDecoderError {
            await terminateForMediaFailure(
                error.deviceHubError,
                stage: mediaDiagnosticStage(for: error)
            )
        } catch let error as DeviceHubError {
            await terminateForMediaFailure(error)
        } catch {
            await terminateForMediaFailure(.decoderFailed)
        }
    }

    func consumeFrames(
        _ frames: AsyncThrowingStream<RemoteDisplayFrame, Error>
    ) async {
        do {
            for try await frame in frames {
                try Task.checkCancellation()
                frameContinuation.yield(frame)
            }
            guard !Task.isCancelled else {
                return
            }
            await terminateForMediaFailure(.decoderFailed)
        } catch is CancellationError {
            return
        } catch let error as MediaDecoderError {
            await terminateForMediaFailure(
                error.deviceHubError,
                stage: mediaDiagnosticStage(for: error)
            )
        } catch {
            await terminateForMediaFailure(.decoderFailed)
        }
    }

    func resetDecoder() async throws {
        decoderConfiguration = nil
        frameTask?.cancel()
        frameTask = nil
        if let decoder {
            try await decoder.stop()
        }
        startDecoder()
    }

    func terminateForMediaFailure(
        _ error: DeviceHubError,
        stage: DiagnosticStage = .decoding
    ) async {
        guard cleanupTask == nil else {
            return
        }
        finishEvents(with: error)
        await record(error, stage: stage)
        await cleanup()
    }
}

/// Maps the finite, redacted decoder vocabulary onto distinct wire phases so
/// a physical-device failure remains diagnosable without recording media data.
func mediaDiagnosticStage(
    for error: MediaDecoderError
) -> DiagnosticStage {
    switch error {
    case .decoderStopped, .outputFrameMissing:
        .displayStopped
    case .decodedDimensionsMismatch:
        .firstVisual
    case .outputFrameDropped:
        .displayStalled
    case .invalidParameterSet:
        .startingDisplay
    case .invalidSample, .staleGeneration:
        .decoding
    case let .systemFailure(operation, _):
        switch operation {
        case .createFormatDescription,
             .createDecompressionSession,
             .configureRealTimeDecoding:
            .startingDisplay
        case .createImage:
            .firstVisual
        case .completeFrame, .submitFrame:
            .decoding
        case .waitForFrames:
            .displayStopped
        }
    }
}
