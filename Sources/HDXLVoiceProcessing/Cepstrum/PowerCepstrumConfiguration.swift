import CryptoKit
import Foundation

public enum CepstrumError: Error, Sendable, Equatable {
    case invalidConfiguration, precisionMismatch, invalidBufferSize, nonfiniteInput
    case unexpectedInterval, insufficientData, capacityExceeded, invalidState, reentrantCall,
        nonfiniteResult
}

/// The numerical recipe is versioned separately from package releases. Analysis
/// uses Double arithmetic: Float spectral rounding can turn deep minima into zeros
/// before the logarithm. Float PCM is explicitly converted before conditioning.
public enum PowerCepstrumDefinition: String, Sendable, Hashable, Codable {
    case praat7002 = "praat-7.0.02-power-cepstrum"
}

/// One already-conditioned mono frame: mean removal, Gaussian2, dt-scaled DFT,
/// natural log of twice the squared complex magnitude, fs-scaled inverse, square.
/// The pinned definition adds 1e-300 before logging every bin EXCEPT Nyquist.
/// A zero Nyquist produces unavailable cepstral output, never a fabricated floor.
public struct PowerCepstrumConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let definition: PowerCepstrumDefinition
    public let sampleRate: Int
    public let precision: AnalysisPrecision
    public let pitchFloorHz: Double
    public let frameLength: Int
    public let transformLength: Int
    public var binCount: Int { transformLength / 2 + 1 }
    public var physicalWidthSeconds: Double { 2 * (3 / pitchFloorHz) }
    public var frequencyStepHz: Double { Double(sampleRate) / Double(transformLength) }
    public var quefrencyStepSeconds: Double { 1 / Double(sampleRate) }

    public init(sampleRate: Int = 10_000, pitchFloorHz: Double = 60) throws {
        guard (4000...192_000).contains(sampleRate), pitchFloorHz.isFinite,
            (20...1000).contains(pitchFloorHz)
        else { throw CepstrumError.invalidConfiguration }
        let length = Int(
            (2 * (3 / pitchFloorHz) / (1 / Double(sampleRate)))
                .rounded(.toNearestOrAwayFromZero))
        guard (2...WindowSpecification.maximumSampleCount).contains(length) else {
            throw CepstrumError.capacityExceeded
        }
        self.schemaVersion = 1
        self.definition = .praat7002
        self.sampleRate = sampleRate
        self.precision = .float64
        self.pitchFloorHz = pitchFloorHz
        self.frameLength = length
        self.transformLength = try FourierConfiguration.lengthPadding(length)
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: definition.rawValue, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, definition, sampleRate, precision, pitchFloorHz, frameLength,
            transformLength
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            pitchFloorHz: c.decode(Double.self, forKey: .pitchFloorHz))
        guard try c.decode(PowerCepstrumDefinition.self, forKey: .definition) == definition,
            try c.decode(AnalysisPrecision.self, forKey: .precision) == .float64,
            try c.decode(Int.self, forKey: .frameLength) == frameLength,
            try c.decode(Int.self, forKey: .transformLength) == transformLength
        else {
            throw CepstrumError.invalidConfiguration
        }
    }
}

/// Full PCM-to-cepstrum settings. Whole-interval and finite-FIR preview conditioning
/// have different profiles, grids, support and latency. Neither requires an F0 estimate.
/// Input PCM encoding and Double analysis arithmetic are separate serialized facts.
public struct CepstrogramConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let inputPrecision: AnalysisPrecision
    public let frame: PowerCepstrumConfiguration
    /// Resampling only. This pipeline applies its own explicitly fused pre-emphasis.
    public let conditioning: ConditioningConfiguration
    public let preEmphasisFromHz: Double
    public let hopSeconds: Double
    public let previewHopLength: Int?
    public var preEmphasisCoefficient: Double {
        exp(-2 * .pi * preEmphasisFromHz * (1 / Double(frame.sampleRate)))
    }

    public init(
        sourceSampleRate: Int, analysisSampleRate: Int = 10_000,
        inputPrecision: AnalysisPrecision = .float64, pitchFloorHz: Double = 60,
        hopSeconds: Double = 0.002, preEmphasisFromHz: Double = 50,
        declaredInputBandwidthHz: Double,
        conditioningMethod: ConditioningMethod = .praat7WholeInterval(interpolationDepth: 50)
    ) throws {
        let frame = try PowerCepstrumConfiguration(
            sampleRate: analysisSampleRate, pitchFloorHz: pitchFloorHz)
        guard hopSeconds.isFinite, (0.0001...frame.physicalWidthSeconds).contains(hopSeconds),
            preEmphasisFromHz.isFinite,
            (0...Double(analysisSampleRate) / 2).contains(preEmphasisFromHz)
        else {
            throw CepstrumError.invalidConfiguration
        }
        let hop: Int?
        switch conditioningMethod {
        case .praat7WholeInterval(let depth):
            guard depth == 50 else { throw CepstrumError.invalidConfiguration }
            hop = nil
        case .streamingPreview:
            let exact = hopSeconds * Double(analysisSampleRate)
            let rounded = exact.rounded(.toNearestOrAwayFromZero)
            guard rounded >= 1, abs(exact - rounded) <= 8 * exact.ulp else {
                throw CepstrumError.invalidConfiguration
            }
            hop = Int(rounded)
        }
        self.schemaVersion = 1
        self.inputPrecision = inputPrecision
        self.frame = frame
        self.conditioning = try ConditioningConfiguration(
            sourceSampleRate: sourceSampleRate,
            targetSampleRate: analysisSampleRate, precision: .float64, method: conditioningMethod,
            preEmphasisFromHz: nil, declaredInputBandwidthHz: declaredInputBandwidthHz,
            requiredInputBandwidthHz: Double(analysisSampleRate) / 2)
        self.preEmphasisFromHz = preEmphasisFromHz == 0 ? 0 : preEmphasisFromHz
        self.hopSeconds = hopSeconds
        self.previewHopLength = hop
    }
    public func identity() throws -> ProfileIdentity {
        let name =
            previewHopLength == nil ? "praat-7.0.02-cepstrogram" : "finite-fir-preview-cepstrogram"
        return try ProfileIdentity(
            identifier: VersionedIdentifier(name: name, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, inputPrecision, frame, conditioning, preEmphasisFromHz, hopSeconds,
            previewHopLength
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        let f = try c.decode(PowerCepstrumConfiguration.self, forKey: .frame)
        let r = try c.decode(ConditioningConfiguration.self, forKey: .conditioning)
        guard c.contains(.previewHopLength) else { throw CepstrumError.invalidConfiguration }
        try self.init(
            sourceSampleRate: r.sourceSampleRate, analysisSampleRate: f.sampleRate,
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            pitchFloorHz: f.pitchFloorHz,
            hopSeconds: c.decode(Double.self, forKey: .hopSeconds),
            preEmphasisFromHz: c.decode(Double.self, forKey: .preEmphasisFromHz),
            declaredInputBandwidthHz: r.declaredInputBandwidthHz, conditioningMethod: r.method)
        guard r == conditioning, f == frame,
            try c.decodeIfPresent(Int.self, forKey: .previewHopLength) == previewHopLength
        else {
            throw CepstrumError.invalidConfiguration
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(inputPrecision, forKey: .inputPrecision)
        try c.encode(frame, forKey: .frame)
        try c.encode(conditioning, forKey: .conditioning)
        try c.encode(preEmphasisFromHz, forKey: .preEmphasisFromHz)
        try c.encode(hopSeconds, forKey: .hopSeconds)
        try c.encode(previewHopLength, forKey: .previewHopLength)
    }
}
