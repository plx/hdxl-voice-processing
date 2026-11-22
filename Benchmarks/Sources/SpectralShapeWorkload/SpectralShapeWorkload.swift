import Foundation
import HDXLVoiceProcessing

public enum ShapeOperation: String, CaseIterable, Sendable {
    case fft = "FFT"
    case fftAndShape = "FFTAndShape"
    case shared = "SharedFrame"
    case separate = "SeparateFrame"
    case ltas = "SharedLTAS"
    case separateLTAS = "SeparateLTAS"
    case rolling = "RollingLTAS"
}

public struct ShapeCase: Encodable, Sendable {
    public let name: String
    public let sampleRate = 16000
    public let durationSeconds: Int
    public let layout: SpectrogramLayout
    public let frameProfile: SpectralShapeProfile
    public let aggregateProfile: SpectralShapeProfile
    public let frameIdentity: ProfileIdentity
    public let aggregateIdentity: ProfileIdentity
    public let expectedFrames: Int
    public let fitBins: Int
    public let intervals: [SourceInterval]

    init(fft: Int, upper: Double, seconds: Int) throws {
        let length = fft == 256 ? 250 : 1000
        let hop = length / 2
        name = "fft\(fft)-band\(Int(upper))-s\(seconds)"
        durationSeconds = seconds
        let frame = try FramingConfiguration(
            window: .init(
                definition: .hannPeriodic, sampleCount: length,
                sampleRate: Double(sampleRate)), hopLength: hop)
        layout = try SpectrogramLayout(
            framing: frame, transformLength: fft,
            channels: PCMChannelSelection(channelIndex: 0))
        let band = try SpectralFrequencyBand(lowerHz: 0, upperHz: upper)
        let fit = try SpectralFrequencyBand(lowerHz: 125, upperHz: upper / 2)
        let ratio = try SpectralBandRatioDefinition(
            name: .init(name: "benchmark-low-high", version: 1),
            numerator: .init(lowerHz: 0, upperHz: upper / 4),
            denominator: .init(lowerHz: upper / 4, upperHz: upper))
        func profile(_ source: SpectralShapeSource) throws -> SpectralShapeProfile {
            try .init(
                source: source, analysisBand: band, includeDC: false, relativeLogFloorDB: -100,
                bandRatio: ratio, fitBand: fit)
        }
        frameProfile = try profile(.frame)
        aggregateProfile = try profile(.longTermSpectrum)
        frameIdentity = try frameProfile.identity(for: layout)
        aggregateIdentity = try aggregateProfile.identity(for: layout)
        let rate = sampleRate
        let step = Double(rate) / Double(fft)
        fitBins = Int(floor(fit.upperHz / step) - ceil(fit.lowerHz / step)) + 1
        expectedFrames = 1 + (rate * seconds - length) / hop
        let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000045")!)
        intervals = try [0, hop].map {
            try SourceInterval(
                epoch: epoch, startSample: Int64($0),
                sampleCount: Int64(rate * seconds), sampleRate: Double(rate))
        }
    }

    public static func matrix() throws -> [Self] {
        var cases: [Self] = []
        for n in [256, 2048] {
            for upper in [2000.0, 8000.0] {
                for seconds in [1, 8] {
                    cases.append(try .init(fft: n, upper: upper, seconds: seconds))
                }
            }
        }
        return cases
    }
}

/// Two exact-duration sliding intervals on the same synthetic recording, separated by one hop.
/// Frame trials measure the first interval. LTAS trials evaluate both successive snapshots.
public final class ShapeTrial {
    private let item: ShapeCase
    private let pcm: [Double]
    private let frames: [[SpectrogramFrame]]
    private let means: [LongTermSpectrum]
    private let shape: PreparedSpectralShape
    private let aggregateShape: PreparedSpectralShape
    private let fftReference: Double
    private let frameReference: Double
    private let meanReference: Double
    private var generator: PreparedSpectrogram<Double>?
    private var accumulators: [LongTermSpectrumAccumulator] = []
    private var observed = 0.0
    private var count = 0

