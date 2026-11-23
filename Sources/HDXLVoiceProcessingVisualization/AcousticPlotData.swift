import Foundation
import HDXLVoiceProcessing

public enum AcousticPlotKind: Sendable, Hashable {
    case waveform, spectrum, spectrogram, cepstrogram
    case metric(MeasurementDescriptor)

    public var title: String {
        switch self {
        case .waveform: "Waveform"
        case .spectrum: "Frequency spectrum"
        case .spectrogram: "Spectrogram"
        case .cepstrogram: "Power cepstrogram"
        case .metric(let descriptor): VisualizationText.measurement(descriptor.kind)
        }
    }

    var isImage: Bool { self == .spectrogram || self == .cepstrogram }
}

/// One immutable, original observation or analysis column. No borrowed buffer escapes.
public enum AcousticPlotPayload: Sendable, Hashable {
    case metric(AcousticMetricObservation)
    case waveform(VisualizationFrameSnapshot)
    case spectral(SpectrogramFrame, SpectrumPresentation)
    case cepstral(PowerCepstrumFrame)

    public var support: SourceInterval {
        switch self {
        case .metric(let sample): sample.measurement.result.timing.source
        case .waveform(let frame): frame.source
        case .spectral(let frame, _): frame.info.source
        case .cepstral(let frame): frame.context.timing.source
        }
    }

    public var dependency: SourceInterval {
        if case .metric(let sample) = self { return sample.dependency }
        return support
    }

    public var unavailability: UnavailabilityReason? {
        switch self {
        case .metric(let sample):
            if case .unavailable(let reason) = sample.measurement.result.outcome { return reason }
        case .spectral(let frame, let presentation):
            if case .unavailable(let reason) = frame.info.status { return reason }
            if frame.info.status == .noEnergy, case .decibels = presentation { return .silence }
        case .cepstral(let frame): return frame.unavailability
        case .waveform: break
        }
        return nil
    }

    func center(on axis: VisualizationTimeAxis) throws -> Double {
        switch self {
        case .metric(let sample): return try sample.seconds(on: axis)
        case .cepstral(let frame):
            let start = try axis.placement(of: frame.context.origin).lowerSeconds
            return start + frame.context.centerSecondsFromOrigin
        default: return try axis.placement(of: support).centerSeconds
        }
    }

    /// Original independent data remain available even when presentation is unavailable,
    /// e.g. a zero-power bin in dB or a retained prefix of an incomplete cepstrum.
    public func rawValue(at bin: Int) -> Double? {
        switch self {
        case .metric(let sample): bin == 0 ? sample.measurement.numericValue : nil
        case .waveform(let frame): frame.values.indices.contains(bin) ? frame.values[bin] : nil
        case .spectral(let frame, _):
            frame.binPower.indices.contains(bin) ? frame.binPower[bin] : nil
        case .cepstral(let frame): frame.values.indices.contains(bin) ? frame.values[bin] : nil
        }
    }

    public func value(at bin: Int) -> Double? {
        if case .spectral(let frame, let presentation) = self {
            return frame.value(at: bin, presentation: presentation).estimate?.value
        }
        guard unavailability == nil else { return nil }
        return rawValue(at: bin)
    }

    public func reason(at bin: Int) -> UnavailabilityReason? {
        if case .spectral(let frame, let presentation) = self,
            case .unavailable(let reason) = frame.value(at: bin, presentation: presentation)
        {
            return reason
        }
        return unavailability
    }
}

/// Fixed-history inputs to the acoustic plots. Construction is a worker/control-path
/// operation. Both the number of columns and the complete displayed grid are bounded.
public struct AcousticPlotData: Sendable {
    public let kind: AcousticPlotKind
    public let timeAxis: VisualizationTimeAxis
    public let profile: ProfileIdentity
    public let calibration: ProfileIdentity?
    public let settings: String
    public let valueLabel: String
    public let unit: MeasurementUnit
    public let rawUnit: MeasurementUnit
    public let columns: [AcousticPlotPayload]
    public let centers: [Double]
    public let binCount: Int
    public let binStep: Double
    public let hopSeconds: Double?
    public let boundaries: [SourceDiscontinuity]
    public let markers: [AcousticPlotMarker]
    public let range: ClosedRange<Double>?
    let intensities: [AcousticIntensityColumn]

