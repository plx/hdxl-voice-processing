import Foundation

/// Prepared raw fit and two-formant correction. Reuse on a single analysis worker.
public final class PreparedHarmonicDifference<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: HarmonicCorrectionProfile
    public let rawAnalyzer: PreparedHarmonicFit<Sample>
    public var rawIdentity: ProfileIdentity { rawAnalyzer.identity }
    public let correctedIdentity: ProfileIdentity
    let boundFormants: ProfileIdentity
    let correctedDescriptor: MeasurementDescriptor

    public init(
        _ configuration: HarmonicCorrectionProfile,
        diagnosticMode: RuntimeDiagnosticMode = .disabled
    ) throws {
        self.configuration = configuration
        rawAnalyzer = try PreparedHarmonicFit(configuration.fit, diagnosticMode: diagnosticMode)
        correctedIdentity = try configuration.identity()
        correctedDescriptor = try HarmonicCorrectionProfile.descriptor
        boundFormants = try BurgFormantProfile.bind(
            configuration.formants.identity(),
            to: configuration.fit.pitchProfile, matched: true)
    }

    public func fit(
        _ pcm: UnsafeBufferPointer<Sample>, source: SourceInterval,
        pitch: MeasurementResult?
    ) throws -> RawHarmonicFrame {
        try rawAnalyzer.fit(pcm, source: source, pitch: pitch)
    }

    /// Complete analysis with a full Burg frame when supplied. A missing correction dependency leaves the raw result available.
    public func analyze(
        _ pcm: UnsafeBufferPointer<Sample>, source: SourceInterval, pitch: MeasurementResult?,
        formants: BurgFormantFrame? = nil
    ) throws -> CorrectedHarmonicFrame {
        try correct(fit(pcm, source: source, pitch: pitch), formants: formants)
    }
}
