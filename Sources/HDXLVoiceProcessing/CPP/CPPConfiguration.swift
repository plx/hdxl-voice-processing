import CryptoKit
import Foundation

public enum CPPError: Error, Sendable, Equatable {
    case invalidConfiguration, capacityExceeded, profileMismatch, invalidBufferSize
    case invalidInput, unexpectedContext, reentrantCall
}

/// Actual estimators, not ambiguous user-interface labels. All native methods are
/// deterministic; complete Theil-Sen uses every pair, without random subsampling.
public enum CPPFitMethod: String, Sendable, Hashable, Codable, CaseIterable {
    case leastSquares
    /// Pinned Praat 7.0.02 "Robust": median of the FIRST n-1 pointwise
    /// slope medians, then median intercept over ALL n points. This historical
    /// implementation detail is distinct from the complete Siegel estimator.
    case praat7002Robust
    case siegelRepeatedMedian, completeTheilSen
}

public enum CPPPeakInterpolation: String, Sendable, Hashable, Codable, CaseIterable {
    case none, parabolic
}

/// Straight background in dB versus quefrency seconds. The peak is selected in
/// the original dB cepstrum, then the fitted background is evaluated at that peak.
/// No smoothing, F0-success gate, health threshold, or trend subtraction is applied.
public struct CPPConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let pitchFloorHz: Double
    public let pitchCeilingHz: Double
    public let interpolation: CPPPeakInterpolation
    public let fitStartSeconds: Double
    /// Zero requests Praat's autowindow: the FULL domain, followed by q=0 exclusion.
    /// It does not preserve fitStartSeconds as the effective lower fit bound.
    public let fitEndSeconds: Double
    public let fitMethod: CPPFitMethod
    public static let additivePowerFloor = 1e-30
    public static let maximumRobustFitPoints = 2048

    public init(
        pitchFloorHz: Double = 60, pitchCeilingHz: Double = 333.3,
        interpolation: CPPPeakInterpolation = .parabolic,
        fitStartSeconds: Double = 0.001, fitEndSeconds: Double = 0.05,
        fitMethod: CPPFitMethod = .completeTheilSen
    ) throws {
        guard pitchFloorHz.isFinite, pitchCeilingHz.isFinite,
            (1...20_000).contains(pitchFloorHz), pitchCeilingHz > pitchFloorHz,
            pitchCeilingHz <= 20_000,
            fitStartSeconds.isFinite, (0...1).contains(fitStartSeconds),
            fitEndSeconds.isFinite, (0...1).contains(fitEndSeconds),
            fitEndSeconds == 0 || fitEndSeconds > fitStartSeconds
        else { throw CPPError.invalidConfiguration }
        schemaVersion = 1
        self.pitchFloorHz = pitchFloorHz
        self.pitchCeilingHz = pitchCeilingHz
        self.interpolation = interpolation
        self.fitStartSeconds = fitStartSeconds == 0 ? 0 : fitStartSeconds
        self.fitEndSeconds = fitEndSeconds == 0 ? 0 : fitEndSeconds
        self.fitMethod = fitMethod
    }

    /// Unsmoothed per-frame consumer settings from the published recipe, executed
    /// with modern Praat 7 semantics. This alone is neither CPPS nor Praat 6 parity.
    public static func murtonRecipePraat7() throws -> Self {
        try Self(pitchCeilingHz: 330, fitEndSeconds: 0, fitMethod: .praat7002Robust)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, pitchFloorHz, pitchCeilingHz, interpolation
        case fitStartSeconds, fitEndSeconds, fitMethod
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            pitchFloorHz: c.decode(Double.self, forKey: .pitchFloorHz),
            pitchCeilingHz: c.decode(Double.self, forKey: .pitchCeilingHz),
            interpolation: c.decode(CPPPeakInterpolation.self, forKey: .interpolation),
            fitStartSeconds: c.decode(Double.self, forKey: .fitStartSeconds),
            fitEndSeconds: c.decode(Double.self, forKey: .fitEndSeconds),
            fitMethod: c.decode(CPPFitMethod.self, forKey: .fitMethod))
    }
}