    private init(
        kind: AcousticPlotKind, axis: VisualizationTimeAxis, profile: ProfileIdentity,
        settings: String, valueLabel: String, unit: MeasurementUnit, rawUnit: MeasurementUnit,
        columns: [AcousticPlotPayload], bins: Int, step: Double, hop: Double? = nil,
        boundaries: [SourceDiscontinuity] = [], markers: [AcousticPlotMarker] = [],
        calibration: ProfileIdentity? = nil, limits: VisualizationLimits
    ) throws {
        guard columns.count <= limits.maximumMeasurements, bins > 0,
            bins <= limits.maximumFrameScalars,
            columns.count <= limits.maximumFrameScalars / bins,
            markers.count <= limits.maximumSegments,
            boundaries.count <= limits.maximumSegments - markers.count
        else { throw VisualizationError.capacityExceeded }
        guard step.isFinite, step > 0, (Double(bins - 1) * step).isFinite,
            hop.map({ $0.isFinite && $0 > 0 }) ?? true
        else { throw VisualizationError.incompatibleAxis }
        var metadata = VisualizationMetadataBudget(limits)
        try metadata.charge(profile)
        try metadata.charge(settings)
        if let calibration { try metadata.charge(calibration) }
        var positions: [Double] = []
        var minimum: Double?
        var maximum: Double?
        var intermediates = 0
        for column in columns {
            guard axis.source.contains(column.support), axis.source.contains(column.dependency)
            else {
                throw VisualizationError.incompatibleSource
            }
            let center = try column.center(on: axis)
            guard center.isFinite else { throw VisualizationError.nonfiniteDisplayValue }
            if let prior = positions.last, kind.isImage, center <= prior {
                throw VisualizationError.unorderedMeasurements
            }
            positions.append(center)
            switch column {
            case .metric(let point):
                try metadata.charge(point.measurement.result)
                if let mask = point.measurement.scheduled?.mask { try metadata.charge(mask) }
                for detail in point.context { try metadata.charge(detail) }
                for frame in point.measurement.result.intermediates {
                    guard frame.values.count <= limits.maximumFrameScalars - intermediates else {
                        throw VisualizationError.capacityExceeded
                    }
                    intermediates += frame.values.count
                }
            case .spectral(let frame, _):
                try metadata.charge(frame.layout.profile)
                if let conditioning = frame.layout.conditioning {
                    try metadata.charge(conditioning)
                }
                if let selection = frame.info.selectionProfile { try metadata.charge(selection) }
            case .cepstral(let frame): try metadata.charge(frame.profile)
            case .waveform(let frame): try metadata.charge(frame.profile)
            }
            guard column.unavailability == nil else { continue }
            for bin in 0..<bins {
                if let value = column.value(at: bin) {
                    minimum = min(minimum ?? value, value)
                    maximum = max(maximum ?? value, value)
                }
            }
        }
        for boundary in boundaries {
            guard
                boundary.previousEpoch == axis.source.epoch
                    || boundary.nextEpoch == axis.source.epoch
            else {
                throw VisualizationError.incompatibleSource
            }
            if let missing = boundary.missingSource, missing.epoch == axis.source.epoch,
                !axis.source.contains(missing)
            {
                throw VisualizationError.incompatibleSource
            }
        }
        for marker in markers {
            try metadata.charge(marker.label)
            try metadata.charge(marker.profile)
            try metadata.charge(marker.detail)
        }
        self.kind = kind
        timeAxis = axis
        self.profile = profile
        self.calibration = calibration
        self.settings = settings
        self.valueLabel = valueLabel
        self.unit = unit
        self.rawUnit = rawUnit
        if case .metric = kind {
            // Nested supports may have coincident or reversed centers. Keep every original
            // observation, with input order breaking exact ties.
            let order = positions.indices.sorted { positions[$0] < positions[$1] }
            self.columns = order.map { columns[$0] }
            centers = order.map { positions[$0] }
        } else {
            self.columns = columns
            centers = positions
        }
        binCount = bins
        binStep = step
        hopSeconds = hop
        self.boundaries = boundaries
        self.markers = markers
        let bounds = minimum.flatMap { low in maximum.map { low...$0 } }
        range = bounds
        intensities =
            kind.isImage
            ? columns.map { AcousticIntensityColumn(column: $0, bins: bins, range: bounds) } : []
    }

