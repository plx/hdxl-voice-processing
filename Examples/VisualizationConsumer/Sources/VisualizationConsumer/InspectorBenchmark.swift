import Darwin
import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization

/// One fresh process per mode. Every mode executes the same prepared YIN worker.
enum InspectorBenchmark {
    enum Mode: String, CaseIterable {
        case processorOnly, disabled, selected, sampled

        var sampling: InspectionSampling {
            switch self {
            case .processorOnly, .disabled: .disabled
            case .selected: .selected(frame: 120)
            case .sampled: .sampled(every: 4, maximumFrames: 8)
            }
        }
    }
    struct Report: Encodable {
        let mode: String
        let profileSHA256: String
        let frames: Int
        let captured: Int
        let retainedFrames: Int
        let retainedCurveBytes: Int
        let retainedMetadataBytes: Int
        let peakRSSBeforeBytes: Int
        let peakRSSAfterBytes: Int
        let frameNanoseconds: [UInt64]
        let captureNanoseconds: [UInt64]
        let pitchChecksumHz: Double
    }
    static func highWaterRSS() throws -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.executableLoad) }
        return usage.ru_maxrss
    }

    static func run(mode: Mode) throws -> Report {
        let recipe = try YINConfiguration(
            sampleRate: 16_000, pitchFloorHz: 60, pitchCeilingHz: 450,
            integrationLength: 400, hopLength: 160)
        let worker = try PreparedYIN<Double>(recipe)
        let frames = 240
        let warmup = 16
        let n = recipe.requiredSampleCount
        let pcm = (0..<(n + (frames + warmup) * recipe.hopLength)).map { index -> Double in
            let phase = Double(index) * 145 * 2 * Double.pi / 16_000
            return 0.2 * sin(phase) + 0.45 * sin(2 * phase)
        }
        let source = try VisualizationConsumer.source(0, Int64(pcm.count))
        let context = InspectionContext(origin: .synthesizedDemonstration, configurationEpoch: 1)
        var history = try InspectionHistory(
            sampling: mode.sampling, context: context,
            source: VisualizationSource(source), profile: worker.identity)
        var times: [UInt64] = []
        times.reserveCapacity(frames)
        var captures: [UInt64] = []
        captures.reserveCapacity(frames)
        var checksum = 0.0
        var before = 0
        try pcm.withUnsafeBufferPointer { buffer in
            for index in -warmup..<frames {
                let offset = (index + warmup) * recipe.hopLength
                let window = try VisualizationConsumer.source(Int64(offset), Int64(n))
                let timing = try AnalysisTiming(
                    source: window, includedSampleCount: window.sampleCount)
                if index == 0 { before = try highWaterRSS() }
                var error: (any Error)?
                let start = DispatchTime.now().uptimeNanoseconds
                try worker.analyze(
                    .init(rebasing: buffer[offset..<(offset + n)]), timing: timing,
                    frameIndex: UInt64(index + warmup)
                ) { output in
                    guard index >= 0 else { return }
                    checksum += output.result.observation?.frequencyHz ?? 0
                    guard mode != .processorOnly else { return }
                    do {
                        _ = try history.capture(frame: UInt64(index)) { limits in
                            let begin = DispatchTime.now().uptimeNanoseconds
                            let snapshot = try AlgorithmInspection.pitch(
                                output, recipe: recipe, context: context, limits: limits)
                            captures.append(DispatchTime.now().uptimeNanoseconds - begin)
                            return snapshot
                        }
                    } catch let failure { error = failure }
                }
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                if let error { throw error }
                if index >= 0 { times.append(elapsed) }
            }
        }
        return try Report(
            mode: mode.rawValue, profileSHA256: worker.identity.sha256, frames: frames,
            captured: captures.count, retainedFrames: history.snapshots.count,
            retainedCurveBytes: history.scalarCount * MemoryLayout<Double>.stride,
            retainedMetadataBytes: history.metadataBytes,
            peakRSSBeforeBytes: before, peakRSSAfterBytes: highWaterRSS(), frameNanoseconds: times,
            captureNanoseconds: captures, pitchChecksumHz: checksum)
    }
}
