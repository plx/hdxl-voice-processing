import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingVisualization

@Suite struct AcousticPlotFamilyTests {
    static let extended = Result {
        try AcousticPlotFamilyFixtures(AcousticPlotPrimaryTests.fixture.get())
    }

    @Test func spectralUnitsSilenceAndIndependentHeatmapColumns() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let index = try #require(f.spectralFrames.firstIndex { $0.info.status == .noEnergy })
        for mode in [
            SpectrumPresentation.binPower, .binRMSAmplitude, .powerDensityPerHertz,
            .decibels(referencePower: 0.25),
        ] {
            let heat = try AcousticPlotData(
                spectrogram: f.spectralFrames, layout: f.spectralLayout, axis: f.axis,
                presentation: mode)
            #expect(heat.unit == mode.unit && heat.rawUnit == .normalizedSquaredAmplitude)
            for (i, frame) in f.spectralFrames.enumerated() {
                for bin in [0, 4, heat.binCount - 1] {
                    let expected = frame.value(at: bin, presentation: mode)
                    #expect(heat.columns[i].value(at: bin) == expected.estimate?.value)
                    #expect(
                        heat.columns[i].rawValue(at: bin)
                            == (frame.binPower.isEmpty ? nil : frame.binPower[bin]))
                }
            }
            #expect(heat.columns[index].rawValue(at: 0) == 0)
            if case .decibels = mode {
                #expect(heat.columns[index].reason(at: 0) == .silence)
                #expect(heat.intensities[index].image == nil)
            } else {
                #expect(heat.columns[index].value(at: 0) == 0)
            }
        }
        let cep = try AcousticPlotData(
            cepstrogram: f.cepstralFrames, configuration: f.cepstralRecipe, axis: f.axis)
        for (i, frame) in f.cepstralFrames.enumerated() {
            #expect(
                cep.centers[i] == frame.context.centerSecondsFromOrigin
                    && cep.columns[i].dependency == frame.context.timing.source)
            #expect(cep.binStep == frame.quefrencyStepSeconds && cep.unit == frame.unit)
            #expect(cep.columns[i].rawValue(at: 1) == frame.values[1])
        }
        let gap = try AcousticPlotData(
            spectrogram: [f.spectralFrames[0], f.spectralFrames[4]], layout: f.spectralLayout,
            axis: f.axis)
        let missing = try #require(gap.cursor(atSeconds: (gap.centers[0] + gap.centers[1]) / 2))
        #expect(gap.inspect(missing) == nil)
    }

    @Test func harmonicFormantAndSpectralOverlaysUseMeasuredCoordinates() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let extra = try Self.extended.get()
        #expect(extra.harmonics.failure == nil && extra.harmonics.raw.failure == nil)
        let plots = try extra.plots(f)
        let spectrum = plots[1]
        #expect(
            spectrum.markers.filter { $0.kind == .harmonic }.map(\.coordinate)
                == [extra.harmonics.raw.first, extra.harmonics.raw.second].compactMap {
                    $0?.frequencyHz
                })
        #expect(
            spectrum.markers.filter { $0.kind == .formant }.map(\.coordinate)
                == extra.formants.candidates.filter(\.isCredible).compactMap(\.frequencyHz))
        #expect(spectrum.markers.filter { $0.kind == .spectralMeasure }.count == 2)
        #expect(
            plots[4].columns[0].value(at: 0)
                == extra.harmonics.raw.measurement.outcome.estimate?.value)
        #expect(
            plots[5].columns[0].value(at: 0) == extra.harmonics.measurement.outcome.estimate?.value)
        for n in [1, 2, 3] {
            for kind in [MeasurementKind.formantFrequency, .formantBandwidth] {
                let point = try AcousticMetricObservation(extra.formants, number: n, kind: kind)
                let expected = try extra.formants.measurement(number: n, kind: kind)
                #expect(
                    point.measurement.result == expected.result
                        && point.dependency == expected.conditioningSupport)
            }
        }
        for descriptor in SpectralShapeDescriptor.allCases {
            let observation = try AcousticMetricObservation(extra.shape, descriptor: descriptor)
            let point = try #require(observation)
            #expect(point.measurement.result == (try extra.shape.measurement(descriptor)))
            #expect(point.context.contains("Analysis band · 0.0–8000.0 Hz · DC included"))
            switch descriptor {
            case .rollOff: #expect(point.context.contains("Cumulative weight fraction · 0.85"))
            case .bandEnergyRatio:
                #expect(point.context.contains("Band ratio · low-over-high v1"))
                #expect(point.context.contains("Numerator · 0.0–1000.0 Hz"))
                #expect(point.context.contains("Denominator · 1000.0–8000.0 Hz"))
            case .slope: #expect(point.context.contains("Fit coordinate · Octaves from 1 Hz"))
            default: break
            }
        }
        #expect(throws: VisualizationError.incompatibleSource) {
            try AcousticPlotData(
                spectrum: f.spectralFrames.last!, axis: f.axis, harmonics: extra.harmonics.raw)
        }
    }

    @Test func pulseAndPerturbationViewsRetainEligibilityAndFractionalQueryCoordinates() throws {
        let f = try AcousticPlotPrimaryTests.fixture.get()
        let extra = try Self.extended.get()
        let pulse = try f.waveform(pulses: extra.pulses)
        let visible = extra.pulses.landmarks.filter {
            (0..<f.source.durationSeconds).contains($0.timeSeconds)
        }
        #expect(pulse.markers.count == visible.count && !visible.isEmpty)
        #expect(extra.pulses.landmarks.contains { $0.timeSeconds < 0 && !$0.isEligible })
        for (mark, landmark) in zip(pulse.markers, visible) {
            #expect(mark.coordinate == landmark.timeSeconds)
            #expect(mark.kind == (landmark.isEligible ? .eligiblePulse : .rejectedPulse))
            #expect(mark.profile == extra.pulses.result.profile)
        }
        let tracked = AcousticPerturbationContext.jitter(
            extra.jitter[0].query, extra.jitter[0].coverage,
            extra.jitter[0].applicability, .init(pulseResult: extra.pulses.result))
        #expect(tracked.provenanceText.contains("Input · Acoustic pulse track"))
        for identity in [extra.pulses.result.profile, extra.pulses.result.f0ContourIdentity] {
            #expect(tracked.provenanceText.contains { $0.contains(identity.sha256) })
        }
        for variant in JitterVariant.allCases {
            let points = try extra.jitter.map {
                try AcousticMetricObservation($0, variant: variant)
            }
            let plot = try AcousticPlotData(
                metric: points[0].measurement.id.series, observations: points,
                axis: extra.perturbationAxis)
            for (i, result) in extra.jitter.enumerated() {
                #expect(plot.columns[i].value(at: 0) == result.estimate(variant).value)
                #expect(
                    points[i].perturbation
                        == .jitter(
                            result.query, result.coverage, result.applicability,
                            result.inputProvenance))
                #expect(plot.unit == variant.unit && plot.centers[i] == result.query.centerSeconds)
                #expect(points[i].context.contains { $0.contains("Eligible period pairs") })
                #expect(points[i].context.contains("Input · Supplied periods"))
            }
            for seconds in [0.22, 0.29] {
                let hole = try #require(plot.cursor(atSeconds: seconds))
                #expect(plot.inspect(hole) == nil)
            }
            #expect(plot.columns[2].unavailability != nil)
        }
        for variant in ShimmerVariant.allCases {
            let points = try extra.shimmer.map {
                try AcousticMetricObservation($0, variant: variant)
            }
            let plot = try AcousticPlotData(
                metric: points[0].measurement.id.series, observations: points,
                axis: extra.perturbationAxis)
            for (i, result) in extra.shimmer.enumerated() {
                #expect(plot.columns[i].value(at: 0) == result.estimate(variant).value)
                #expect(
                    points[i].perturbation
                        == .shimmer(
                            result.query, result.coverage, result.applicability,
                            result.inputProvenance))
                #expect(plot.unit == variant.unit && plot.centers[i] == result.query.centerSeconds)
                #expect(points[i].context.contains { $0.contains("Eligible amplitude pairs") })
                #expect(points[i].context.contains("Input · Supplied amplitudes"))
            }
            for seconds in [0.22, 0.29] {
                let hole = try #require(plot.cursor(atSeconds: seconds))
                #expect(plot.inspect(hole) == nil)
            }
            #expect(plot.columns[2].unavailability != nil)
        }
    }
}
