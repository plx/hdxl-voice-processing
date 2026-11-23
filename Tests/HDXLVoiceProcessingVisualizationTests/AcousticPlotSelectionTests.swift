import Foundation
import Testing

@testable import HDXLVoiceProcessing
@testable import HDXLVoiceProcessingVisualization

@Suite struct AcousticPlotSelectionTests {
    @Test func sharedSelectionPreservesOverlappingAndCoincidentScalarObservations() throws {
        let template = try visualizationResult()
        let start: Int64 = (1 << 54) + 7
        let axis = try VisualizationTimeAxis(origin: visualizationSource(start, 0))
        func row(_ offset: Int64, _ length: Int64, _ value: Double) throws
            -> AcousticMetricObservation
        {
            try AcousticMetricObservation(
                MeasurementResult(
                    measurement: template.measurement, profile: template.profile,
                    timing: .init(
                        source: visualizationSource(start + offset, length),
                        includedSampleCount: length),
                    outcome: .available(.init(value: value))))
        }
        let input = try [row(0, 100, 1), row(8, 4, 2), row(9, 2, 3), row(12, 1, 4)]
        let plot = try AcousticPlotData(
            metric: input[0].measurement.id.series, observations: input, axis: axis)
        #expect(plot.columns.compactMap { $0.value(at: 0) } == [2, 3, 4, 1])
        let longWindowOnly = try VisualizationSelection(source: visualizationSource(start + 14, 0))
        #expect(plot.inspect(longWindowOnly)?.column == 3)
        let cursor = try #require(plot.cursor(for: .init(column: 2, bin: 0)))
        #expect(cursor.source.startSample == start + 12 && plot.inspect(cursor)?.column == 2)
        #expect(plot.inspect(.init(source: try visualizationSource(start + 100, 0))) == nil)
    }

    @Test func acousticSPLRequiresTheIdentityOfTheHostsCalibrationRecord() throws {
        let digital = try visualizationResult()
        let axis = try VisualizationTimeAxis(origin: visualizationSource(100, 0))
        let calibration = try ProfileIdentity(
            identifier: .init(name: "synthetic-meter-calibration", version: 2),
            sha256: String(repeating: "b", count: 64))
        let spl = try AcousticMetricObservation(
            MeasurementResult(
                measurement: .init(
                    kind: .calibratedSPL,
                    unit: .decibelsSPL, algorithm: digital.measurement.algorithm),
                profile: digital.profile,
                timing: digital.timing, outcome: .available(.init(value: 72.1))))
        #expect(throws: VisualizationError.invalidConfiguration) {
            try AcousticPlotData(metric: spl.measurement.id.series, observations: [spl], axis: axis)
        }
        let plot = try AcousticPlotData(
            metric: spl.measurement.id.series, observations: [spl], axis: axis,
            calibration: calibration)
        #expect(
            plot.calibration == calibration && plot.unit == .decibelsSPL
                && plot.columns[0].value(at: 0) == 72.1)
        let amplitude = AcousticMetricObservation(digital)
        #expect(throws: VisualizationError.invalidConfiguration) {
            try AcousticPlotData(
                metric: amplitude.measurement.id.series, observations: [amplitude], axis: axis,
                calibration: calibration)
        }
    }

    @Test func personalOverlayPreservesSelectedMedianCalibrationAndSourceIdentity() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let cpps = try f.metric(.cpps, algorithm: .cpps)
        let identity = CalibrationDigest(bytes: Data("synthetic-personal-target".utf8))
        let export = try #require(
            cpps.columns.compactMap { column -> ScheduledMeasurementExport? in
                if case .metric(let point) = column { return point.measurement.scheduled }
                return nil
            }.first)
        let counts = try CalibrationCoverage(export.dependencyCoverage)
        let values = PersonalTargetValues(
            cppsDB: 13.5, fundamentalFrequencyHz: 125, levelDBFS: -18,
            selectedFraction: 1, cppsAvailableFraction: 1, pitchAvailableFraction: 1,
            levelAvailableFraction: 1)
        func overlay(
            _ coverage: CalibrationCoverage?, _ profile: ProfileIdentity?, _ source: SourceInterval,
            disposition: PersonalTargetFeedbackInputDisposition = .accepted
        ) -> AcousticPersonalTargetOverlay? {
            let evidence = PersonalTargetFeedbackInterval(
                source: source, analysisIdentity: identity, profile: profile,
                statistic: .selectedIntervalLowerMedianV1,
                analysisImplementation: cpps.profile.identifier,
                sourceEndHostNanoseconds: 0, coverage: coverage, selectedTags: [:])
            return AcousticPersonalTargetOverlay(
                .init(
                    targetIdentity: identity, configurationIdentity: identity,
                    profile: cpps.profile, statistic: .selectedIntervalLowerMedianV1,
                    state: .onTarget, reasons: [.targetMatch],
                    modelReasons: [], responsibleFeature: .cpps, proximity: .insidePreferred,
                    evidence: evidence, values: values,
                    progress: .init(
                        qualifiedSeconds: 1, entrySeconds: 1, exitSeconds: 0, entryObservations: 1,
                        exitObservations: 0),
                    coverage: .init(), statistics: .init(), inputDisposition: disposition,
                    evaluatedAtHostNanoseconds: 0,
                    evidenceAgeNanoseconds: 0))
        }
        let source = export.dependencyTiming.source
        let mark = try #require(overlay(counts, cpps.profile, source))
        #expect(mark.target == identity && mark.profile == cpps.profile && mark.source == source)
        #expect(mark.state == .onTarget && mark.selectedMedianDB == 13.5 && mark.applies(to: cpps))
        #expect(!mark.applies(to: try f.metric(.cpp, algorithm: .cpps)))
        #expect(overlay(nil, cpps.profile, source) == nil)
        #expect(overlay(counts, cpps.profile, source, disposition: .duplicate) == nil)
        #expect(overlay(counts, try visualizationProfile().identity(), source) == nil)
        let foreign = try #require(overlay(counts, cpps.profile, try visualizationSource()))
        #expect(!foreign.applies(to: cpps))
    }
}
