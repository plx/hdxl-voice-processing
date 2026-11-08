import CryptoKit
import Foundation

public enum HNRError: Error, Sendable, Equatable {
    case invalidConfiguration, precisionMismatch, invalidBufferSize, invalidInput
    case unexpectedContext, insufficientData, capacityExceeded, invalidState, reentrantCall
    case numericalFailure
}

public enum HNRMethod: String, Sendable, Hashable, Codable, CaseIterable {
    case autocorrelation = "ac"
    case forwardCrossCorrelation = "cc"
}

/// An algorithmic amplitude reference, not a noise-floor or health calibration.
public enum HNRNormalizationDefinition: String, Sendable, Hashable, Codable {
    /// Depends on the complete declared contiguous input, including future samples.
    case wholeInterval = "wholeIntervalMeanRemovedPeak"
    /// Uses only the current finite acquired window. A separate causal profile.
    case causalWindow = "causalWindowMeanRemovedPeak"
}

/// Accurate Gaussian AC and rectangular forward CC share an internal period
/// search, but retain separate identities. No external pitch estimate is needed.
/// All input/support, interpolation and numerical-resolution conventions are
/// recorded in Tools/HNR/README.md and participate in the profile fingerprint.
public struct HNRConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let method: HNRMethod
    public let sampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let arithmeticPrecision: AnalysisPrecision
    public let pitchFloorHz: Double
    public let periodsPerWindow: Double
    public let hopSeconds: Double
    public let silenceThreshold: Double
    public let normalization: HNRNormalizationDefinition
    public let window: String
    public let interpolation: String
    public let overshoot: String
    public let peakResolution: String
    public let minimumPeakCurvature: Double
    public let reportingPeriodicityLimit: Double
    public let reportingDecibelLimit: Double
    public let frameGrid: String
    public let arithmeticScaling: String

    public var effectivePeriods: Double {
        periodsPerWindow * (method == .autocorrelation ? 2 : 1)
    }
    public var windowDurationSeconds: Double { effectivePeriods / pitchFloorHz }
    public var nominalSupportSeconds: Double {
        windowDurationSeconds + (method == .forwardCrossCorrelation ? 1 / pitchFloorHz : 0)
    }
    public var windowSampleCount: Int {
        2 * (Int(floor(windowDurationSeconds / (1 / Double(sampleRate)))) / 2 - 1)
    }
    public var localMeanSampleCount: Int {
        2 * Int(floor(1 / (1 / Double(sampleRate)) / pitchFloorHz))
    }
    public var maximumCandidateLag: Int {
        min(Int(floor(Double(windowSampleCount) / effectivePeriods)) + 2, windowSampleCount)
    }
    public var maximumCorrelationLag: Int {
        method == .autocorrelation ? windowSampleCount / 4 : windowSampleCount
    }
    public var retainedCandidateCapacity: Int {
        max(15, Int(floor((Double(sampleRate) / 2) / pitchFloorHz))) - 1
    }
    /// Complete finite causal normalization window, including all mean/lag support.
    public var causalWindowSampleCount: Int {
        Int(ceil(nominalSupportSeconds * Double(sampleRate)))
    }
    /// A finite allocation bound; long recordings use explicitly declared intervals.
    public static let maximumIntervalSampleCount = 16_777_216
    public static let maximumFrameCount = 1_048_576

    public init(
        method: HNRMethod, sampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        pitchFloorHz: Double = 75, periodsPerWindow: Double = 4.5,
        hopSeconds: Double = 0.01, silenceThreshold: Double = 0.1,
        normalization: HNRNormalizationDefinition = .wholeInterval
    ) throws {
        guard (4000...192_000).contains(sampleRate),
            pitchFloorHz.isFinite, (20...Double(sampleRate) / 8).contains(pitchFloorHz),
            periodsPerWindow.isFinite, (2...10).contains(periodsPerWindow),
            hopSeconds.isFinite, (1 / Double(sampleRate)...1).contains(hopSeconds),
            silenceThreshold.isFinite, (0...1).contains(silenceThreshold)
        else { throw HNRError.invalidConfiguration }
        let width = periodsPerWindow * (method == .autocorrelation ? 2 : 1) / pitchFloorHz
        let count = 2 * (Int(floor(width / (1 / Double(sampleRate)))) / 2 - 1)
        guard (8...65_536).contains(count) else { throw HNRError.capacityExceeded }
        self.schemaVersion = 1
        self.method = method
        self.sampleRate = sampleRate
        self.inputPrecision = inputPrecision
        self.arithmeticPrecision = .float64
        self.pitchFloorHz = pitchFloorHz
        self.periodsPerWindow = periodsPerWindow
        self.hopSeconds = hopSeconds
        self.silenceThreshold = silenceThreshold == 0 ? 0 : silenceThreshold
        self.normalization = normalization
        self.window =
            method == .autocorrelation ? "pitchGaussianNPlusOne" : "rectangularForwardPair"
        self.interpolation = "sinc700SymmetricRaisedCosineDepthPlusHalf"
        self.overshoot = "reciprocalAboveOne"
        self.peakResolution = "positiveLocalMaximumCurvature128Binary64Ulps-v1"
        self.minimumPeakCurvature = 128 * Double.ulpOfOne
        self.reportingPeriodicityLimit = 1e-15
        self.reportingDecibelLimit = 150
        self.frameGrid =
            normalization == .wholeInterval
            ? "centeredWholeIntervalBinary64FusedStep"
            : "causalAcquiredWindowCenterBinary64FractionalHopAccumulator"
        self.arithmeticScaling = "framePeakScaledBinary64WithSeparateSilenceReference"
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(
                name: "hdxl-hnr-" + method.rawValue + "-" + normalization.rawValue, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    /// The entire acquired window participates in this causal amplitude reference.
    /// This layout makes no claim about a recording's future peak or end position.
    public func causalFrameLayout(frameIndex: Int) throws -> HNRFrameLayout {
        guard normalization == .causalWindow else { throw HNRError.invalidConfiguration }
        let count = causalWindowSampleCount
        return try HNRFrameLayout(
            configuration: self, count: count, index: frameIndex,
            center: (1 / Double(sampleRate)) * Double(count) / 2)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, method, sampleRate, inputPrecision, arithmeticPrecision
        case pitchFloorHz, periodsPerWindow, hopSeconds, silenceThreshold, normalization
        case window, interpolation, overshoot, peakResolution, minimumPeakCurvature
        case reportingPeriodicityLimit, reportingDecibelLimit, frameGrid, arithmeticScaling
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            method: c.decode(HNRMethod.self, forKey: .method),
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            pitchFloorHz: c.decode(Double.self, forKey: .pitchFloorHz),
            periodsPerWindow: c.decode(Double.self, forKey: .periodsPerWindow),
            hopSeconds: c.decode(Double.self, forKey: .hopSeconds),
            silenceThreshold: c.decode(Double.self, forKey: .silenceThreshold),
            normalization: c.decode(HNRNormalizationDefinition.self, forKey: .normalization))
        guard
            try c.decode(AnalysisPrecision.self, forKey: .arithmeticPrecision)
                == arithmeticPrecision,
            try c.decode(String.self, forKey: .window) == window,
            try c.decode(String.self, forKey: .interpolation) == interpolation,
            try c.decode(String.self, forKey: .overshoot) == overshoot,
            try c.decode(String.self, forKey: .peakResolution) == peakResolution,
            try c.decode(Double.self, forKey: .minimumPeakCurvature) == minimumPeakCurvature,
            try c.decode(Double.self, forKey: .reportingPeriodicityLimit)
                == reportingPeriodicityLimit,
            try c.decode(Double.self, forKey: .reportingDecibelLimit) == reportingDecibelLimit,
            try c.decode(String.self, forKey: .frameGrid) == frameGrid,
            try c.decode(String.self, forKey: .arithmeticScaling) == arithmeticScaling
        else { throw HNRError.invalidConfiguration }
    }
}

