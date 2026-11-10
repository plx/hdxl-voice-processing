import Foundation
import HDXLVoiceProcessing

public enum SWIPEPrimeBenchmarkAlgorithm: String, CaseIterable, Codable, Sendable {
    case swipePrime = "SWIPEPrime"
    case yinFFT = "YINFFT"
}
public enum SWIPEPrimeBenchmarkOperation: String, CaseIterable {
    case prepare = "Prepare"
    case run = "Run"
}
public enum SWIPEPrimeWorkloadKind: String, Codable, Sendable {
    case harmonic = "Harmonic"
    case maximum = "MaximumGeometry"
    case silence = "Silence"
    case noise = "Noise"
    case export = "OwnedDiagnostics"
}

/// Both algorithms consume exactly the same input, retaining their own support
/// and valid hop. A shorter dependency is not relabelled as equivalent latency.
public struct SWIPEPrimeCase: Encodable, Sendable {
    public let name: String
    public let kind: SWIPEPrimeWorkloadKind
    public let configuration: SWIPEPrimeConfiguration
    public let baseline: YINProfile
    public let requestedHopMilliseconds: Int
    public let inputSampleCount: Int
    public let chunkSamples = 256
    public var shard: String {
        kind == .harmonic
            ? "rate\(configuration.sampleRate)-\(configuration.inputPrecision.rawValue)"
            : kind.rawValue
    }
    public var inputDurationSeconds: Double {
        Double(inputSampleCount) / Double(configuration.sampleRate)
    }

    private init(
        kind: SWIPEPrimeWorkloadKind = .harmonic, rate: Int = 48000,
        precision: AnalysisPrecision = .float64, floor: Int = 80, ceiling: Int = 400,
        hopMS: Int = 10
    ) throws {
        self.kind = kind
        requestedHopMilliseconds = hopMS
        let hop = (rate * hopMS + 500) / 1000
        configuration = try SWIPEPrimeConfiguration(
            sampleRate: rate, inputPrecision: precision,
            pitchFloorHz: Double(floor), pitchCeilingHz: Double(ceiling), hopLength: hop,
            candidatesPerOctave: kind == .maximum ? 192 : 96)
        let yinSupport = 2 * Int(ceil(Double(rate) / Double(floor))) + 1
        baseline = try YINProfile(
            estimator: YINConfiguration(
                sampleRate: rate, inputPrecision: precision,
                pitchFloorHz: Double(floor), pitchCeilingHz: Double(ceiling),
                hopLength: min(hop, yinSupport),
                differenceBackend: .fft))
        switch kind {
        case .maximum, .export: inputSampleCount = configuration.requiredSampleCount + 3 * hop + 1
        case .silence, .noise: inputSampleCount = 10 * rate
        case .harmonic: inputSampleCount = 2 * rate
        }
        name =
            "\(kind.rawValue).\(precision.rawValue).\(rate)Hz.n\(inputSampleCount).f\(floor)-\(ceiling).h\(hopMS).r\(configuration.candidatesPerOctave)"
    }

    public static func matrix() throws -> [Self] {
        var result: [Self] = []
        for rate in [16000, 44100, 48000] {
            for precision in [AnalysisPrecision.float32, .float64] {
                for (floor, ceiling) in [(80, 400), (25, 2000)] {
                    for hop in [5, 10, 20] {
                        result.append(
                            try Self(
                                rate: rate, precision: precision, floor: floor, ceiling: ceiling,
                                hopMS: hop))
                    }
                }
            }
        }
        for precision in [AnalysisPrecision.float32, .float64] {
            result.append(
                try Self(
                    kind: .maximum, rate: 192000, precision: precision, floor: 20, ceiling: 48000))
            for kind in [SWIPEPrimeWorkloadKind.silence, .noise, .export] {
                result.append(try Self(kind: kind, precision: precision))
            }
        }
        return result
    }

    public func makeWorkload(algorithm: SWIPEPrimeBenchmarkAlgorithm) throws -> any SWIPEPrimeBatch
    {
        if configuration.inputPrecision == .float32 {
            return try SWIPEPrimeWorkload<Float>(self, algorithm: algorithm)
        }
        return try SWIPEPrimeWorkload<Double>(self, algorithm: algorithm)
    }
}