/// Full input recipe plus CPP settings. A prepared consumer checks the upstream
/// identity, preventing a preview frame from being labelled as whole-interval CPP.
public struct CPPProfile: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let frame: PowerCepstrumConfiguration
    public let cepstrogram: CepstrogramConfiguration?
    public let settings: CPPConfiguration

    public init(frame: PowerCepstrumConfiguration, settings: CPPConfiguration) {
        schemaVersion = 1
        self.frame = frame
        self.cepstrogram = nil
        self.settings = settings
    }
    public init(cepstrogram: CepstrogramConfiguration, settings: CPPConfiguration) {
        schemaVersion = 1
        self.frame = cepstrogram.frame
        self.cepstrogram = cepstrogram
        self.settings = settings
    }
    public func sourceIdentity() throws -> ProfileIdentity {
        if let cepstrogram { return try cepstrogram.identity() }
        return try frame.identity()
    }
    public func identity() throws -> ProfileIdentity {
        // The exact mathematical estimator intentionally does not reproduce known
        // Praat 7 randomized-selector defects on tied data (decision #107).
        let name: String
        switch settings.fitMethod {
        case .completeTheilSen: name = "complete-theil-sen-cpp-praat7-peak"
        case .siegelRepeatedMedian: name = "siegel-repeated-median-cpp-praat7-peak"
        case .leastSquares, .praat7002Robust: name = "praat-7.0.02-straight-cpp"
        }
        return try ProfileIdentity(
            identifier: VersionedIdentifier(name: name, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, frame, cepstrogram, settings
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        guard c.contains(.cepstrogram) else { throw CPPError.invalidConfiguration }
        let frame = try c.decode(PowerCepstrumConfiguration.self, forKey: .frame)
        let settings = try c.decode(CPPConfiguration.self, forKey: .settings)
        if let upstream = try c.decodeIfPresent(CepstrogramConfiguration.self, forKey: .cepstrogram)
        {
            guard upstream.frame == frame else { throw CPPError.profileMismatch }
            self.init(cepstrogram: upstream, settings: settings)
        } else {
            self.init(frame: frame, settings: settings)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(frame, forKey: .frame)
        try c.encode(cepstrogram, forKey: .cepstrogram)
        try c.encode(settings, forKey: .settings)
    }
}

/// Resolved geometry exposes the actual fit rather than just its requested bounds.
public struct CPPLayout: Sendable, Hashable {
    public let binCount: Int
    public let quefrencyStepSeconds: Double
    public let searchStartSeconds: Double
    public let searchEndSeconds: Double
    public let fitStartSeconds: Double
    public let fitEndSeconds: Double
    public let firstFitBin: Int
    public let lastFitBin: Int
    public var fitPointCount: Int { max(0, lastFitBin - firstFitBin + 1) }
    /// Slopes evaluated per frame, excluding residual/median work; zero for LS.
    public let slopeEvaluationCount: Int
    public let unavailability: UnavailabilityReason?

    public init(profile: CPPProfile) throws {
        let c = profile.settings
        let step = profile.frame.quefrencyStepSeconds
        let count = profile.frame.binCount
        let maximum = Double(count - 1) * step
        let start = c.fitEndSeconds == 0 ? 0 : c.fitStartSeconds
        let end = c.fitEndSeconds == 0 ? maximum : min(c.fitEndSeconds, maximum)
        let first = max(1, Int(ceil(start / step)))
        let last = min(count - 1, Int(floor(end / step)))
        let points = max(0, last - first + 1)
        guard c.fitMethod == .leastSquares || points <= CPPConfiguration.maximumRobustFitPoints
        else { throw CPPError.capacityExceeded }
        binCount = count
        quefrencyStepSeconds = step
        searchStartSeconds = 1 / c.pitchCeilingHz
        searchEndSeconds = min(1 / c.pitchFloorHz, maximum)
        fitStartSeconds = start
        fitEndSeconds = end
        firstFitBin = first
        lastFitBin = last
        switch c.fitMethod {
        case .leastSquares: slopeEvaluationCount = 0
        case .completeTheilSen: slopeEvaluationCount = points * (points - 1) / 2
        case .siegelRepeatedMedian: slopeEvaluationCount = points * (points - 1)
        case .praat7002Robust: slopeEvaluationCount = max(0, points - 1) * max(0, points - 1)
        }
        if searchStartSeconds > searchEndSeconds || start > maximum {
            unavailability = .unsupportedRange
        } else if points < 3 {
            unavailability = .insufficientData
        } else {
            unavailability = nil
        }
    }
}
