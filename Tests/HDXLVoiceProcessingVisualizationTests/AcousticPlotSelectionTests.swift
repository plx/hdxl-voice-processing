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
        let tie = try VisualizationSelection(source: visualizationSource(start + 10, 0))
        let geometry = AcousticPlotVerticalGeometry(scale: .init(bounds: 1...4), viewHeight: 154)
        #expect(
            plot.scalarIndex(for: tie, center: plot.centers[0], tap: (geometry.y(3), geometry))?
                .column == 1)
        #expect(plot.inspect(tie)?.column == 0)
        let gap = try SourceDiscontinuity(
            previousEpoch: visualizationEpoch, nextEpoch: visualizationEpoch.successor(),
            reason: .droppedAudio, missingSource: visualizationSource(start + 20, 12))
        let interrupted = try AcousticPlotData(
            metric: input[0].measurement.id.series, observations: input, axis: axis,
            boundaries: [gap])
        #expect(interrupted.inspect(.init(source: try visualizationSource(start + 20, 12))) == nil)
        #expect(
            interrupted.inspect(.init(source: try visualizationSource(start + 30, 4)))?.column == 3)
        let only = try AcousticPlotData(
            metric: input[0].measurement.id.series, observations: [input[0]], axis: axis)
        #expect(only.horizontalRange == 0...(100.0 / 16000))
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

    @Test func emptyScalarHistoryChargesItsDescriptorBeforeRetainingIt() throws {
        let axis = try VisualizationTimeAxis(origin: visualizationSource(100, 0))
        let profile = try ProfileIdentity(
            identifier: .init(name: "p", version: 1), sha256: String(repeating: "a", count: 64))
        let descriptor = try MeasurementDescriptor(
            kind: .rms, unit: .normalizedAmplitude,
            algorithm: .init(name: String(repeating: "x", count: 80), version: 1))
        let key = try VisualizationSeriesKey(
            measurement: descriptor, profile: profile, source: axis.source)
        let limit = try VisualizationLimits(
            maximumMeasurements: 2, maximumFrameScalars: 2, maximumSegments: 2,
            maximumMetadataBytes: 115)
        #expect(throws: VisualizationError.capacityExceeded) {
            try AcousticPlotData(metric: key, observations: [], axis: axis, limits: limit)
        }
    }

    @Test func exactSampleSupportAndSharedDependencyRetainLocalFocus() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let wave = try f.waveform()
        let index = AcousticPlotIndex(column: 0, bin: 3)
        let sample = try #require(wave.contributingSelection(for: index))
        #expect(
            sample.source.startSample == f.source.startSample + 3 && sample.source.sampleCount == 1)
        let levels = try f.metric(.levelDBFS, algorithm: .levels)
        let aligned = try #require(levels.cursor(for: .init(column: 3, bin: 0)))
        #expect(aligned.source.startSample == f.source.startSample + 680)
        let cpps = try f.metric(.cpps, algorithm: .cpps)
        let first = AcousticPlotIndex(column: 0, bin: 0)
        let focus = try #require(AcousticPlotInspection(first, in: cpps, shareSupport: true))
        #expect(focus.index == first && focus.matches(focus.shared, in: cpps))
        #expect(
            focus.shared.source == cpps.columns[0].dependency
                && !focus.matches(focus.shared, in: levels))
    }

    @Test func localHNRWindowAndCausalLevelFilterRetainDistinctDependencies() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let hnr = try #require(
            f.frames.compactMap { frame -> HNRFrameResult? in
                if case .hnr(.frame(let result)) = frame.value { return result }
                return nil
            }.first {
                $0.frameTiming.source.sampleCount < $0.dependencyTiming.source.sampleCount
                    && $0.selectedObservation != nil
            })
        let point = try AcousticMetricObservation(hnr)
        #expect(
            point.observationWindow == hnr.frameTiming.source
                && point.dependency == hnr.dependencyTiming.source)
        let after = try SourceInterval(
            epoch: point.dependency.epoch, startSample: point.observationWindow.endSample,
            sampleCount: 0, sampleRate: point.dependency.sampleRate)
        #expect(!point.intersects(.init(source: after)))
        let window = try PreparedLevelAnalyzer<Double>(
            configuration: .init(
                sampleRate: 16000, inputPrecision: .float64,
                windowLength: 400, hopLength: 160, accumulation: .direct,
                weighting: .bs1770Revision5(warmupSampleCount: 128)), epoch: f.source.epoch,
            startSample: f.source.startSample)
        var frames: [LevelWindowResult] = []
        _ = try f.pcm.withUnsafeBufferPointer {
            try window.process($0, interval: f.source) { frames.append($0) }
        }
        let frame = try #require(frames.last)
        let weighted = try AcousticMetricObservation(
            frame, kind: .kWeightedEnergy, unit: .normalizedSquaredAmplitude)
        let rms = try AcousticMetricObservation(frame, kind: .rms, unit: .normalizedAmplitude)
        #expect(
            weighted.dependency == frame.filterHistorySource
                && weighted.dependency.startSample < weighted.observationWindow.startSample)
        #expect(rms.dependency == frame.source && rms.observationWindow == frame.source)
    }

    @Test func sparseSpectrogramCellsStopAtTheAcquiredSampleBoundary() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let layout = try SpectrogramLayout(
            framing: .init(
                window: .init(
                    definition: .hannPeriodic, sampleCount: 128, sampleRate: 16_000,
                    precision: .float64), hopLength: 512, partialWindowPolicy: .emitUnavailable),
            transformLength: 128, channels: .init(channelIndex: 0))
        let fft = try PreparedSpectrogram<Double>(
            layout: layout, epoch: f.source.epoch, startSample: f.source.startSample)
        var columns: [SpectrogramFrame] = []
        _ = try f.pcm.withUnsafeBufferPointer {
            try fft.process($0, interval: f.source) { columns.append($0.owned()) }
        }
        let plot = try AcousticPlotData(spectrogram: columns, layout: layout, axis: f.axis)
        #expect(plot.imageCell(at: 0) == 0..<(128.0 / 16000))
        for i in [128, 200, 511] {
            let hole = try SourceInterval(
                epoch: f.source.epoch, startSample: f.source.startSample + Int64(i), sampleCount: 0,
                sampleRate: 16_000)
            #expect(plot.inspect(.init(source: hole)) == nil)
        }
        let next = try #require(plot.cursor(atSeconds: 512.0 / 16000))
        #expect(plot.inspect(next)?.column == 1)
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
            disposition: PersonalTargetFeedbackInputDisposition = .accepted,
            proximity: PersonalTargetFeedbackProximity = .insidePreferred,
            reasons: [PersonalTargetFeedbackReason] = [.targetMatch]
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
                    state: .onTarget, reasons: reasons,
                    modelReasons: [], responsibleFeature: .cpps, proximity: proximity,
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
        let end = try cpps.timeAxis.placement(of: source).upperSeconds
        #expect(mark.visibleSpan(on: cpps.timeAxis, in: end...(end + 1)) == nil)
        #expect(mark.visibleSpan(on: cpps.timeAxis, in: 0...end) == 0...end)
        let held = try #require(
            overlay(
                counts, cpps.profile, source, proximity: .outsideTarget, reasons: [.exitPersistence]
            ))
        #expect(
            held.state == .onTarget && held.proximity == .outsideTarget
                && held.reasons == [.exitPersistence])
        #expect(held.intervalDescription == "Current interval outside the target")
        let later = try SourceInterval(
            epoch: source.epoch, startSample: f.source.endSample + 1000, sampleCount: 50,
            sampleRate: source.sampleRate)
        let disjoint = try #require(overlay(counts, cpps.profile, later))
        #expect(!disjoint.applies(to: cpps))
        #expect(!mark.applies(to: try f.metric(.cpp, algorithm: .cpps)))
        #expect(overlay(nil, cpps.profile, source) == nil)
        #expect(overlay(counts, cpps.profile, source, disposition: .duplicate) == nil)
        #expect(overlay(counts, try visualizationProfile().identity(), source) == nil)
        let foreign = try #require(overlay(counts, cpps.profile, try visualizationSource()))
        #expect(!foreign.applies(to: cpps))
    }

    @Test func cepstralPointHasLocalCursorWindowAndFullConditioningSupport() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let scheduled = try #require(f.frames.first { $0.algorithm == .cpps })
        guard case .cpps(let frame) = scheduled.value else {
            Issue.record("Missing CPPS output")
            return
        }
        let direct = try [
            AcousticMetricObservation(frame.rawCPP), AcousticMetricObservation(frame),
        ]
        let exports = try [ScheduledMetric.cpp, .cpps].map {
            try AcousticMetricObservation(VisualizationMeasurement(scheduled, metric: $0))
        }
        for point in direct + exports {
            let source = point.dependency
            let axis = try VisualizationTimeAxis(
                origin: .init(
                    epoch: source.epoch,
                    startSample: source.startSample, sampleCount: 0, sampleRate: source.sampleRate))
            let plot = try AcousticPlotData(
                metric: point.measurement.id.series, observations: [point], axis: axis)
            let index = AcousticPlotIndex(column: 0, bin: 0)
            #expect(point.observationWindow.sampleCount < source.sampleCount)
            let cursor = try #require(plot.cursor(for: index))
            #expect(plot.inspect(cursor) == index)
            #expect(plot.contributingSelection(for: index)?.source == source)
            let end = try SourceInterval(
                epoch: source.epoch, startSample: source.endSample - 1,
                sampleCount: 0, sampleRate: source.sampleRate)
            #expect(plot.inspect(.init(source: end)) == nil)
        }
    }

    @Test func scheduledRMSAndFilteredEnergyShareTheirOwnSourceDependencies() throws {
        let start: Int64 = (1 << 54) + 11
        let origin = try visualizationSource(start, 0)
        let source = try visualizationSource(start, 129_040)
        let config = try AnalysisScheduleProfile(
            inputFormat: .init(sampleRate: 16000, channelCount: 1, encoding: .float64),
            channels: .init(channelIndex: 0),
            levels: .init(
                sampleRate: 16000, inputPrecision: .float64,
                windowLength: 400, hopLength: 160, accumulation: .direct,
                weighting: .bs1770Revision5(warmupSampleCount: 128)))
        let schedule = try PreparedAnalysisSchedule<Double>(
            profile: config,
            origin: .init(source: origin, continuityEpoch: origin.epoch.successor()), mode: .finite,
            expectedSampleCount: source.sampleCount)
        var output: ScheduledFrame?
        func capture(_ frame: ScheduledFrame) {
            if case .levels(let level) = frame.value, level.source.startSample == 128_640 {
                output = frame
            }
        }
        _ = try Array(repeating: 0.2, count: Int(source.sampleCount)).withUnsafeBufferPointer {
            try schedule.processInterleaved($0, interval: source, emit: capture)
        }
        _ = try schedule.finish(emit: capture)
        let frame = try #require(output)
        let rms = try AcousticMetricObservation(VisualizationMeasurement(frame, metric: .rms))
        let energy = try AcousticMetricObservation(
            VisualizationMeasurement(frame, metric: .kWeightedEnergy))
        #expect(
            rms.dependency == rms.observationWindow && rms.dependency.startSample == start + 128_640
        )
        #expect(
            energy.dependency.startSample == start
                && energy.observationWindow == rms.observationWindow)
        #expect(
            rms.measurement.scheduled?.dependencyTiming
                == energy.measurement.scheduled?.dependencyTiming)
        let plot = try AcousticPlotData(
            metric: rms.measurement.id.series, observations: [rms],
            axis: .init(origin: origin))
        #expect(plot.cursor(for: .init(column: 0, bin: 0))?.source.startSample == start + 128_840)
    }

    @MainActor @Test func consecutiveImageCellsShareBoundaryAndHonorInitialInspection() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let plot = try AcousticPlotData(
            spectrogram: f.spectralFrames, layout: f.spectralLayout, axis: f.axis)
        let boundary = 816.0 / 16000
        #expect(
            plot.imageCell(at: 3)?.upperBound == boundary
                && plot.imageCell(at: 4)?.lowerBound == boundary)
        let cursor = try #require(plot.cursor(atSeconds: boundary))
        #expect(plot.inspect(cursor)?.column == 4)
        let first = AcousticPlotIndex(column: 0, bin: 4)
        #expect(
            AcousticPlotView(plot, selection: .constant(nil), initialInspection: first).active
                == first)
        #expect(
            AcousticPlotView(plot, selection: .constant(nil)).active?.column == plot.columns.count
                - 1)
    }

    @Test func directTapSelectsMissingLaneAndDragRoundsOuterEndpoints() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let wave = try f.waveform()
        let rate = f.source.sampleRate
        for (a, b) in [(2.9, 3.9), (3.9, 2.9), (2.0, 4.0)] {
            let selected = try #require(wave.selection(fromSeconds: a / rate, toSeconds: b / rate))
            #expect(
                selected.source.startSample == f.source.startSample + 2
                    && selected.source.sampleCount == 2)
        }
        let exact = try #require(wave.selection(fromSeconds: 3 / rate, toSeconds: 2 / rate))
        #expect(exact.source.sampleCount == 1)
        let values = try [
            visualizationResult(start: 100, outcome: .available(.init(value: 0))),
            visualizationResult(start: 100, outcome: .unavailable(.missingAcquisition)),
        ].map(AcousticMetricObservation.init)
        let plot = try AcousticPlotData(
            metric: values[0].measurement.id.series, observations: values,
            axis: .init(origin: visualizationSource(100, 0)))
        let cursor = try #require(plot.cursor(for: .init(column: 0, bin: 0)))
        let geometry = AcousticPlotVerticalGeometry(scale: .init(bounds: -1...1), viewHeight: 154)
        for value: Double? in [0, nil] {
            let match = try #require(
                plot.scalarIndex(
                    for: cursor, center: plot.centers[0],
                    tap: (geometry.y(value), geometry)))
            #expect(plot.columns[match.column].value(at: 0) == value)
        }
    }

}
