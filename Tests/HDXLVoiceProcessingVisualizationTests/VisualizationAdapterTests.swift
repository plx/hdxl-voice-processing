import CryptoKit
import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization
import Testing

@Test func visualizationScheduledPCMRetainsDependencyCoverageAndClocks() throws {
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: PCMChannelSelection(channelIndex: 0),
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64, windowLength: 160, hopLength: 80,
            accumulation: .compensatedSliding, weighting: .none))
    let source = try visualizationSource(1000, 320)
    let timeline = try MaskTimeline(
        MaskPlan(source: source, provenances: [], policy: MaskSelectionPolicy(), observations: []))
    let mask = try PreparedAnalysisMask(timeline: timeline, scope: .selected)
    let origin = try AnalysisScheduleOrigin(
        source: visualizationSource(1000, 0), continuityEpoch: visualizationEpoch.successor(),
        sourceStartSeconds: 20, hostStartNanoseconds: 2_000_000_000, wallClockStartUnixSeconds: 1000
    )
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .finite, expectedSampleCount: 320, mask: mask)
    var frames: [ScheduledFrame] = []
    try Array(repeating: 0.25, count: 320).withUnsafeBufferPointer {
        _ = try worker.processInterleaved($0, interval: source) { frames.append($0) }
    }
    _ = try worker.finish { frames.append($0) }
    let frame = try #require(frames.first)
    let export = try frame.export(.rms)
    let adapted = try VisualizationMeasurement(frame, metric: .rms)
    #expect(adapted.scheduled == export)
    #expect(adapted.result == export.result)
    #expect(adapted.id.series.scheduledOrigin == origin)
    #expect(adapted.scheduled?.mask == mask.provenance)
    #expect(adapted.scheduled?.dependencyCoverage == frame.coverage)
    #expect(adapted.scheduled?.dependencyTiming == frame.timing)
    #expect(adapted.result.timing.hostStartNanoseconds == 2_000_000_000)
    #expect(adapted.result.timing.source.startSample == 1000)
    #expect(adapted.numericValue == 0.25)
    let bare = VisualizationMeasurement(adapted.result)
    #expect(bare.id.series != adapted.id.series)
    #expect(throws: VisualizationError.incompatibleSeries) {
        try VisualizationMetricSnapshot(series: adapted.id.series, measurements: [bare])
    }
    let document = try VisualizationProfileSnapshot(profile)
    let bytes = Data(try #require(document.canonicalRecipe).utf8)
    #expect(try JSONDecoder().decode(AnalysisScheduleProfile.self, from: bytes) == profile)
    #expect(
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            == document.identity.sha256)
}

@Test func visualizationFrameAdapterPreservesAxesParentAndPartialCepstrum() throws {
    let intermediate = try IntermediateSnapshot(
        stage: VersionedIdentifier(name: "spectrum-power", version: 1),
        source: visualizationSource(), xUnit: .hertz, yUnit: .normalizedSquaredAmplitude,
        xOrigin: 0, xStep: 100, values: [0, 0.5, 2])
    let parent = try visualizationResult(
        outcome: .unavailable(.inapplicableTask), intermediates: [intermediate])
    let spectrum = try VisualizationFrameSnapshot(
        measurement: parent, intermediateIndex: 0, domain: .spectrum)
    #expect(spectrum.values == [0, 0.5, 2])
    #expect(spectrum.xUnit == .hertz && spectrum.yUnit == .normalizedSquaredAmplitude)
    #expect(spectrum.xStep == 100)
    #expect(spectrum.parentMeasurement == parent)
    // Finite intermediate; parent applicability is separate.
    #expect(spectrum.unavailability == nil)
    #expect(throws: VisualizationError.incompatibleAxis) {
        try VisualizationFrameSnapshot(measurement: parent, intermediateIndex: 0, domain: .cepstrum)
    }
    let configuration = try CPPSProfile.murtonRecipePraat7(
        sourceSampleRate: 16000, declaredInputBandwidthHz: 8000
    ).cepstrogram
    let context = try CepstralFrameContext(
        origin: visualizationSource(100, 0), timing: parent.timing, frameIndex: 2,
        firstAnalysisSampleIndex: 0, suppliedAnalysisSampleCount: 3, centerSecondsFromOrigin: 0.001,
        usesBoundaryExtension: true)
    let native = try PowerCepstrumFrame(
        configuration: configuration, context: context, values: [1, 4],
        unavailability: .insufficientData)
    let cepstrum = try VisualizationFrameSnapshot(native)
    #expect(cepstrum.payload == .powerCepstrum(native))
    #expect(cepstrum.values == [1, 4])
    #expect(cepstrum.unavailability == .insufficientData)
    #expect(cepstrum.expectedValueCount > cepstrum.values.count)
    #expect(cepstrum.yUnit == .inverseSecondsSquared)
    #expect(cepstrum.xStep == native.quefrencyStepSeconds)
    #expect(cepstrum.selected(by: VisualizationSelection(source: try visualizationSource(105, 0))))
}

