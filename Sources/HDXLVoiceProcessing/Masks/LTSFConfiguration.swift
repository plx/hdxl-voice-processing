import CryptoKit
import Foundation

/// Pinned fixed-threshold temporal-flatness profile. This is distinct from the
/// adaptive/voting detector in Ma/Nishihara 2013 and from ordinary spectral flatness
/// across frequency bins of a single frame. All arithmetic uses Double.
public struct LTSFConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let declaredInputBandwidthHz: Double
    public let hopSeconds: Double
    public let shortWindowSeconds: Double
    public let longWindowSeconds: Double
    public let minimumFrequencyHz: Double
    public let maximumFrequencyHz: Double
    public let flatnessThreshold: Double
    /// Nil disables the optional input-relative intensity gate. Otherwise the
    /// threshold is relative to the interpolated maximum over the entire input.
    public let relativeIntensityThresholdDB: Double?
    public let minimumSpeechSeconds: Double
    public let minimumNonSpeechSeconds: Double

    public init(
        sampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        declaredInputBandwidthHz: Double, hopSeconds: Double = 0.01,
        shortWindowSeconds: Double = 0.1, longWindowSeconds: Double = 0.3,
        minimumFrequencyHz: Double = 70, maximumFrequencyHz: Double = 6000,
        flatnessThreshold: Double = -10, relativeIntensityThresholdDB: Double? = -35,
        minimumSpeechSeconds: Double = 0.1, minimumNonSpeechSeconds: Double = 0.1
    ) throws {
        guard (8_000...96_000).contains(sampleRate),
            declaredInputBandwidthHz.isFinite,
            (1...Double(sampleRate) / 2).contains(declaredInputBandwidthHz),
            hopSeconds.isFinite, (0.002...0.05).contains(hopSeconds),
            shortWindowSeconds.isFinite, (0.001...2).contains(shortWindowSeconds),
            longWindowSeconds.isFinite, (hopSeconds...5).contains(longWindowSeconds),
            minimumFrequencyHz.isFinite, minimumFrequencyHz > 0,
            maximumFrequencyHz.isFinite, maximumFrequencyHz > minimumFrequencyHz,
            maximumFrequencyHz <= 48_000,
            min(maximumFrequencyHz, Double(sampleRate) / 2) <= declaredInputBandwidthHz,
            flatnessThreshold.isFinite, (-100_000...100_000).contains(flatnessThreshold),
            minimumSpeechSeconds.isFinite, (0.001...10).contains(minimumSpeechSeconds),
            minimumNonSpeechSeconds.isFinite, (0.001...10).contains(minimumNonSpeechSeconds)
        else { throw MaskError.invalidConfiguration }
        if let relativeIntensityThresholdDB {
            guard relativeIntensityThresholdDB.isFinite, relativeIntensityThresholdDB > -50,
                relativeIntensityThresholdDB < 0
            else { throw MaskError.invalidConfiguration }
        }
        schemaVersion = 1
        self.sampleRate = sampleRate
        self.inputPrecision = inputPrecision
        self.declaredInputBandwidthHz = declaredInputBandwidthHz
        self.hopSeconds = hopSeconds
        self.shortWindowSeconds = shortWindowSeconds
        self.longWindowSeconds = longWindowSeconds
        self.minimumFrequencyHz = minimumFrequencyHz
        self.maximumFrequencyHz = maximumFrequencyHz
        self.flatnessThreshold = flatnessThreshold == 0 ? 0 : flatnessThreshold
        self.relativeIntensityThresholdDB = relativeIntensityThresholdDB
        self.minimumSpeechSeconds = minimumSpeechSeconds
        self.minimumNonSpeechSeconds = minimumNonSpeechSeconds
        // Frequency-row and resource validation applies even before a source is attached.
        _ = try LTSFSpectralGeometry(configuration: self)
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: "praat-7.0.02-ltsf-supported-domain", version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    public func provenance() throws -> MaskProvenance {
        let identity = try identity()
        let geometry = try LTSFSpectralGeometry(configuration: self)
        return try MaskProvenance(
            kind: .spectralFlatnessSpeechActivity, identifier: identity.identifier,
            parameters: [
                "configurationSHA256": .text(identity.sha256),
                "sampleRateHz": .integer(Int64(sampleRate)),
                "inputPrecision": .text(inputPrecision.rawValue),
                "analysisPrecision": .text("float64"),
                "declaredInputBandwidthHz": .real(declaredInputBandwidthHz),
                "hopSeconds": .real(hopSeconds), "shortWindowSeconds": .real(shortWindowSeconds),
                "longWindowSeconds": .real(longWindowSeconds),
                "minimumFrequencyHz": .real(minimumFrequencyHz),
                "maximumFrequencyHz": .real(maximumFrequencyHz),
                "flatnessThreshold": .real(flatnessThreshold),
                "relativeIntensityEnabled": .boolean(relativeIntensityThresholdDB != nil),
                "relativeIntensityThresholdDB": .real(relativeIntensityThresholdDB ?? -50),
                "minimumSpeechSeconds": .real(minimumSpeechSeconds),
                "minimumNonSpeechSeconds": .real(minimumNonSpeechSeconds),
                "hysteresis": .text("none-fixed-threshold"),
                "shortAverage": .text("centered-piecewise-linear-constant-half-cell-caps"),
                "cleanup": .text("short-speech-then-short-nonspeech"),
                "speechComparison": .text("flatness-strictly-less-than-threshold"),
                "finalization": .text("complete-declared-source-interval"),
                "boundaryQuantization": .text("nearest-source-sample-boundary-ties-away-from-zero"),
                "physicalWindowSeconds": .real(geometry.physicalWindowSeconds),
                "observedFrameSamples": .integer(Int64(geometry.frameLength)),
                "fftLength": .integer(Int64(geometry.fftLength)),
                "spectrogramBinStepHz": .real(geometry.frequencyStepHz),
                "effectiveMinimumFrequencyHz": .real(geometry.effectiveMinimumFrequencyHz),
                "effectiveMaximumFrequencyHz": .real(geometry.effectiveMaximumFrequencyHz),
                "spectrogramWindow": .text("hann-one-based-phase-over-physical-width"),
                "relativeIntensityPowerReference": .real(4e-10),
                "intensityCombinationEndMarginSeconds": .real(0.02),
            ])
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sampleRate, inputPrecision, declaredInputBandwidthHz, hopSeconds
        case shortWindowSeconds, longWindowSeconds, minimumFrequencyHz, maximumFrequencyHz
        case flatnessThreshold, relativeIntensityThresholdDB, minimumSpeechSeconds,
            minimumNonSpeechSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        guard c.contains(.relativeIntensityThresholdDB) else {
            throw MaskError.invalidConfiguration
        }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            declaredInputBandwidthHz: c.decode(Double.self, forKey: .declaredInputBandwidthHz),
            hopSeconds: c.decode(Double.self, forKey: .hopSeconds),
            shortWindowSeconds: c.decode(Double.self, forKey: .shortWindowSeconds),
            longWindowSeconds: c.decode(Double.self, forKey: .longWindowSeconds),
            minimumFrequencyHz: c.decode(Double.self, forKey: .minimumFrequencyHz),
            maximumFrequencyHz: c.decode(Double.self, forKey: .maximumFrequencyHz),
            flatnessThreshold: c.decode(Double.self, forKey: .flatnessThreshold),
            relativeIntensityThresholdDB: c.decodeIfPresent(
                Double.self, forKey: .relativeIntensityThresholdDB),
            minimumSpeechSeconds: c.decode(Double.self, forKey: .minimumSpeechSeconds),
            minimumNonSpeechSeconds: c.decode(Double.self, forKey: .minimumNonSpeechSeconds))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(inputPrecision, forKey: .inputPrecision)
        try c.encode(declaredInputBandwidthHz, forKey: .declaredInputBandwidthHz)
        try c.encode(hopSeconds, forKey: .hopSeconds)
        try c.encode(shortWindowSeconds, forKey: .shortWindowSeconds)
        try c.encode(longWindowSeconds, forKey: .longWindowSeconds)
        try c.encode(minimumFrequencyHz, forKey: .minimumFrequencyHz)
        try c.encode(maximumFrequencyHz, forKey: .maximumFrequencyHz)
        try c.encode(flatnessThreshold, forKey: .flatnessThreshold)
        try c.encode(relativeIntensityThresholdDB, forKey: .relativeIntensityThresholdDB)
        try c.encode(minimumSpeechSeconds, forKey: .minimumSpeechSeconds)
        try c.encode(minimumNonSpeechSeconds, forKey: .minimumNonSpeechSeconds)
    }
}

