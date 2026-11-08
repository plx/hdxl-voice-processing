import HDXLVoiceProcessing

public enum VisualizationFrameDomain: String, Sendable, Hashable, CaseIterable {
    case waveform, spectrum, cepstrum, diagnostic

    func validate(_ unit: MeasurementUnit) throws {
        let accepted: Bool
        switch self {
        case .waveform: accepted = unit == .seconds || unit == .samples
        case .spectrum: accepted = unit == .hertz
        case .cepstrum: accepted = unit == .seconds
        case .diagnostic: accepted = true
        }
        guard accepted else { throw VisualizationError.incompatibleAxis }
    }
}

/// Existing owned public Core values, never a processor's borrowed buffer.
public enum VisualizationFramePayload: Sendable, Hashable {
    case intermediate(IntermediateSnapshot)
    case powerCepstrum(PowerCepstrumFrame)
}

/// Renderer-facing axes keep their physical normalization. A spectrum is not
/// implicitly squared/logged, and a cepstrum is not reinterpreted as a dB scale.
/// Parent measurement timing/status remains available separately when its support
/// differs from the intermediate's support. No frame coverage is invented.
public struct VisualizationFrameSnapshot: Sendable, Hashable {
    public let domain: VisualizationFrameDomain
    public let profile: ProfileIdentity
    public let payload: VisualizationFramePayload
    public let parentMeasurement: MeasurementResult?
    public let limits: VisualizationLimits

    public init(
        intermediate: IntermediateSnapshot, profile: ProfileIdentity,
        domain: VisualizationFrameDomain, limits: VisualizationLimits = .standard
    ) throws {
        try domain.validate(intermediate.xUnit)
        guard intermediate.values.count <= limits.maximumFrameScalars else {
            throw VisualizationError.capacityExceeded
        }
        var metadata = VisualizationMetadataBudget(limits)
        try metadata.charge(profile)
        try metadata.charge(intermediate.stage)
        self.domain = domain
        self.profile = profile
        payload = .intermediate(intermediate)
        parentMeasurement = nil
        self.limits = limits
    }

    public init(
        measurement: MeasurementResult, intermediateIndex: Int,
        domain: VisualizationFrameDomain, limits: VisualizationLimits = .standard
    ) throws {
        guard measurement.intermediates.indices.contains(intermediateIndex) else {
            throw VisualizationError.invalidConfiguration
        }
        let intermediate = measurement.intermediates[intermediateIndex]
        try domain.validate(intermediate.xUnit)
        var remaining = limits.maximumFrameScalars
        for frame in measurement.intermediates {
            guard frame.values.count <= remaining else { throw VisualizationError.capacityExceeded }
            remaining -= frame.values.count
        }
        var metadata = VisualizationMetadataBudget(limits)
        try metadata.charge(measurement)
        self.domain = domain
        profile = measurement.profile
        payload = .intermediate(intermediate)
        parentMeasurement = measurement
        self.limits = limits
    }

    /// An unavailable power cepstrum may retain a finite prefix. The original
    /// reason, expected bin count, recipe and boundary-extension context survive.
    public init(_ frame: PowerCepstrumFrame, limits: VisualizationLimits = .standard) throws {
        guard frame.configuration.frame.binCount <= limits.maximumFrameScalars else {
            throw VisualizationError.capacityExceeded
        }
        var metadata = VisualizationMetadataBudget(limits)
        try metadata.charge(frame.profile)
        domain = .cepstrum
        profile = frame.profile
        payload = .powerCepstrum(frame)
        parentMeasurement = nil
        self.limits = limits
    }

    /// One owned mono sample per source frame. Channel selection/conditioning must
    /// be explicit in the supplied profile. Empty input is a no-data state, not a frame.
    public init(
        waveform: [Double], source: SourceInterval, profile: ProfileIdentity,
        stage: VersionedIdentifier, limits: VisualizationLimits = .standard
    ) throws {
        guard waveform.count <= limits.maximumFrameScalars else {
            throw VisualizationError.capacityExceeded
        }
        guard !waveform.isEmpty, Int64(exactly: waveform.count) == source.sampleCount else {
            throw VisualizationError.invalidConfiguration
        }
        try self.init(
            intermediate: IntermediateSnapshot(
                stage: stage, source: source, xUnit: .seconds, yUnit: .normalizedAmplitude,
                xOrigin: 0, xStep: 1 / source.sampleRate, values: waveform),
            profile: profile, domain: .waveform, limits: limits)
    }

    public var source: SourceInterval {
        switch payload {
        case .intermediate(let frame): frame.source
        case .powerCepstrum(let frame): frame.context.timing.source
        }
    }

    public var values: [Double] {
        switch payload {
        case .intermediate(let frame): frame.values
        case .powerCepstrum(let frame): frame.values
        }
    }

    public var xUnit: MeasurementUnit {
        switch payload {
        case .intermediate(let frame): frame.xUnit
        case .powerCepstrum: .seconds
        }
    }

    public var yUnit: MeasurementUnit {
        switch payload {
        case .intermediate(let frame): frame.yUnit
        case .powerCepstrum(let frame): frame.unit
        }
    }

    public var xOrigin: Double {
        switch payload {
        case .intermediate(let frame): frame.xOrigin
        case .powerCepstrum: 0
        }
    }

    public var xStep: Double {
        switch payload {
        case .intermediate(let frame): frame.xStep
        case .powerCepstrum(let frame): frame.quefrencyStepSeconds
        }
    }

    public var expectedValueCount: Int {
        switch payload {
        case .intermediate(let frame): frame.values.count
        case .powerCepstrum(let frame): frame.configuration.frame.binCount
        }
    }

    public var unavailability: UnavailabilityReason? {
        switch payload {
        case .intermediate: nil
        case .powerCepstrum(let frame): frame.unavailability
        }
    }

    public func selected(by selection: VisualizationSelection) -> Bool {
        selection.intersects(source)
    }
}
