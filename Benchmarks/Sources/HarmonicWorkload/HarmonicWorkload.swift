import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum HarmonicOperation: String, CaseIterable {
    case raw = "RawFit"
    case corrected = "SuppliedCorrection"
    case dependencies = "YINAndBurg"
    case complete = "Complete"
}

public struct HarmonicCase: Encodable {
    public let name: String
    public let profile: HarmonicCorrectionProfile
    public let rawIdentity, correctedIdentity: ProfileIdentity
    public let source: SourceInterval
    public let yin: YINConfiguration
    public let excitationHz: Double
    public let firstResonanceHz: Double

    public static func matrix() throws -> [Self] {
        let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000052")!)
        var cases: [Self] = []
        for rate in [16000, 44100, 48000] {
            let count = rate / 20
            let yin = try YINConfiguration(
                sampleRate: rate, pitchFloorHz: 80, pitchCeilingHz: 450,
                integrationLength: count - Int(ceil(Double(rate) / 80)) - 1, hopLength: rate / 100)
            let source = try SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: Int64(count), sampleRate: Double(rate))
            for periods in [3, 5] {
                let fit = try HarmonicFitProfile(
                    sourceSampleRate: rate, periods: periods, pitch: .yin(yin))
                let config = try HarmonicCorrectionProfile(
                    fit: fit, formants: .init(sourceSampleRate: rate, ceilingHz: 5000))
                for near in [false, true] {
                    cases.append(
                        try Self(
                            name: "r\(rate)-p\(periods)-\(near ? "near" : "ordinary")",
                            profile: config, rawIdentity: fit.identity(),
                            correctedIdentity: config.identity(),
                            source: source, yin: yin, excitationHz: 137.3,
                            firstResonanceHz: near ? 291 : 640))
                }
            }
        }
        return cases
    }
}

private enum WorkloadError: Error {
    case unavailable(String)
}

private final class Dependencies {
    let item: HarmonicCase
    let yin: PreparedYIN<Double>
    let burg: PreparedBurgFormants<Double>
    let timing: AnalysisTiming

    init(_ item: HarmonicCase) throws {
        self.item = item
        yin = try .init(item.yin)
        burg = try .init(configuration: item.profile.formants, source: item.source)
        timing = try .init(source: item.source, includedSampleCount: item.source.sampleCount)
    }

    func analyze(_ pcm: UnsafeBufferPointer<Double>) throws -> (MeasurementResult, BurgFormantFrame)
    {
        var observation: YINFrameResult?
        try yin.analyze(pcm, timing: timing) { observation = $0.result }
        guard let observation, observation.status == .voiced
        else {
            throw WorkloadError.unavailable("YIN did not return a voiced estimate for " + item.name)
        }
        let pitch = try observation.measurementResult()
        let evidence = try FormantPitchEvidence(measurement: pitch)
        var formants: BurgFormantFrame?
        try burg.analyze(
            pcm, source: item.source, pitch: { _ in evidence }, emit: { formants = $0 })
        guard let formants, burg.frameCount == 1, formants.timing.source == item.source
        else { throw WorkloadError.unavailable("Unexpected Burg frame geometry for " + item.name) }
        return (pitch, formants)
    }
}

public final class HarmonicTrial {
    private let item: HarmonicCase
    private let pcm: [Double]
    private let pcm16LESHA256: String
    private let dependencies: Dependencies
    private let analyzer: PreparedHarmonicDifference<Double>
    private let pitch: MeasurementResult
    private let formants: BurgFormantFrame
    private let expected: CorrectedHarmonicFrame
    private var rawOutput: RawHarmonicFrame?
    private var correctedOutput: CorrectedHarmonicFrame?
    private var dependencyOutput: (MeasurementResult, BurgFormantFrame)?