/// Actual FFT grouping and temporal support. Requested frequency thresholds are
/// not bin centers; expose both to avoid claiming a different effective bandwidth.
public struct LTSFSpectralGeometry: Sendable, Hashable, Encodable {
    public let physicalWindowSeconds: Double
    public let frameLength: Int
    public let fftLength: Int
    public let fftBinsPerSpectrogramBin: Int
    public let frequencyBinCount: Int
    public let firstFrequencyHz: Double
    public let frequencyStepHz: Double
    public let firstFlatnessBin: Int
    public let lastFlatnessBin: Int
    public let effectiveMinimumFrequencyHz: Double
    public let effectiveMaximumFrequencyHz: Double
    public let shortAveragingEnabled: Bool
    public let longFrameCount: Int
    public let spectralRingFrameCount: Int

    public init(configuration c: LTSFConfiguration) throws {
        let dt = 1 / Double(c.sampleRate)
        let width = max(0.02, 2 * c.hopSeconds)
        let frameLength = 2 * (Int(floor(width / dt)) / 2 - 1)
        let high = min(c.maximumFrequencyHz, 0.5 / dt)
        let approximateBins = floor(high / 20)
        guard approximateBins >= 1 else { throw MaskError.invalidConfiguration }
        var fftLength = 1
        while fftLength < frameLength || Double(fftLength) < 2 * approximateBins * (0.5 / dt / high)
        {
            fftLength *= 2
        }
        let grouping = max(1, Int(floor(20 * dt * Double(fftLength))))
        let fftStep = 1 / (dt * Double(fftLength))
        let step = Double(grouping) * fftStep
        let count = Int(floor(high / step))
        let first = max(1, Int(floor(c.minimumFrequencyHz / step))) - 1
        let last = min(count, Int(floor(high / step))) - 1
        // Row 1 is scratch in the pinned implementation. Its in-place mutation is
        // deliberately outside this immutable-input profile (decision #109).
        guard first >= 1, first < last else { throw MaskError.invalidConfiguration }
        let shortEnabled = floor(c.shortWindowSeconds / c.hopSeconds) > 1
        let lookahead = max(
            shortEnabled ? c.shortWindowSeconds / 2 : 0,
            c.relativeIntensityThresholdDB == nil ? 0 : 0.032)
        let ring = 2 * Int(ceil(lookahead / c.hopSeconds)) + 3
        let longCount = Int(floor(c.longWindowSeconds / c.hopSeconds + 0.5))
        guard (ring + longCount) * count <= 8_388_608 else { throw MaskError.capacityExceeded }
        physicalWindowSeconds = width
        self.frameLength = frameLength
        self.fftLength = fftLength
        fftBinsPerSpectrogramBin = grouping
        frequencyBinCount = count
        firstFrequencyHz = 0.5 * (step - fftStep)
        frequencyStepHz = step
        firstFlatnessBin = first
        lastFlatnessBin = last
        effectiveMinimumFrequencyHz = firstFrequencyHz + Double(first) * step
        effectiveMaximumFrequencyHz = firstFrequencyHz + Double(last) * step
        shortAveragingEnabled = shortEnabled
        longFrameCount = longCount
        spectralRingFrameCount = ring
    }
}

