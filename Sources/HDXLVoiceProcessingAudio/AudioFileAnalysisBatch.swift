import Foundation
import HDXLVoiceProcessing

public struct AudioFileScheduleInput: Sendable {
    public let url: URL
    public let profile: AnalysisScheduleProfile
    public let origin: AnalysisScheduleOrigin
    public let sampleCount: Int64?
    public let mask: PreparedAnalysisMask?

    public init(
        url: URL, profile: AnalysisScheduleProfile, origin: AnalysisScheduleOrigin,
        sampleCount: Int64? = nil, mask: PreparedAnalysisMask? = nil
    ) {
        self.url = url
        self.profile = profile
        self.origin = origin
        self.sampleCount = sampleCount
        self.mask = mask
    }
}

public enum AudioFileBatchAction: Sendable { case proceed, cancelInput, cancelBatch }

public struct AudioFileBatchCheckpoint: Sendable {
    public let inputIndex: Int
    public let nextSourceSample: Int64
}

public struct AudioFileBatchFailure: Sendable, Hashable {
    public enum Stage: String, Sendable, Hashable { case preparation, processing }
    public let stage: Stage
    public let domain: String
    public let code: Int
    public let message: String
}

public enum AudioFileBatchResult: Sendable {
    case analyzed(decoding: AudioFileDecodingProvenance, completion: AudioFileScheduleCompletion)
    case failed(AudioFileBatchFailure)
    case cancelledBeforePreparation
}

public struct AudioFileBatchReport: Sendable, Hashable {
    public let successfulInputs: Int
    public let failedInputs: Int
    public let cancelledInputs: Int
}

/// Independent per-input workers, released before the next input. Results are
/// delivered synchronously, without retaining an unbounded frame/result history.
/// The control callback is sampled before preparation and between bounded reads.
public enum AudioFileAnalysisBatch {
    public static func run<Sample: BinaryFloatingPoint & Sendable>(
        _: Sample.Type, inputs: [AudioFileScheduleInput], chunkCapacity: Int = 2048,
        sourceTileCapacity: Int = 256,
        control: (AudioFileBatchCheckpoint) -> AudioFileBatchAction = { _ in .proceed },
        emit: (Int, AudioFileScheduledFrame) -> Void,
        regionCompleted: (Int, AnalysisScheduleCompletion) -> Void = { _, _ in },
        inputCompleted: (Int, AudioFileBatchResult) -> Void
    ) -> AudioFileBatchReport {
        var successes = 0
        var failures = 0
        var cancellations = 0
        var cancelRemaining = false
        for (index, input) in inputs.enumerated() {
            let action =
                cancelRemaining
                ? .cancelBatch
                : control(
                    AudioFileBatchCheckpoint(
                        inputIndex: index, nextSourceSample: input.origin.source.startSample))
            if action != .proceed {
                if action == .cancelBatch { cancelRemaining = true }
                cancellations += 1
                inputCompleted(index, .cancelledBeforePreparation)
                continue
            }
            var stage = AudioFileBatchFailure.Stage.preparation
            do {
                let worker = try PreparedAudioFileSchedule<Sample>(
                    url: input.url,
                    profile: input.profile, origin: input.origin, sampleCount: input.sampleCount,
                    chunkCapacity: chunkCapacity, sourceTileCapacity: sourceTileCapacity,
                    mask: input.mask)
                stage = .processing
                while worker.completion == nil {
                    let action = control(
                        AudioFileBatchCheckpoint(
                            inputIndex: index, nextSourceSample: worker.nextSourceSample))
                    if action != .proceed {
                        if action == .cancelBatch { cancelRemaining = true }
                        worker.cancel()
                        break
                    }
                    _ = try worker.read(
                        maximumChunks: 1, emit: { emit(index, $0) },
                        regionCompleted: { regionCompleted(index, $0) })
                }
                guard let completion = worker.completion else {
                    throw AnalysisScheduleError.invalidState
                }
                if worker.isCancelled { cancellations += 1 } else { successes += 1 }
                inputCompleted(index, .analyzed(decoding: worker.decoding, completion: completion))
            } catch {
                failures += 1
                let failure = error as NSError
                inputCompleted(
                    index,
                    .failed(
                        AudioFileBatchFailure(
                            stage: stage,
                            domain: failure.domain, code: failure.code,
                            message: failure.localizedDescription)))
            }
        }
        return AudioFileBatchReport(
            successfulInputs: successes, failedInputs: failures,
            cancelledInputs: cancellations)
    }
}