/// Exact acquired support of one frame. Offsets are relative to its declared
/// contiguous input origin; none of the ranges includes fabricated edge samples.
public struct HNRFrameLayout: Sendable, Hashable {
    public let configuration: HNRConfiguration
    public let intervalSampleCount: Int
    public let frameIndex: Int
    public let centerSecondsFromOrigin: Double
    public let centeredWindowStartSample: Int
    public let localMeanStartSample: Int
    public let correlationStartSample: Int
    public let computedMaximumLag: Int
    public let support: Range<Int>

    package init(configuration c: HNRConfiguration, count: Int, index: Int, center: Double) throws {
        guard count >= 0, count <= HNRConfiguration.maximumIntervalSampleCount,
            index >= 0, center.isFinite, center >= 0,
            center <= Double(count) / Double(c.sampleRate)
        else { throw HNRError.unexpectedContext }
        let dx = 1 / Double(c.sampleRate)
        let split = Int(floor(1 + (center - 0.5 * dx) / dx))
        let n = c.windowSampleCount
        let start = split - n / 2
        let meanStart = split - c.localMeanSampleCount / 2
        let correlationStart: Int
        let computed: Int
        if c.method == .autocorrelation {
            correlationStart = start
            computed = c.maximumCorrelationLag
        } else {
            let firstTime =
                center - 0.5 * (1 / c.pitchFloorHz + c.periodsPerWindow / c.pitchFloorHz)
            correlationStart = max(0, Int(floor(1 + (firstTime - 0.5 * dx) / dx)) - 1)
            computed = min(c.maximumCandidateLag, count - correlationStart - n)
        }
        let lower = min(start, meanStart, correlationStart)
        let upper = max(
            start + n, meanStart + c.localMeanSampleCount,
            correlationStart + n + (c.method == .forwardCrossCorrelation ? computed : 0))
        guard computed >= 0, lower >= 0, upper <= count, lower < upper else {
            throw HNRError.insufficientData
        }
        configuration = c
        intervalSampleCount = count
        frameIndex = index
        centerSecondsFromOrigin = center
        centeredWindowStartSample = start
        localMeanStartSample = meanStart
        correlationStartSample = correlationStart
        computedMaximumLag = computed
        support = lower..<upper
    }
}