/// A declared complete source fixes the centered grid before the first chunk.
/// Final labels still require finish, including interval cleanup and global energy.
public struct LTSFIntervalLayout: Sendable, Hashable, Encodable {
    public let configuration: LTSFConfiguration
    public let source: SourceInterval
    public let spectral: LTSFSpectralGeometry
    public let frameCount: Int
    public let firstCenterSeconds: Double?
    public let unavailability: UnavailabilityReason?
    /// Conservative source-relative finalization delay, not wall-clock runtime.
    public let maximumEffectiveDelaySeconds: Double
    public static let maximumDurationSeconds = 600.0

    public init(configuration: LTSFConfiguration, source: SourceInterval) throws {
        guard source.sampleRate == Double(configuration.sampleRate),
            source.durationSeconds <= Self.maximumDurationSeconds
        else { throw MaskError.unexpectedInterval }
        let spectral = try LTSFSpectralGeometry(configuration: configuration)
        let dt = 1 / source.sampleRate
        let duration = Double(source.sampleCount) * dt
        let count =
            duration < spectral.physicalWindowSeconds
            ? 0
            : 1 + Int(floor((duration - spectral.physicalWindowSeconds) / configuration.hopSeconds))
        self.configuration = configuration
        self.source = source
        maximumEffectiveDelaySeconds = source.durationSeconds
        self.spectral = spectral
        frameCount = count
        if count == 0 {
            firstCenterSeconds = nil
        } else {
            // The pinned executable contracts the source-sample product with
            // subtraction, then contracts the final half-width addition. A few
            // ulps here can choose a different sample at a half-sample boundary.
            let remainder = (-Double(count - 1) * configuration.hopSeconds)
                .addingProduct(Double(source.sampleCount - 1), dt)
            firstCenterSeconds = (0.5 * dt).addingProduct(0.5, remainder)
        }
        unavailability =
            count == 0
                || duration
                    < max(configuration.minimumSpeechSeconds, configuration.minimumNonSpeechSeconds)
            ? .insufficientData : nil
    }

    /// Relative to source.startSample, never the host clock or a concatenated origin.
    public func centerSeconds(frameIndex: Int) throws -> Double {
        guard (0..<frameCount).contains(frameIndex), let firstCenterSeconds else {
            throw MaskError.unexpectedInterval
        }
        return firstCenterSeconds.addingProduct(Double(frameIndex), configuration.hopSeconds)
    }

    public func firstSampleOffset(frameIndex: Int) throws -> Int {
        let dt = 1 / source.sampleRate
        let center = try centerSeconds(frameIndex: frameIndex)
        let leftOneBased = Int(floor((center - 0.5 * dt) / dt + 1))
        return leftOneBased - spectral.frameLength / 2
    }

    public func sourceBoundary(relativeSeconds: Double) throws -> Int64 {
        guard relativeSeconds.isFinite, relativeSeconds >= 0,
            relativeSeconds <= source.durationSeconds
        else { throw MaskError.unexpectedInterval }
        let offset = min(
            source.sampleCount,
            max(0, Int64((relativeSeconds * source.sampleRate).rounded(.toNearestOrAwayFromZero))))
        return source.startSample + offset
    }
}