    public init(
        metric series: VisualizationSeriesKey, observations: [AcousticMetricObservation],
        axis: VisualizationTimeAxis, recipe: VisualizationProfileSnapshot? = nil,
        calibration: ProfileIdentity? = nil, boundaries: [SourceDiscontinuity] = [],
        limits: VisualizationLimits = .standard
    ) throws {
        guard series.source == axis.source else { throw VisualizationError.incompatibleSource }
        guard observations.count <= limits.maximumMeasurements else {
            throw VisualizationError.capacityExceeded
        }
        guard observations.allSatisfy({ $0.measurement.id.series == series }),
            recipe == nil || recipe?.identity == series.profile
        else { throw VisualizationError.incompatibleSeries }
        guard (series.measurement.kind == .calibratedSPL) == (calibration != nil) else {
            throw VisualizationError.invalidConfiguration
        }
        let settings =
            recipe?.canonicalRecipe
            ?? "Profile \(series.profile.identifier.name) · v\(series.profile.identifier.version)"
        try self.init(
            kind: .metric(series.measurement), axis: axis, profile: series.profile,
            settings: settings,
            valueLabel: VisualizationText.measurement(series.measurement.kind),
            unit: series.measurement.unit,
            rawUnit: series.measurement.unit, columns: observations.map(AcousticPlotPayload.metric),
            bins: 1, step: 1, boundaries: boundaries, calibration: calibration, limits: limits)
    }

    public init(
        metric snapshot: VisualizationMetricSnapshot, axis: VisualizationTimeAxis,
        recipe: VisualizationProfileSnapshot? = nil, calibration: ProfileIdentity? = nil
    ) throws {
        try self.init(
            metric: snapshot.series,
            observations: snapshot.measurements.map(AcousticMetricObservation.init),
            axis: axis, recipe: recipe, calibration: calibration, boundaries: snapshot.boundaries,
            limits: snapshot.limits)
    }

    public init(
        waveform frame: VisualizationFrameSnapshot, axis: VisualizationTimeAxis,
        pulses: PulseSnapshot? = nil, limits: VisualizationLimits = .standard
    ) throws {
        guard case .intermediate(let wave) = frame.payload, frame.domain == .waveform,
            frame.parentMeasurement == nil, wave.yUnit == .normalizedAmplitude,
            wave.values.count == wave.source.sampleCount, wave.xOrigin == 0,
            (wave.xUnit == .seconds && wave.xStep == 1 / wave.source.sampleRate)
                || (wave.xUnit == .samples && wave.xStep == 1)
        else { throw VisualizationError.incompatibleAxis }
        let marks = try AcousticPlotMarker.pulses(
            pulses, source: frame.source, axis: axis, limits: limits)
        try self.init(
            kind: .waveform, axis: axis, profile: frame.profile, settings: wave.stage.name,
            valueLabel: "PCM amplitude", unit: .normalizedAmplitude, rawUnit: .normalizedAmplitude,
            columns: [.waveform(frame)], bins: wave.values.count, step: 1 / wave.source.sampleRate,
            markers: marks, limits: limits)
    }