    public init(_ item: HarmonicCase) throws {
        self.item = item
        analyzer = try .init(item.profile)
        dependencies = try .init(item)
        let samples = Self.synthesize(item)
        pcm = samples.map { Double($0) / 32768 }
        pcm16LESHA256 = samples.map(\.littleEndian).withUnsafeBytes {
            SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined()
        }
        (pitch, formants) = try pcm.withUnsafeBufferPointer { [dependencies] in
            try dependencies.analyze($0)
        }
        expected = try pcm.withUnsafeBufferPointer { [analyzer, pitch, formants] in
            try analyzer.analyze($0, source: item.source, pitch: pitch, formants: formants)
        }
        guard expected.failure == nil, expected.contributions.count == 2,
            expected.contributions.first?.nearResonance == (item.firstResonanceHz == 291),
            let measuredPitch = pitch.outcome.estimate?.value,
            abs(measuredPitch - item.excitationHz) < 3
        else {
            throw WorkloadError.unavailable(
                "\(item.name), pitch \(String(describing: pitch.outcome.estimate?.value)), raw \(String(describing: expected.raw.failure)), corrected \(String(describing: expected.failure))"
            )
        }
    }

    /// Deterministic band-limited periodic excitation with a low noise floor, passed through four causal resonances.
    private static func synthesize(_ item: HarmonicCase) -> [Int16] {
        let n = Int(item.source.sampleCount)
        let rate = item.source.sampleRate
        let warm = 4 * n
        var state: UInt32 = 52
        var data = (0..<warm + n).map { i in
            state = state &* 1_664_525 &+ 1_013_904_223
            let p = 2 * Double.pi * item.excitationHz * Double(i) / rate
            var sample = 0.10 * (Double(state) / Double(UInt32.max) - 0.5)
            for h in 1...Int(4800 / item.excitationHz) {
                sample += cos(Double(h) * p) / sqrt(Double(h))
            }
            return sample
        }
        for (frequency, bandwidth) in [
            (item.firstResonanceHz, 110.0), (1500, 115), (2660, 150), (3650, 190),
        ] {
            let r = exp(-Double.pi * bandwidth / rate)
            let feedback = 2 * r * cos(2 * Double.pi * frequency / rate)
            var a = 0.0
            var b = 0.0
            for i in data.indices {
                let y = (1 - feedback + r * r) * data[i] + feedback * a - r * r * b
                data[i] = y
                b = a
                a = y
            }
        }
        let cut = data.suffix(n)
        let scale = 0.5 / cut.reduce(0.0) { max($0, abs($1)) }
        return cut.map { Int16((scale * $0 * 32768).rounded(.toNearestOrEven)) }
    }

    public func prepare() {
        rawOutput = nil
        correctedOutput = nil
        dependencyOutput = nil
    }
    public func run(_ operation: HarmonicOperation) throws {
        switch operation {
        case .raw:
            rawOutput = try pcm.withUnsafeBufferPointer {
                try analyzer.fit($0, source: item.source, pitch: pitch)
            }
        case .corrected: correctedOutput = try analyzer.correct(expected.raw, formants: formants)
        case .dependencies:
            dependencyOutput = try pcm.withUnsafeBufferPointer { try dependencies.analyze($0) }
        case .complete:
            correctedOutput = try pcm.withUnsafeBufferPointer {
                let (current, model) = try dependencies.analyze($0)
                return try analyzer.analyze(
                    $0, source: item.source, pitch: current, formants: model)
            }
        }
    }
    public func verify(_ operation: HarmonicOperation) throws {
        let valid: Bool
        switch operation {
        case .raw: valid = rawOutput == expected.raw
        case .corrected, .complete: valid = correctedOutput == expected
        case .dependencies: valid = dependencyOutput?.0 == pitch && dependencyOutput?.1 == formants
        }
        guard valid else { throw WorkloadError.unavailable(item.name + " " + operation.rawValue) }
    }

    public struct Observation: Encodable {
        public let name: String
        public let configuration: HarmonicCase
        public let pcm16LESHA256: String
        public let measuredPitchHz: Double
        public let windowSamples: Int64
        public let rawDB, correctedDB: Double
        public let contributions: [HarmonicFormantContribution]
    }
    public func observation() throws -> Observation {
        guard let hz = pitch.outcome.estimate?.value,
            let raw = expected.raw.measurement.outcome.estimate?.value,
            let corrected = expected.measurement.outcome.estimate?.value
        else { throw WorkloadError.unavailable(item.name) }
        return Observation(
            name: item.name, configuration: item, pcm16LESHA256: pcm16LESHA256, measuredPitchHz: hz,
            windowSamples: expected.raw.measurement.timing.source.sampleCount,
            rawDB: raw, correctedDB: corrected, contributions: expected.contributions)
    }
}
