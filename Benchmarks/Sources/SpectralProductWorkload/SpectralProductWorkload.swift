import Foundation
import HDXLVoiceProcessing

public enum ProductOperation: String, CaseIterable, Sendable {
    case generate = "Generate"
    case average = "LTAS"
    case retain8 = "Retain8"
    case retain64 = "Retain64"
    case export = "Export"
    var capacity: Int { self == .retain64 ? 64 : 8 }
}

public struct ProductCase: Encodable, Sendable {
    public let name: String
    public let sampleRate: Int
    public let durationSeconds: Int
    public let inputSamples: Int
    public let windowMilliseconds: Int
    public let layout: SpectrogramLayout
    public let cepstrogram: CepstrogramConfiguration
    public let expectedCepstralFrames: Int
    public let expectedFrames: Int
    public let source: SourceInterval

    public init(rate: Int, seconds: Int, milliseconds: Int) throws {
        name = "fs\(rate)-s\(seconds)-w\(milliseconds)"
        sampleRate = rate
        durationSeconds = seconds
        windowMilliseconds = milliseconds
        inputSamples = rate * seconds
        let length = (rate * milliseconds + 500) / 1000
        let framing = try FramingConfiguration(
            window: WindowSpecification(
                definition: .hannPeriodic, sampleCount: length,
                sampleRate: Double(rate)), hopLength: length / 2)
        layout = try SpectrogramLayout(
            framing: framing, transformLength: FourierConfiguration.lengthPadding(length),
            channels: PCMChannelSelection(channelIndex: 0), weighting: .newlyCoveredSamples)
        expectedFrames = try Int(
            framing.completeFrameCount(observedSampleCount: Int64(inputSamples)))
        cepstrogram = try CepstrogramConfiguration(
            sourceSampleRate: rate, analysisSampleRate: 4000,
            pitchFloorHz: 6000 / Double(milliseconds), hopSeconds: Double(milliseconds) / 2000,
            declaredInputBandwidthHz: Double(rate) / 2,
            conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
        let targetCount = seconds * cepstrogram.frame.sampleRate
        let cepHop = cepstrogram.previewHopLength!
        let complete = 1 + (targetCount - cepstrogram.frame.frameLength) / cepHop
        expectedCepstralFrames = complete + (complete * cepHop < targetCount ? 1 : 0)
        source = try SourceInterval(
            epoch: StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!),
            startSample: 0, sampleCount: Int64(inputSamples), sampleRate: Double(rate))
    }

    public static func matrix() throws -> [Self] {
        var cases: [Self] = []
        for rate in [16_000, 44_100, 48_000] {
            for seconds in [1, 10, 60] {
                for width in [20, 64] {
                    cases.append(try Self(rate: rate, seconds: seconds, milliseconds: width))
                }
            }
        }
        return cases
    }

    static func sample(_ i: Int) -> Double { Double(i % 257 - 128) / 128 }
}

/// Retained offline inputs exist only in the benchmark harness to isolate each consumer from the FFT.
public final class ProductTrial {
    let item: ProductCase
    let input: [Double]
    let frames: [SpectrogramFrame]
    let probe: Int
    let expectedSum: Double
    let expectedMean: Double
    var generator: PreparedSpectrogram<Double>?
    var accumulator: LongTermSpectrumAccumulator?
    var ring: RollingSpectralProducts?
    var lastCopy: SpectrogramFrame?
    var count = 0
    var observedSum = 0.0

    public init(_ item: ProductCase) throws {
        self.item = item
        input = (0..<item.inputSamples).map(ProductCase.sample)
        let prepared = try PreparedSpectrogram<Double>(
            layout: item.layout, epoch: item.source.epoch)
        var rows: [SpectrogramFrame] = []
        rows.reserveCapacity(item.expectedFrames)
        _ = try input.withUnsafeBufferPointer {
            try prepared.process($0, interval: item.source) { rows.append($0.owned()) }
        }
        _ = try prepared.finish { rows.append($0.owned()) }
        precondition(
            rows.count == item.expectedFrames && rows.allSatisfy { $0.info.status == .measured })
        frames = rows
        let index = max(1, item.layout.spectrum.transform.length / 257)
        probe = index
        expectedSum = rows.reduce(0) { $0 + $1.binPower[index] }
        expectedMean =
            rows.reduce(0) { $0 + $1.binPower[index] * Double($1.info.weight) }
            / Double(rows.reduce(Int64(0)) { $0 + $1.info.weight })
        precondition(expectedSum > 0 && expectedMean > 0)
    }

    public func prepare(_ operation: ProductOperation) throws {
        count = 0
        observedSum = 0
        lastCopy = nil
        switch operation {
        case .generate:
            generator = try PreparedSpectrogram(layout: item.layout, epoch: item.source.epoch)
        case .average:
            accumulator = try LongTermSpectrumAccumulator(
                layout: item.layout, epoch: item.source.epoch)
        case .retain8, .retain64:
            ring = try RollingSpectralProducts(layout: item.layout, capacity: operation.capacity)
        case .export: break
        }
    }

    @inline(never) public func run(_ operation: ProductOperation) throws {
        switch operation {
        case .generate:
            let generator = generator!
            _ = try input.withUnsafeBufferPointer {
                try generator.process($0, interval: item.source) { row in
                    observedSum += row.binPower[probe]
                    count += 1
                }
            }
            _ = try generator.finish { _ in preconditionFailure("Unexpected padded frame") }
        case .average:
            let accumulator = accumulator!
            for row in frames { try accumulator.append(row) }
        case .retain8, .retain64:
            let ring = ring!
            for row in frames { try row.withBorrowedFrame { try ring.append($0) } }
        case .export:
            for row in frames {
                lastCopy = row.withBorrowedFrame { $0.owned() }
                observedSum += lastCopy!.binPower[probe]
                count += 1
            }
        }
    }

    public func verify(_ operation: ProductOperation) throws {
        switch operation {
        case .generate, .export:
            precondition(count == item.expectedFrames && observedSum == expectedSum)
            if operation == .export { precondition(lastCopy == frames.last) }
        case .average:
            let snapshot = try accumulator!.snapshot(observedSource: item.source)
            precondition(
                snapshot.measuredFrames == UInt64(item.expectedFrames)
                    && abs(snapshot.meanBinPower[probe] - expectedMean) < 1e-10)
        case .retain8, .retain64:
            let snapshot = ring!.snapshot()
            let kept = min(operation.capacity, item.expectedFrames)
            precondition(
                snapshot.evictedCount == UInt64(item.expectedFrames - kept)
                    && snapshot.columns.count == kept)
            precondition(
                snapshot.columns == frames.suffix(kept).map(SpectralProductColumn.spectrum))
        }
    }
}
