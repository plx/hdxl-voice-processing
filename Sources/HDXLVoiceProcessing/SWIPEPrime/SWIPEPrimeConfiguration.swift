import CryptoKit
import Foundation

public enum SWIPEPrimeError: Error, Sendable, Equatable {
    case invalidConfiguration, precisionMismatch, invalidBufferSize, invalidInput
    case unexpectedContext, invalidState, reentrantCall, numericalFailure
}

/// Original discrete SWIPE′ profile from Camacho and Harris (2008), not plain
/// SWIPE or a claim of parity with author software. Conventions and numerical
/// budgets were frozen in Tools/SWIPE/README.md before native implementation.
public struct SWIPEPrimeConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let definition: String
    public let sampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let arithmeticPrecision: AnalysisPrecision
    public let pitchFloorHz: Double
    public let pitchCeilingHz: Double
    public let hopLength: Int
    public let candidatesPerOctave: Int
    public let strengthThreshold: Double
    public let silenceRMSThreshold: Double
    public let partialWindowPolicy: PartialWindowPolicy
    public let candidateGrid: String
    public let gridEndpointRelativeTolerance: Double
    public let windowPolicy: String
    public let erbStep: Double
    public let erbMapping: String
    public let spectrumInterpolation: String
    public let kernel: String
    public let bandPolicy: String
    public let normalization: String
    public let refinement: String
    public let supportPolicy: String
    public let selection: String

    /// The lowest candidate requires the longest observed support. An exactly
    /// optimal power-of-two window does not require its zero-weight upper neighbor.
    public var requiredSampleCount: Int {
        let logarithm = log2(Double(sampleRate) / pitchFloorHz) + 3
        let lower = Int(floor(logarithm))
        return 1 << (logarithm == Double(lower) ? lower : lower + 1)
    }
    public var supportDurationSeconds: Double { Double(requiredSampleCount) / Double(sampleRate) }
    /// Earliest delivery after the actual support midpoint, independent of hop.
    public var algorithmicDelaySeconds: Double { supportDurationSeconds / 2 }

    public init(
        sampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        pitchFloorHz: Double = 50, pitchCeilingHz: Double = 700,
        hopLength: Int, candidatesPerOctave: Int = 96,
        strengthThreshold: Double = 0.2, silenceRMSThreshold: Double = 1e-7,
        partialWindowPolicy: PartialWindowPolicy = .emitUnavailable
    ) throws {
        guard (4000...192_000).contains(sampleRate),
            pitchFloorHz.isFinite, pitchCeilingHz.isFinite,
            pitchFloorHz >= 20, pitchFloorHz < pitchCeilingHz,
            pitchCeilingHz <= Double(sampleRate) / 4,
            (12...192).contains(candidatesPerOctave),
            strengthThreshold.isFinite, strengthThreshold > 0, strengthThreshold < 1,
            silenceRMSThreshold.isFinite, (0...1).contains(silenceRMSThreshold)
        else { throw SWIPEPrimeError.invalidConfiguration }
        let grid = Self.makeCandidateGrid(
            floor: pitchFloorHz, ceiling: pitchCeilingHz, resolution: candidatesPerOctave)
        let logarithm = log2(Double(sampleRate) / pitchFloorHz) + 3
        let support = 1 << Int(ceil(logarithm))
        guard (3...2304).contains(grid.count), support <= 131_072,
            (1...support).contains(hopLength)
        else { throw SWIPEPrimeError.invalidConfiguration }
        self.schemaVersion = 1
        self.definition = "hdxl-swipe-prime-centered-2008"
        self.sampleRate = sampleRate
        self.inputPrecision = inputPrecision
        self.arithmeticPrecision = .float64
        self.pitchFloorHz = pitchFloorHz
        self.pitchCeilingHz = pitchCeilingHz
        self.hopLength = hopLength
        self.candidatesPerOctave = candidatesPerOctave
        self.strengthThreshold = strengthThreshold
        self.silenceRMSThreshold = silenceRMSThreshold == 0 ? 0 : silenceRMSThreshold
        self.partialWindowPolicy = partialWindowPolicy
        self.candidateGrid = "logarithmicWithExactEndpoints"
        self.gridEndpointRelativeTolerance = 1e-12
        self.windowPolicy = "centeredPeriodicHannEightPeriodsLogBlend"
        self.erbStep = 0.1
        self.erbMapping = "glasbergMoore229Hz21Point4"
        self.spectrumInterpolation = "linearMagnitudeThenSquareRoot"
        self.kernel = "firstAndPrimeHarmonicsPositivePartNorm"
        self.bandPolicy = "wholeERBGridThroughNyquistIncludingPartialLobes"
        self.normalization = "observedPeakAndWholeBandLoudnessL2"
        self.refinement = "concavePeriodVertexWithinNeighbors"
        self.supportPolicy = "longestRequiredObservedWindow"
        self.selection = "maximumStrengthLowestFrequencyTie"
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: definition, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    public func framingConfiguration() throws -> FramingConfiguration {
        try FramingConfiguration(
            window: WindowSpecification(
                definition: .rectangular, sampleCount: requiredSampleCount,
                sampleRate: Double(sampleRate), precision: inputPrecision),
            hopLength: hopLength, partialWindowPolicy: partialWindowPolicy)
    }

    /// Allocating preparation helper, not a frame-processing operation.
    package func candidateFrequencies() -> [Double] {
        Self.makeCandidateGrid(
            floor: pitchFloorHz, ceiling: pitchCeilingHz, resolution: candidatesPerOctave)
    }
    private static func makeCandidateGrid(floor: Double, ceiling: Double, resolution: Int)
        -> [Double]
    {
        let count = Int(ceil(log2(ceiling / floor) * Double(resolution)))
        var result: [Double] = []
        result.reserveCapacity(count + 1)
        for index in 0..<count {
            let frequency = floor * pow(2, Double(index) / Double(resolution))
            if ceiling - frequency > 1e-12 * ceiling { result.append(frequency) }
        }
        result.append(ceiling)
        return result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, definition, sampleRate, inputPrecision, arithmeticPrecision
        case pitchFloorHz, pitchCeilingHz, hopLength, candidatesPerOctave, strengthThreshold
        case silenceRMSThreshold, partialWindowPolicy, candidateGrid, gridEndpointRelativeTolerance
        case windowPolicy, erbStep, erbMapping, spectrumInterpolation, kernel, bandPolicy
        case normalization, refinement, supportPolicy, selection
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            pitchFloorHz: c.decode(Double.self, forKey: .pitchFloorHz),
            pitchCeilingHz: c.decode(Double.self, forKey: .pitchCeilingHz),
            hopLength: c.decode(Int.self, forKey: .hopLength),
            candidatesPerOctave: c.decode(Int.self, forKey: .candidatesPerOctave),
            strengthThreshold: c.decode(Double.self, forKey: .strengthThreshold),
            silenceRMSThreshold: c.decode(Double.self, forKey: .silenceRMSThreshold),
            partialWindowPolicy: c.decode(PartialWindowPolicy.self, forKey: .partialWindowPolicy))
        guard try c.decode(String.self, forKey: .definition) == definition,
            try c.decode(AnalysisPrecision.self, forKey: .arithmeticPrecision)
                == arithmeticPrecision,
            try c.decode(String.self, forKey: .candidateGrid) == candidateGrid,
            try c.decode(Double.self, forKey: .gridEndpointRelativeTolerance)
                == gridEndpointRelativeTolerance,
            try c.decode(String.self, forKey: .windowPolicy) == windowPolicy,
            try c.decode(Double.self, forKey: .erbStep) == erbStep,
            try c.decode(String.self, forKey: .erbMapping) == erbMapping,
            try c.decode(String.self, forKey: .spectrumInterpolation) == spectrumInterpolation,
            try c.decode(String.self, forKey: .kernel) == kernel,
            try c.decode(String.self, forKey: .bandPolicy) == bandPolicy,
            try c.decode(String.self, forKey: .normalization) == normalization,
            try c.decode(String.self, forKey: .refinement) == refinement,
            try c.decode(String.self, forKey: .supportPolicy) == supportPolicy,
            try c.decode(String.self, forKey: .selection) == selection
        else { throw SWIPEPrimeError.invalidConfiguration }
    }
}

