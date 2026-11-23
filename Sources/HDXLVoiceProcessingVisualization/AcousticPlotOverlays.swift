import Foundation
import HDXLVoiceProcessing

public struct AcousticPlotMarker: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case harmonic, formant, spectralMeasure, eligiblePulse, rejectedPulse
    }
    public let kind: Kind
    /// Hertz on spectra, seconds from the shared origin on waveforms.
    public let coordinate: Double
    public let label: String
    public let detail: String
    public let support: SourceInterval
    public let profile: ProfileIdentity

    static func pulses(
        _ snapshot: PulseSnapshot?, source: SourceInterval, axis: VisualizationTimeAxis,
        limits: VisualizationLimits
    ) throws -> [Self] {
        guard let snapshot else { return [] }
        let support = snapshot.result.timing.source
        guard axis.source.contains(source), axis.source.contains(support) else {
            throw VisualizationError.incompatibleSource
        }
        guard snapshot.landmarks.count <= limits.maximumSegments else {
            throw VisualizationError.capacityExceeded
        }
        let origin = try axis.placement(of: support).lowerSeconds
        let visible = try axis.placement(of: source)
        return snapshot.landmarks.compactMap { pulse in
            let time = origin + pulse.timeSeconds
            guard time >= visible.lowerSeconds, time < visible.upperSeconds else { return nil }
            return Self(
                kind: pulse.isEligible ? .eligiblePulse : .rejectedPulse, coordinate: time,
                label: pulse.isEligible ? "Eligible pulse" : "Rejected pulse",
                detail:
                    "Landmark \(pulse.index) · \(pulse.timeSeconds) s from analysis start · rejection flags \(pulse.rejections.rawValue)",
                support: support, profile: snapshot.result.profile)
        }
    }

    static func spectrum(
        _ frame: SpectrogramFrame, harmonics: RawHarmonicFrame?,
        formants: BurgFormantFrame?, shape: SpectralShapeResult?
    ) throws -> [Self] {
        let source = frame.info.source
        let center = source.startSample + source.sampleCount / 2
        func check(_ support: SourceInterval) throws {
            guard VisualizationSource(source).contains(support),
                support.startSample <= center, center < support.endSample
            else {
                throw VisualizationError.incompatibleSource
            }
        }
        var result: [Self] = []
        if let harmonics {
            let support = harmonics.measurement.timing.source
            try check(support)
            for (label, amplitude) in [("H1", harmonics.first), ("H2", harmonics.second)] {
                if let amplitude {
                    result.append(
                        Self(
                            kind: .harmonic, coordinate: amplitude.frequencyHz, label: label,
                            detail:
                                "Fitted peak \(amplitude.peakFS) FS · \(amplitude.peakDBFS) dBFS",
                            support: support, profile: harmonics.measurement.profile))
                }
            }
        }
        if let formants {
            try check(formants.timing.source)
            for candidate in formants.candidates where candidate.isCredible {
                if let number = candidate.number, let hz = candidate.frequencyHz,
                    let width = candidate.bandwidthHz
                {
                    result.append(
                        Self(
                            kind: .formant, coordinate: hz, label: "F\(number)",
                            detail: "Burg LPC · bandwidth \(width) Hz",
                            support: formants.timing.source, profile: formants.profile))
                }
            }
        }
        if let shape {
            guard shape.layout == frame.layout, shape.origin == .frame(frame.info) else {
                throw VisualizationError.incompatibleSeries
            }
            for descriptor in [SpectralShapeDescriptor.centroid, .rollOff] {
                if let scalar = shape[descriptor], let value = scalar.outcome.estimate?.value {
                    let label = VisualizationText.measurement(scalar.measurement.kind)
                    result.append(
                        Self(
                            kind: .spectralMeasure, coordinate: value, label: label,
                            detail: "Spectral shape",
                            support: shape.timing.source, profile: shape.profile))
                }
            }
        }
        return result.filter {
            $0.coordinate >= 0
                && $0.coordinate <= Double(frame.layout.frequency.count - 1)
                    * frame.layout.frequency.step
        }
    }
}

/// A time-region annotation from the fitted personal policy. The calibrated target applies
/// to a selected interval's CPPS median. Frame-level scalar values keep their own semantics.
public struct AcousticPersonalTargetOverlay: Sendable, Hashable {
    public let source: SourceInterval
    public let state: PersonalTargetFeedbackState
    public let target: CalibrationDigest
    public let profile: ProfileIdentity
    public let selectedMedianDB: Double?

    public init?(_ snapshot: PersonalTargetFeedbackSnapshot) {
        guard let interval = snapshot.evidence, !interval.isGap,
            interval.profile == snapshot.profile,
            interval.statistic == .selectedIntervalLowerMedianV1,
            snapshot.inputDisposition == .accepted
        else { return nil }
        source = interval.source
        state = snapshot.state
        target = snapshot.targetIdentity
        profile = snapshot.profile
        selectedMedianDB = snapshot.values?.cppsDB
    }

    public func applies(to plot: AcousticPlotData) -> Bool {
        guard case .metric(let descriptor) = plot.kind else { return false }
        return descriptor.kind == .cpps && descriptor.unit == .decibelsRatio
            && plot.profile == profile && plot.timeAxis.source.contains(source)
    }
}
