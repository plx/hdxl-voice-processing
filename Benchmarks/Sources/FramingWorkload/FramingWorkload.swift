import Foundation
import HDXLVoiceProcessing

public struct FramingCase: Codable, Sendable {
    public let name: String
    public let configuration: FramingConfiguration
    public let framingIdentity: ProfileIdentity
    public let requestedWindowSeconds: Double?
    public let requestedHopSeconds: Double
    public let inputSampleCount: Int
    public let inputDurationSeconds: Double
    public let expectedFrameCount: UInt64
    public let smallChunkSamples: Int
    public let primitiveOperationsPerIteration: Int
    public let preparedBufferBytes: Int

    private init(
        rate: Double, seconds: Double?, hop: Double, precision: AnalysisPrecision,
        shape: WindowDefinition = .praatGaussian2
    ) throws {
        let length =
            try seconds.map {
                try SampleCountQuantization(seconds: $0, sampleRate: rate).sampleCount
            }
            ?? WindowSpecification.maximumSampleCount
        let step = try SampleCountQuantization(seconds: hop, sampleRate: rate).sampleCount
        configuration = try FramingConfiguration(
            window: WindowSpecification(
                definition: shape,
                sampleCount: length, sampleRate: rate, precision: precision), hopLength: step)
        framingIdentity = try configuration.identity()
        name = "\(precision.rawValue).\(Int(rate))Hz.N\(length).H\(step).\(shape.rawValue)"
        requestedWindowSeconds = seconds
        requestedHopSeconds = hop
        inputSampleCount = max(Int(rate), length + 10 * step)
        inputDurationSeconds = Double(inputSampleCount) / rate
        expectedFrameCount = try configuration.completeFrameCount(
            observedSampleCount: Int64(inputSampleCount))
        smallChunkSamples = 17
        primitiveOperationsPerIteration = 100
        preparedBufferBytes = 3 * length * (precision == .float32 ? 4 : 8)
    }

    /// Common Gaussian supports, maximum supported support, and all other window shapes.
    public static func matrix() throws -> [Self] {
        var result: [Self] = []
        for precision in [AnalysisPrecision.float32, .float64] {
            for rate in [16_000.0, 44_100, 48_000] {
                for seconds in [0.020, 0.050, 0.100] {
                    for hop in [0.002, 0.005, 0.010, 0.030] {
                        result.append(
                            try Self(rate: rate, seconds: seconds, hop: hop, precision: precision))
                    }
                }
                result.append(try Self(rate: rate, seconds: nil, hop: 0.002, precision: precision))
            }
            for shape in WindowDefinition.allCases where shape != .praatGaussian2 {
                result.append(
                    try Self(
                        rate: 48_000, seconds: 0.05, hop: 0.005, precision: precision, shape: shape)
                )
            }
        }
        return result
    }
    public func makeWorkload() throws -> any FramingBatch {
        if configuration.window.precision == .float32 { return try FramingWorkload<Float>(self) }
        return try FramingWorkload<Double>(self)
    }
}

public protocol FramingBatch: AnyObject {
    var preparedBufferBytes: Int { get }
    var checksum: Double { get }
    var expectedChecksum: Double { get }
    var frameCount: UInt64 { get }
    func restart() throws
    func run(chunkSize: Int) throws
    func reuseWindow() throws -> Double
    func prepare() throws -> AnyObject
}

private final class FramingWorkload<Sample: BinaryFloatingPoint & Sendable>: FramingBatch {
    var preparedBufferBytes: Int { framer.preparedBufferBytes }
    let item: FramingCase
    let input: [Sample]
    let output: UnsafeMutableBufferPointer<Sample>
    let framer: PCMFramer<Sample>
    let window: PreparedWindow<Sample>
    private(set) var checksum = 0.0
    private(set) var frameCount: UInt64 = 0
    let expectedChecksum: Double

    init(_ item: FramingCase) throws {
        self.item = item
        input = (0..<item.inputSampleCount).map { Sample(Double($0 % 257 - 128) / 128) }
        framer = try PCMFramer(
            configuration: item.configuration, epoch: StreamEpoch(streamID: UUID()))
        window = framer.preparedWindow!
        let count = item.configuration.window.sampleCount
        let center = count / 2
        let coefficient = window.coefficientSnapshot()[center]
        var sum = 0.0
        for ordinal in 0..<item.expectedFrameCount {
            let position = Int(ordinal) * item.configuration.hopLength + center
            sum += Double(input[position] * coefficient)
        }
        expectedChecksum = sum
        output = .allocate(capacity: count)
        output.initialize(repeating: 0)
    }
    deinit {
        output.deinitialize()
        output.deallocate()
    }
    func restart() throws {
        try framer.reset(
            for: SourceDiscontinuity(
                previousEpoch: framer.epoch,
                nextEpoch: framer.epoch.successor(), reason: .explicitReset))
        checksum = 0
        frameCount = 0
    }
    @inline(never)
    func run(chunkSize: Int) throws {
        precondition(chunkSize > 0)
        try input.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < input.count {
                let count = min(chunkSize, input.count - offset)
                try framer.process(
                    UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                    interval: SourceInterval(
                        epoch: framer.epoch, startSample: Int64(offset),
                        sampleCount: Int64(count), sampleRate: item.configuration.window.sampleRate)
                ) {
                    samples, support in
                    precondition(support.unavailability == nil)
                    try! window.write(samples, into: output)
                    checksum += Double(output[output.count / 2])
                    frameCount += 1
                }
                offset += count
            }
        }
        let completion = try framer.finish { _, _ in
            preconditionFailure("Unexpected unavailable tail")
        }
        precondition(completion.completeFrameCount == item.expectedFrameCount)
    }
    @inline(never)
    func reuseWindow() throws -> Double {
        _ = try input.withUnsafeBufferPointer { buffer in
            try window.write(UnsafeBufferPointer(rebasing: buffer[..<output.count]), into: output)
        }
        return Double(output[output.count / 2])
    }
    @inline(never)
    func prepare() throws -> AnyObject {
        try PCMFramer<Sample>(configuration: item.configuration, epoch: framer.epoch)
    }
}