    public init(_ item: ShapeCase) throws {
        self.item = item
        let span = item.intervals[0]
        let input = (0..<Int(item.intervals[1].endSample)).map { i in
            Double(i % 257 - 128) / 256 + Double(i % 89 - 44) / 256
        }
        let frameShape = try PreparedSpectralShape(
            layout: item.layout, configuration: item.frameProfile)
        let longShape = try PreparedSpectralShape(
            layout: item.layout, configuration: item.aggregateProfile)
        var columns: [[SpectrogramFrame]] = []
        var snapshots: [LongTermSpectrum] = []
        for interval in item.intervals {
            let fft = try PreparedSpectrogram<Double>(
                layout: item.layout, epoch: span.epoch, startSample: interval.startSample)
            let accumulator = try LongTermSpectrumAccumulator(
                layout: item.layout, epoch: span.epoch, startSample: interval.startSample)
            var rows: [SpectrogramFrame] = []
            _ = try input.withUnsafeBufferPointer { samples in
                let window = Int(interval.startSample)..<Int(interval.endSample)
                return try fft.process(
                    UnsafeBufferPointer(rebasing: samples[window]), interval: interval
                ) { rows.append($0.owned()) }
            }
            _ = try fft.finish { rows.append($0.owned()) }
            precondition(rows.count == item.expectedFrames)
            for row in rows { try accumulator.append(row) }
            let latest = try accumulator.snapshot(observedSource: interval)
            precondition(
                latest.timing.coverage == 1 && latest.measuredFrames == UInt64(item.expectedFrames))
            columns.append(rows)
            snapshots.append(latest)
        }
        pcm = Array(input.prefix(Int(span.sampleCount)))
        frames = columns
        means = snapshots
        shape = frameShape
        aggregateShape = longShape
        fftReference = columns[0].reduce(0) { $0 + $1.binPower[1] }
        frameReference = try columns[0].reduce(0) { $0 + Self.score(try frameShape.evaluate($1)) }
        meanReference = try snapshots.reduce(0) { $0 + Self.score(try longShape.evaluate($1)) }
        precondition(fftReference > 0 && frameReference.isFinite && meanReference.isFinite)
    }

    private static func score(_ result: SpectralShapeResult) -> Double {
        SpectralShapeDescriptor.allCases.reduce(0) { $0 + result[$1]!.outcome.estimate!.value }
    }

    public func prepare(_ operation: ShapeOperation) throws {
        count = 0
        observed = 0
        switch operation {
        case .fft, .fftAndShape:
            generator = try PreparedSpectrogram<Double>(
                layout: item.layout, epoch: item.intervals[0].epoch)
        case .rolling:
            accumulators = try item.intervals.map {
                try LongTermSpectrumAccumulator(
                    layout: item.layout, epoch: $0.epoch, startSample: $0.startSample)
            }
        default: break
        }
    }

    @inline(never) public func run(_ operation: ShapeOperation) throws {
        switch operation {
        case .fft, .fftAndShape:
            let generator = generator!
            _ = try pcm.withUnsafeBufferPointer {
                try generator.process($0, interval: item.intervals[0]) { row in
                    // Identically probe FFT output in both PCM paths.
                    observed += row.binPower[1]
                    if operation == .fftAndShape {
                        observed += Self.score(try! shape.evaluate(row))
                    }
                    count += 1
                }
            }
            _ = try generator.finish { _ in preconditionFailure("Unexpected incomplete frame") }
        case .shared, .separate:
            for row in frames[0] {
                if operation == .shared {
                    observed += Self.score(try shape.evaluate(row))
                } else {
                    observed += try SpectralShapeDescriptor.allCases.reduce(0) { sum, d in
                        sum + (try shape.evaluate(row, only: d))[d]!.outcome.estimate!.value
                    }
                }
                count += 1
            }
        case .ltas, .separateLTAS:
            for mean in means {
                if operation == .ltas {
                    observed += Self.score(try aggregateShape.evaluate(mean))
                } else {
                    observed += try SpectralShapeDescriptor.allCases.reduce(0) { sum, d in
                        sum
                            + (try aggregateShape.evaluate(mean, only: d))[d]!.outcome.estimate!
                            .value
                    }
                }
                count += 1
            }
        case .rolling:
            for i in item.intervals.indices {
                for frame in frames[i] { try accumulators[i].append(frame) }
                let mean = try accumulators[i].snapshot(observedSource: item.intervals[i])
                observed += Self.score(try aggregateShape.evaluate(mean))
                count += 1
            }
        }
    }

    public func verify(_ operation: ShapeOperation) throws {
        let expected: Double
        switch operation {
        case .fft: expected = fftReference
        case .fftAndShape: expected = fftReference + frameReference
        case .shared, .separate: expected = frameReference
        case .ltas, .separateLTAS, .rolling: expected = meanReference
        }
        let aggregates = operation == .ltas || operation == .separateLTAS || operation == .rolling
        precondition(count == (aggregates ? means.count : item.expectedFrames))
        precondition(abs(observed - expected) <= max(1, abs(expected)) * 1e-12)
    }
}
