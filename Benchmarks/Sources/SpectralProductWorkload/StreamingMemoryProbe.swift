import Darwin
import Foundation
import HDXLVoiceProcessing

public struct SpectralMemoryObservation: Encodable {
    public let seconds: Int
    public let liveHeapBytes: UInt64
    public let retainedFrames: Int
    public let evictedFrames: UInt64
    public let measuredFrames: UInt64
}

/// Run a fixed-size PCM chunk through the public worker, accumulator and ring for ten source minutes.
public func spectralMemoryProbe() throws -> [SpectralMemoryObservation] {
    let item = try ProductCase(rate: 48_000, seconds: 1, milliseconds: 64)
    let pcm = (0..<item.sampleRate).map(ProductCase.sample)
    let worker = try PreparedSpectrogram<Double>(layout: item.layout, epoch: item.source.epoch)
    let aggregate = try LongTermSpectrumAccumulator(layout: item.layout, epoch: item.source.epoch)
    let ring = try RollingSpectralProducts(layout: item.layout, capacity: 64)
    var observations: [SpectralMemoryObservation] = []
    observations.reserveCapacity(10)
    for second in 1...600 {
        let source = try SourceInterval(
            epoch: item.source.epoch, startSample: Int64((second - 1) * item.sampleRate),
            sampleCount: Int64(item.sampleRate), sampleRate: Double(item.sampleRate))
        _ = try pcm.withUnsafeBufferPointer {
            try worker.process($0, interval: source) { row in
                try! aggregate.append(row)
                try! ring.append(row)
            }
        }
        if second.isMultiple(of: 60) {
            let observed = try SourceInterval(
                epoch: source.epoch, startSample: 0, sampleCount: source.endSample,
                sampleRate: source.sampleRate)
            let count = try aggregate.snapshot(observedSource: observed).measuredFrames
            precondition(
                count
                    == (try! item.layout.framing.completeFrameCount(
                        observedSampleCount: source.endSample)))
            precondition(
                ring.count == ring.capacity && ring.evictedCount + UInt64(ring.count) == count)
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            observations.append(
                SpectralMemoryObservation(
                    seconds: second, liveHeapBytes: UInt64(stats.size_in_use),
                    retainedFrames: ring.count, evictedFrames: ring.evictedCount,
                    measuredFrames: count))
        }
    }
    _ = try worker.finish { _ in preconditionFailure("Unexpected partial spectrum") }
    return observations
}