@Test func visualizationSegmentationRetainsMissingExcludedAndWholeTimelineCoverage() throws {
    let source = try visualizationSource(100, 100)
    let provenance = try MaskProvenance(
        kind: .externalAnnotation, identifier: VersionedIdentifier(name: "annotations", version: 1),
        parameters: ["instructions": .text("fixture")])
    let plan = try MaskPlan(
        source: source, provenances: [provenance],
        policy: MaskSelectionPolicy(selectionSources: [0]),
        observations: [
            MaskObservation(
                source: source, provenanceIndex: 0, selection: .selected, tags: [.speechDetected]),
            MaskObservation(
                source: visualizationSource(140, 20), provenanceIndex: 0,
                tags: [.missingAcquisition]),
            MaskObservation(
                source: visualizationSource(180, 10), provenanceIndex: 0, selection: .rejected),
        ])
    let timeline = try MaskTimeline(plan)
    let snapshot = try VisualizationSegmentationSnapshot(timeline)
    #expect(snapshot.timeline == timeline)
    #expect(snapshot.timeline.coverage.missingSampleCount == 20)
    #expect(snapshot.timeline.coverage.excludedEligibleSampleCount == 10)
    #expect(snapshot.timeline.coverage.selectedSampleCount == 70)
    let gap = try #require(
        snapshot.selected(by: VisualizationSelection(source: visualizationSource(150, 0))).first)
    #expect(!gap.isEligible && !gap.isSelected)
    #expect(gap.tags.contains(.missingAcquisition))
    #expect(gap.source == (try visualizationSource(140, 20)))
    #expect(snapshot.timeline.coverage.sourceSampleCount == 100)
}

@Test func visualizationProfileAndDiagnosticsInspectionDoesNotInventData() throws {
    let profile = try visualizationProfile()
    let document = try VisualizationProfileSnapshot(profile)
    #expect(document.definition == .analysis(profile))
    #expect(
        document.canonicalRecipe == String(decoding: try profile.canonicalJSON(), as: UTF8.self))
    let unknown = VisualizationProfileSnapshot(identity: document.identity)
    #expect(unknown.definition == .identityOnly && unknown.canonicalRecipe == nil)
    let latency = RuntimeLatencySummary()
    let id = try VersionedIdentifier(name: "render-cpu-duration", version: 1)
    let metric = VisualizationDiagnosticValue.latency(id: id, summary: latency)
    let diagnostics = try VisualizationDiagnosticsSnapshot(mode: .disabled, values: [metric])
    #expect(diagnostics.values == [metric])
    #expect(latency.meanNanoseconds == nil)
    #expect(diagnostics.source == nil && diagnostics.profile == nil)
    #expect(throws: VisualizationError.invalidConfiguration) {
        try VisualizationDiagnosticsSnapshot(mode: .disabled, values: [metric, metric])
    }
}

@Test func visualizationUnitConversionsAreExplicitAndKeepOriginalMeaning() throws {
    let percent = try VisualizationValueFormat(conversion: .percentage)
    let original = MeasurementOutcome.available(
        try ScalarEstimate(value: 0.125, confidence: 0.8, warnings: [.lowConfidence]))
    let displayed = try percent.format(
        original, unit: .fraction, locale: Locale(identifier: "en_US_POSIX"))
    #expect(displayed.displayValue == 12.5 && displayed.valueText == "12.5")
    #expect(displayed.originalOutcome == original && displayed.originalUnit == .fraction)
    #expect(displayed.unit.symbol == "%")
    #expect(
        try percent.format(.available(ScalarEstimate(value: 12.5)), unit: .percent).displayValue
            == 12.5)
    let milliseconds = try VisualizationValueFormat(conversion: .milliseconds)
    #expect(
        try milliseconds.format(.available(ScalarEstimate(value: 0.003)), unit: .seconds)
            .displayValue == 3)
    #expect(throws: VisualizationError.unsupportedDisplayConversion) {
        try percent.format(original, unit: .hertz)
    }
    #expect(throws: VisualizationError.nonfiniteDisplayValue) {
        try percent.format(
            .available(ScalarEstimate(value: .greatestFiniteMagnitude)), unit: .fraction)
    }
    let absent = try percent.format(.unavailable(.excluded), unit: .fraction)
    #expect(absent.displayValue == nil && absent.valueText == "Excluded audio")
    let zero = try VisualizationValueFormat.standard.format(
        .available(ScalarEstimate(value: 0)), unit: .decibelsFullScale,
        locale: Locale(identifier: "en_US_POSIX"))
    #expect(zero.valueText == "0" && zero.displayValue == 0)
    #expect(zero.unit.symbol == "dBFS")
    #expect(VisualizationUnitLabel.native(.decibelsSPL).symbol == "dB SPL")
    #expect(VisualizationUnitLabel.native(.decibelsRatio).spoken != zero.unit.spoken)
}

@Test(arguments: MeasurementUnit.allCases)
func visualizationEveryUnitHasDistinctInspectableText(_ unit: MeasurementUnit) throws {
    let formatted = try VisualizationValueFormat.standard.format(
        .unavailable(.insufficientData), unit: unit)
    #expect(formatted.originalUnit == unit)
    #expect(formatted.displayValue == nil)
    #expect(!formatted.unit.symbol.isEmpty && !formatted.unit.spoken.isEmpty)
}