/// Candidate-specific mixture. A zero upperWeight means upperLength is a
/// geometric neighbor only; it is absent from the required window collection.
public struct SWIPEPrimeWindowMixture: Sendable, Hashable {
    public let lowerLength: Int
    public let upperLength: Int
    public let upperWeight: Double
}

/// Immutable, allocating preparation geometry. Every spectral window is centered
/// within requiredSampleCount; auditory frequencies never extend above Nyquist.
public struct SWIPEPrimeLayout: Sendable, Hashable {
    public let candidateFrequenciesHz: [Double]
    public let windowLengths: [Int]
    public let requiredSampleCount: Int
    public let erbFrequenciesHz: [Double]
    public let candidateWindows: [SWIPEPrimeWindowMixture]

    public init(configuration: SWIPEPrimeConfiguration) {
        let frequencies = configuration.candidateFrequencies()
        let rate = Double(configuration.sampleRate)
        let mixtures = frequencies.map { frequency in
            let logarithm = log2(rate / frequency) + 3
            let exponent = Int(floor(logarithm))
            return SWIPEPrimeWindowMixture(
                lowerLength: 1 << exponent, upperLength: 1 << (exponent + 1),
                upperWeight: logarithm - Double(exponent))
        }
        var lengths: Set<Int> = []
        for mixture in mixtures {
            lengths.insert(mixture.lowerLength)
            if mixture.upperWeight > 0 { lengths.insert(mixture.upperLength) }
        }
        let maximumERB = 21.4 * log1p((rate / 2) / 229) / log(10)
        let lastERBIndex = Int(floor(maximumERB / configuration.erbStep))
        self.candidateFrequenciesHz = frequencies
        self.candidateWindows = mixtures
        self.windowLengths = lengths.sorted()
        self.requiredSampleCount = configuration.requiredSampleCount
        self.erbFrequenciesHz = (0...lastERBIndex).map { index in
            229 * expm1(Double(index) * configuration.erbStep * log(10) / 21.4)
        }
    }
}