/// The pinned complete-support whole-interval grid. A positive short input has
/// zero complete frames; the interval analyzer reports its insufficient support.
public struct HNRIntervalLayout: Sendable, Hashable {
    public let configuration: HNRConfiguration
    public let sampleCount: Int
    public let frameCount: Int
    public let firstCenterSeconds: Double?

    public init(configuration: HNRConfiguration, sampleCount: Int) throws {
        guard configuration.normalization == .wholeInterval else {
            throw HNRError.invalidConfiguration
        }
        guard (0...HNRConfiguration.maximumIntervalSampleCount).contains(sampleCount) else {
            throw HNRError.capacityExceeded
        }
        let duration = (1 / Double(configuration.sampleRate)) * Double(sampleCount)
        let count =
            duration < configuration.nominalSupportSeconds
            ? 0
            : Int(
                floor((duration - configuration.nominalSupportSeconds) / configuration.hopSeconds))
                + 1
        guard count <= HNRConfiguration.maximumFrameCount else { throw HNRError.capacityExceeded }
        self.configuration = configuration
        self.sampleCount = sampleCount
        self.frameCount = count
        self.firstCenterSeconds =
            count == 0
            ? nil
            : duration / 2 - 0.5 * (Double(count) * configuration.hopSeconds) + 0.5
                * configuration.hopSeconds
    }

    public func frame(at index: Int) throws -> HNRFrameLayout {
        guard (0..<frameCount).contains(index), let firstCenterSeconds else {
            throw HNRError.invalidBufferSize
        }
        return try HNRFrameLayout(
            configuration: configuration, count: sampleCount, index: index,
            center: firstCenterSeconds.addingProduct(Double(index), configuration.hopSeconds))
    }
}