    public init(
        spectrum frame: SpectrogramFrame, axis: VisualizationTimeAxis,
        presentation: SpectrumPresentation = .binPower, harmonics: RawHarmonicFrame? = nil,
        formants: BurgFormantFrame? = nil, shape: SpectralShapeResult? = nil,
        limits: VisualizationLimits = .standard
    ) throws {
        let marks = try AcousticPlotMarker.spectrum(
            frame, harmonics: harmonics, formants: formants, shape: shape)
        try self.init(
            spectral: [frame], layout: frame.layout, axis: axis, kind: .spectrum,
            presentation: presentation, marks: marks, limits: limits)
    }

    public init(
        spectrogram frames: [SpectrogramFrame], layout: SpectrogramLayout,
        axis: VisualizationTimeAxis,
        presentation: SpectrumPresentation = .binPower, limits: VisualizationLimits = .standard
    ) throws {
        try self.init(
            spectral: frames, layout: layout, axis: axis, kind: .spectrogram,
            presentation: presentation, marks: [], limits: limits)
    }

    private init(
        spectral frames: [SpectrogramFrame], layout: SpectrogramLayout, axis: VisualizationTimeAxis,
        kind: AcousticPlotKind, presentation: SpectrumPresentation, marks: [AcousticPlotMarker],
        limits: VisualizationLimits
    ) throws {
        guard frames.count <= limits.maximumMeasurements else {
            throw VisualizationError.capacityExceeded
        }
        guard
            frames.allSatisfy({
                $0.layout == layout
                    && $0.info.epochStartSample == frames.first?.info.epochStartSample
                    && $0.info.selectionProfile == frames.first?.info.selectionProfile
            })
        else { throw VisualizationError.incompatibleSeries }
        let label: String
        switch presentation {
        case .binPower: label = "Bin power"
        case .binRMSAmplitude: label = "Bin RMS amplitude"
        case .powerDensityPerHertz: label = "Power spectral density"
        case .decibels(let reference):
            guard reference.isFinite, reference > 0 else {
                throw VisualizationError.incompatibleAxis
            }
            label = "Log power · ref \(reference) FS²"
        }
        let window = layout.framing.window
        guard axis.source.sampleRate == window.sampleRate else {
            throw VisualizationError.incompatibleSource
        }
        let settings =
            "\(window.definition.rawValue) · \(window.sampleCount)-sample window · \(layout.framing.hopLength)-sample hop"
        try self.init(
            kind: kind, axis: axis, profile: layout.profile, settings: settings, valueLabel: label,
            unit: presentation.unit, rawUnit: layout.powerUnit,
            columns: frames.map { .spectral($0, presentation) },
            bins: layout.frequency.count, step: layout.frequency.step,
            hop: Double(layout.framing.hopLength) / window.sampleRate, markers: marks,
            limits: limits)
    }

    public init(
        cepstrogram frames: [PowerCepstrumFrame], configuration: CepstrogramConfiguration,
        axis: VisualizationTimeAxis, limits: VisualizationLimits = .standard
    ) throws {
        guard frames.count <= limits.maximumMeasurements else {
            throw VisualizationError.capacityExceeded
        }
        guard axis.source.sampleRate == Double(configuration.conditioning.sourceSampleRate) else {
            throw VisualizationError.incompatibleSource
        }
        let profile = try configuration.identity()
        guard
            frames.allSatisfy({
                $0.configuration == configuration && $0.profile == profile
                    && $0.context.origin == frames.first?.context.origin
            })
        else { throw VisualizationError.incompatibleSeries }
        let frame = configuration.frame
        let settings =
            "\(frame.frameLength)-sample cepstral window · \(configuration.hopSeconds) s requested hop"
        try self.init(
            kind: .cepstrogram, axis: axis, profile: profile, settings: settings,
            valueLabel: "Cepstral power",
            unit: .inverseSecondsSquared, rawUnit: .inverseSecondsSquared,
            columns: frames.map(AcousticPlotPayload.cepstral), bins: frame.binCount,
            step: frame.quefrencyStepSeconds,
            hop: configuration.previewHopLength.map { Double($0) / Double(frame.sampleRate) }
                ?? configuration.hopSeconds,
            limits: limits)
    }
}
