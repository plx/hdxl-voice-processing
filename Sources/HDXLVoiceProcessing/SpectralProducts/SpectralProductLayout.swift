import CryptoKit
import Foundation

/// The unit of an LTAS weight is one frame or one newly covered source sample.
public enum SpectralWeighting: String, Sendable, Codable {
    case equalFrames, newlyCoveredSamples
}

/// Uniform zero-origin grid. Indices beyond count have no measured value.
public struct SpectralProductAxis: Sendable, Hashable, Codable {
    public let origin: Double
    public let count: Int
    public let step: Double
    public let unit: MeasurementUnit

    init(count: Int, step: Double, unit: MeasurementUnit) throws {
        guard count > 0, step.isFinite, step > 0, (Double(count - 1) * step).isFinite,
            unit == .hertz || unit == .seconds
        else { throw ContractError.invalidConfiguration }
        self.origin = 0
        self.count = count
        self.step = step
        self.unit = unit
    }

    public func coordinate(at index: Int) -> Double? {
        (0..<count).contains(index) ? Double(index) * step : nil
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case origin, count, step, unit }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard try c.decode(Double.self, forKey: .origin) == 0 else {
            throw ContractError.invalidConfiguration
        }
        try self.init(
            count: c.decode(Int.self, forKey: .count), step: c.decode(Double.self, forKey: .step),
            unit: c.decode(MeasurementUnit.self, forKey: .unit))
    }
}

/// Every frame and LTAS export carries its analysis grid, conditioning provenance and linear units.
/// The caller supplies mono PCM after the declared channel selection and any upstream conditioning.
public struct SpectrogramLayout: Sendable, Hashable, Codable {
    public let framing: FramingConfiguration
    public let spectrum: SpectrumConfiguration
    public let channels: PCMChannelSelection
    public let conditioning: ProfileIdentity?
    public let bandwidthHz: Double
    public let weighting: SpectralWeighting
    public let frequency: SpectralProductAxis
    public let powerUnit: MeasurementUnit
    public let equivalentNoiseBandwidthHz: Double
    public let profile: ProfileIdentity

    public init(
        framing: FramingConfiguration, transformLength: Int, channels: PCMChannelSelection,
        conditioning: ProfileIdentity? = nil, bandwidthHz: Double? = nil,
        weighting: SpectralWeighting = .equalFrames
    ) throws {
        let window = framing.window
        let transform = try FourierConfiguration(
            length: transformLength, sampleRate: window.sampleRate,
            precision: window.precision)
        spectrum = try SpectrumConfiguration(transform: transform, window: window)
        let limit = bandwidthHz ?? window.sampleRate / 2
        guard limit.isFinite, limit > 0, limit <= window.sampleRate / 2 else {
            throw ContractError.invalidConfiguration
        }
        // Binary search the transform's exact grid rule, including a bin exactly at the cutoff.
        var low = 0
        var high = transform.realBinCount
        while low < high {
            let mid = low + (high - low) / 2
            if try transform.realFrequencyHz(at: mid) <= limit { low = mid + 1 } else { high = mid }
        }
        frequency = try SpectralProductAxis(
            count: low, step: transform.frequencySpacingHz, unit: .hertz)
        let gains: (coherent: Double, energy: Double)
        if window.precision == .float32 {
            let prepared = try PreparedWindow<Float>(window)
            gains = (prepared.coherentGain, prepared.energyGain)
        } else {
            let prepared = try PreparedWindow<Double>(window)
            gains = (prepared.coherentGain, prepared.energyGain)
        }
        let enbw =
            (window.sampleRate / Double(window.sampleCount))
            * (gains.energy / (gains.coherent * gains.coherent))
        guard enbw.isFinite, enbw > 0 else { throw FourierError.invalidNormalization }
        equivalentNoiseBandwidthHz = enbw
        self.framing = framing
        self.channels = channels
        self.conditioning = conditioning
        self.bandwidthHz = limit
        self.weighting = weighting
        powerUnit = .normalizedSquaredAmplitude
        struct Parameters: Encodable {
            let framing: FramingConfiguration
            let spectrum: SpectrumConfiguration
            let channels: PCMChannelSelection
            let conditioning: ProfileIdentity?
            let bandwidthHz: Double
            let weighting: SpectralWeighting
        }
        let parameters = Parameters(
            framing: framing, spectrum: spectrum, channels: channels,
            conditioning: conditioning, bandwidthHz: limit, weighting: weighting)
        profile = try ProfileIdentity(
            identifier: VersionedIdentifier(
                name: "bounded-one-sided-spectral-products", version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(parameters)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case framing, spectrum, channels, conditioning, bandwidthHz, weighting, frequency,
            powerUnit,
            equivalentNoiseBandwidthHz, profile
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let spectrum = try c.decode(SpectrumConfiguration.self, forKey: .spectrum)
        try self.init(
            framing: c.decode(FramingConfiguration.self, forKey: .framing),
            transformLength: spectrum.transform.length,
            channels: c.decode(PCMChannelSelection.self, forKey: .channels),
            conditioning: c.decodeIfPresent(ProfileIdentity.self, forKey: .conditioning),
            bandwidthHz: c.decode(Double.self, forKey: .bandwidthHz),
            weighting: c.decode(SpectralWeighting.self, forKey: .weighting))
        guard spectrum == self.spectrum,
            try c.decode(SpectralProductAxis.self, forKey: .frequency) == frequency,
            try c.decode(MeasurementUnit.self, forKey: .powerUnit) == powerUnit,
            try c.decode(Double.self, forKey: .equivalentNoiseBandwidthHz)
                == equivalentNoiseBandwidthHz,
            try c.decode(ProfileIdentity.self, forKey: .profile) == profile
        else { throw ContractError.invalidFingerprint }
    }
}

/// RMS amplitude is the square root of a bin's contribution to the window-corrected mean square.
/// Logarithmic presentation uses 10 log10(power/referencePower), with both in amplitude squared.
public enum SpectrumPresentation: Sendable, Hashable, Codable {
    case binPower, binRMSAmplitude, powerDensityPerHertz
    case decibels(referencePower: Double)

    public var unit: MeasurementUnit {
        switch self {
        case .binPower: .normalizedSquaredAmplitude
        case .binRMSAmplitude: .normalizedAmplitude
        case .powerDensityPerHertz: .normalizedSquaredAmplitudePerHertz
        case .decibels: .decibelsRatio
        }
    }

    func convert(power: Double, spacing: Double) -> MeasurementOutcome {
        let value: Double
        switch self {
        case .binPower: value = power
        case .binRMSAmplitude: value = sqrt(power)
        case .powerDensityPerHertz: value = power / spacing
        case .decibels(let reference):
            guard reference.isFinite, reference > 0 else { return .unavailable(.invalidInput) }
            guard power > 0 else { return .unavailable(.silence) }
            value = 10 * (log10(power) - log10(reference))
        }
        guard let estimate = try? ScalarEstimate(value: value) else {
            return .unavailable(.analysisFailure)
        }
        return .available(estimate)
    }
}
