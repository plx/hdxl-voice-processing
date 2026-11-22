import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Suite struct SpectralShapeTests {
    let source = SpectralProductTests()

    func profile(
        source kind: SpectralShapeSource = .frame,
        weighting: SpectralShapeWeighting = .power, analysis: ClosedRange<Double> = 0...512,
        numerator: ClosedRange<Double> = 0...128, denominator: ClosedRange<Double> = 128...512,
        fit: ClosedRange<Double> = 16...512, dc: Bool = true, floor: Double? = nil,
        fraction: Double = 0.85, coordinate: SpectralSlopeCoordinate = .octavesFromOneHertz,
        regression: SpectralRegressionWeighting = .uniform, minimumFitBins: Int = 3,
        name: String = "below-over-above-128"
    ) throws -> SpectralShapeProfile {
        func band(_ limits: ClosedRange<Double>) throws -> SpectralFrequencyBand {
            try .init(lowerHz: limits.lowerBound, upperHz: limits.upperBound)
        }
        return try .init(
            source: kind, weighting: weighting, analysisBand: band(analysis), includeDC: dc,
            relativeLogFloorDB: floor, rollOffFraction: fraction,
            bandRatio: .init(
                name: VersionedIdentifier(name: name, version: 1),
                numerator: band(numerator), denominator: band(denominator)),
            fitBand: band(fit), fitCoordinate: coordinate, regressionWeighting: regression,
            minimumFitBins: minimumFitBins)
    }

    func row(_ powers: [Double], layout: SpectrogramLayout? = nil) throws -> SpectrogramFrame {
        let layout = try layout ?? source.layout()
        #expect(powers.count == layout.frequency.count)
        let info = try SpectralFrameInfo(
            epochStartSample: 0, frameIndex: 0, source: source.source(0, 64),
            selectionProfile: nil, status: powers.contains { $0 > 0 } ? .measured : .noEnergy,
            newlyCoveredSamples: 64, weight: 1)
        let raw = SpectrogramFrame(layout: layout, info: info, binPower: powers)
        return try JSONDecoder().decode(SpectrogramFrame.self, from: JSONEncoder().encode(raw))
    }

    func verify(
        _ outcome: MeasurementOutcome?, _ value: Double, tolerance: Double = 1e-10,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let actual = try #require(outcome?.estimate?.value, sourceLocation: sourceLocation)
        #expect(
            abs(actual - value) <= tolerance, "observed \(actual), expected \(value)",
            sourceLocation: sourceLocation)
    }

    func tone(_ k: Int, _ amplitude: Double = 1) -> [Double] {
        (0..<64).map { amplitude * sin(2 * .pi * Double(k * $0) / 64) }
    }

    @Test func singleAndTwoTonePCMInBothWeightings() throws {
        let layout = try source.layout()
        let one = try source.analyze(tone(4), layout).0[0]
        let two = try source.analyze(zip(tone(4, 0.5), tone(12, 0.25)).map(+), layout).0[0]
        for weighting in [SpectralShapeWeighting.power, .binRMSMagnitude] {
            let worker = try PreparedSpectralShape(
                layout: layout, configuration: profile(weighting: weighting))
            let single = try worker.evaluate(one)
            try verify(single.centroid?.outcome, 64)
            try verify(single.spread?.outcome, 0, tolerance: weighting == .power ? 1e-9 : 3e-5)
            try verify(single.rollOff?.outcome, 64)
            let both = try worker.evaluate(two)
            let low = weighting == .power ? 4.0 : 2
            try verify(both.centroid?.outcome, (64 * low + 192) / (1 + low))
            try verify(both.spread?.outcome, 128 * sqrt(low) / (1 + low))
            try verify(both.rollOff?.outcome, 192)
            try verify(both.bandEnergyRatio?.outcome, 10 * log10(4))
            try verify(both.bandEnergies?.numerator, 0.125)
            try verify(both.bandEnergies?.denominator, 0.03125)
            for descriptor in SpectralShapeDescriptor.allCases {
                let separate = try worker.evaluate(two, only: descriptor)
                #expect(separate[descriptor] == both[descriptor])
                #expect(
                    SpectralShapeDescriptor.allCases.filter { separate[$0] != nil } == [descriptor])
                let measurement = try #require(try both.measurement(descriptor))
                #expect(
                    measurement.profile == worker.identity
                        && measurement.timing.source == two.info.source)
                #expect(
                    try JSONDecoder().decode(
                        MeasurementResult.self, from: measurement.canonicalJSON()) == measurement)
            }
        }
    }

    @Test func flatPowerLawAndGainInvariance() throws {
        let flat = try row(Array(repeating: 0.25, count: 33))
        let worker = try PreparedSpectralShape(layout: flat.layout, configuration: profile())
        let equal = try worker.evaluate(flat)
        try verify(equal.centroid?.outcome, 256)
        try verify(equal.spread?.outcome, 16 * sqrt((33.0 * 33 - 1) / 12))
        try verify(equal.flatness?.outcome, 1)
        try verify(equal.rollOff?.outcome, 448)
        try verify(equal.slope?.outcome, 0)
        #expect(equal.fit?.rSquared == nil && equal.fit?.residualRMSDB == 0)
        let powers = (0..<33).map { $0 == 0 ? 0.0 : 1.0 / Double($0 * $0) }
        for weighting in [SpectralShapeWeighting.power, .binRMSMagnitude] {
            for regression in [SpectralRegressionWeighting.uniform, .shapeWeight] {
                let configured = try PreparedSpectralShape(
                    layout: flat.layout,
                    configuration: profile(weighting: weighting, dc: false, regression: regression))
                let a = try configured.evaluate(row(powers))
                let b = try configured.evaluate(row(powers.map { 9 * $0 }))
                for descriptor in SpectralShapeDescriptor.allCases {
                    try verify(
                        b[descriptor]?.outcome, try #require(a[descriptor]?.outcome.estimate).value)
                }
                try verify(
                    b.bandEnergies?.numerator,
                    9 * (try #require(a.bandEnergies?.numerator.estimate)).value)
                try verify(
                    b.bandEnergies?.denominator,
                    9 * (try #require(a.bandEnergies?.denominator.estimate)).value)
                try verify(a.slope?.outcome, -20 * log10(2))
                #expect(a.fit?.firstFrequencyHz == 16 && a.fit?.lastFrequencyHz == 512)
                #expect(
                    a.fit?.usedBins == 32 && a.fit?.candidateBins == 32 && a.fit?.flooredBins == 0)
                #expect(try #require(a.fit?.residualRMSDB) < 1e-12)
                #expect(a.fit?.rSquared == 1)
            }
        }
    }

    @Test func fractionalCellsDCAndNyquist() throws {
        var values = [Double](repeating: 0, count: 33)
        values[0] = 1
        values[8] = 4
        values[32] = 2
        let input = try row(values)
        func bands(_ left: ClosedRange<Double>, _ right: ClosedRange<Double>, dc: Bool = true)
            throws -> SpectralShapeResult
        {
            let p = try profile(numerator: left, denominator: right, dc: dc)
            return try PreparedSpectralShape(layout: input.layout, configuration: p).evaluate(input)
        }
        let pair = try bands(0...128, 128...512)
        try verify(pair.bandEnergies?.numerator, 3)
        try verify(pair.bandEnergies?.denominator, 4)
        let halves = try bands(0...4, 508...512)
        try verify(halves.bandEnergies?.numerator, 0.5)
        try verify(halves.bandEnergies?.denominator, 1)
        let partial = try bands(120...124, 124...136)
        try verify(partial.bandEnergies?.numerator, 1)
        try verify(partial.bandEnergies?.denominator, 3)
        let exclude = try bands(0...4, 508...512, dc: false)
        #expect(exclude.bandEnergies?.numerator == .unavailable(.insufficientData))
        #expect(exclude.bandEnergyRatio?.outcome == .unavailable(.insufficientData))
    }

    @Test func logFloorZeroDenominatorFitEligibilityAndHzSlope() throws {
        var powers = [Double](repeating: 0, count: 33)
        powers[2] = 1
        powers[3] = 0.01
        let input = try row(powers)
        func run(_ floor: Double?, regression: SpectralRegressionWeighting = .uniform) throws
            -> SpectralShapeResult
        {
            let p = try profile(
                analysis: 16...80, numerator: 24...56, denominator: 56...72,
                fit: 16...80, floor: floor, coordinate: .hertz, regression: regression)
            return try PreparedSpectralShape(layout: input.layout, configuration: p).evaluate(input)
        }
        let raw = try run(nil)
        try verify(raw.flatness?.outcome, 0)
        try verify(raw.bandEnergies?.denominator, 0)
        #expect(raw.bandEnergyRatio?.outcome == .unavailable(.silence))
        #expect(raw.slope?.outcome == .unavailable(.insufficientData) && raw.fit?.usedBins == 2)
        let floor = try run(-10)
        try verify(floor.flatness?.outcome, pow(0.1, 4.0 / 5) / (1.4 / 5))
        try verify(floor.slope?.outcome, -0.0625)
        #expect(floor.fit?.usedBins == 5 && floor.fit?.flooredBins == 4)
        #expect(try #require(floor.fit?.residualRMSDB) > 0)
        let weighted = try run(-10, regression: .shapeWeight)
        #expect(weighted.fit?.usedBins == 2 && weighted.fit?.flooredBins == 1)
        let line = try row((0..<33).map { pow(10, (Double($0) * 16 * -0.002 - 3) / 10) })
        let fit = try PreparedSpectralShape(
            layout: line.layout, configuration: profile(fit: 0...512, coordinate: .hertz)
        ).evaluate(line)
        try verify(fit.slope?.outcome, -0.002)
        #expect(fit.fit?.usedBins == 33 && fit.fit?.firstFrequencyHz == 0 && fit.fit?.rSquared == 1)
    }
}

extension SpectralShapeTests {
    @Test func sourceTimingLTASAndEvaluationOrder() throws {
        let layout = try source.layout()
        let pcm = tone(4) + tone(12, 0.25) + [0, 0, 0]
        let (rows, mean) = try source.analyze(pcm, layout)
        let frames = try PreparedSpectralShape(layout: layout, configuration: profile())
        let aggregate = try PreparedSpectralShape(
            layout: layout, configuration: profile(source: .longTermSpectrum))
        let first = try frames.evaluate(rows[0])
        let second = try frames.evaluate(rows[1])
        let tail = try frames.evaluate(rows[2])
        let averaged = try aggregate.evaluate(mean)
        #expect(first.origin == .frame(rows[0].info))
        #expect(
            averaged.origin
                == .longTerm(timing: mean.timing, selection: nil, status: .measured, totalWeight: 2)
        )
        #expect(
            averaged.timing == mean.timing && averaged.selectionCoverage == mean.selectionCoverage)
        try verify(first.centroid?.outcome, 64)
        try verify(second.centroid?.outcome, 192)
        try verify(averaged.centroid?.outcome, (16.0 * 64 + 192) / 17)
        #expect(averaged.profile != first.profile && averaged.warnings == [.partialCoverage])
        #expect(
            try averaged.measurement(.centroid)?.outcome.estimate?.warnings == [.partialCoverage])
        for d in SpectralShapeDescriptor.allCases {
            #expect(tail[d]?.outcome == .unavailable(.insufficientData))
        }
        #expect(tail.timing.includedSampleCount == 0 && tail.timing.source.sampleCount == 3)
        #expect(throws: ContractError.invalidConfiguration) { try frames.evaluate(mean) }
        #expect(throws: ContractError.invalidConfiguration) { try aggregate.evaluate(rows[0]) }
        let other = try source.analyze(tone(4), source.layout(window: .hannPeriodic)).0[0]
        #expect(throws: ContractError.invalidFingerprint) { try frames.evaluate(other) }
    }

    @Test func insufficientUnsupportedSilentAndExcluded() throws {
        let limited = try source.layout(bandwidth: 143)
        let input = try row([Double](repeating: 1, count: 9), layout: limited)
        let shape = try PreparedSpectralShape(layout: limited, configuration: profile(fit: 1...7))
        let result = try shape.evaluate(input)
        #expect(result.centroid?.outcome == .unavailable(.unsupportedRange))
        #expect(result.bandEnergies?.denominator == .unavailable(.unsupportedRange))
        #expect(result.bandEnergies?.numerator.estimate != nil)
        #expect(
            result.slope?.outcome == .unavailable(.insufficientData)
                && result.fit?.candidateBins == 0)
        let edge = try PreparedSpectralShape(
            layout: limited,
            configuration: profile(
                analysis: 0...143,
                numerator: 128...143, denominator: 0...8, fit: 16...128)
        ).evaluate(input)
        #expect(
            edge.centroid?.outcome.estimate != nil
                && edge.bandEnergies?.numerator == .unavailable(.unsupportedRange))
        let layout = try source.layout()
        let frames = try PreparedSpectralShape(layout: layout, configuration: profile())
        let zero = try frames.evaluate(row(Array(repeating: 0, count: 33)))
        for d in SpectralShapeDescriptor.allCases {
            #expect(zero[d]?.outcome == .unavailable(.silence))
        }
        try verify(zero.bandEnergies?.numerator, 0)
        try verify(zero.bandEnergies?.denominator, 0)
        let mask = try MaskTimeline(
            MaskPlan(
                source: source.source(0, 128),
                provenances: [
                    MaskProvenance(
                        kind: .externalAnnotation,
                        identifier: VersionedIdentifier(name: "shape-selection", version: 1))
                ], policy: MaskSelectionPolicy(rejectedTags: [.nonSpeechDetected]),
                observations: [
                    MaskObservation(
                        source: source.source(0, 3), provenanceIndex: 0, tags: [.nonSpeechDetected]),
                    MaskObservation(
                        source: source.source(74, 3), provenanceIndex: 0,
                        tags: [.missingAcquisition]),
                ]))
        let (masked, mean) = try source.analyze(tone(4) + tone(12), layout, mask: mask)
        for (row, reason) in zip(masked, [UnavailabilityReason.excluded, .missingAcquisition]) {
            let out = try frames.evaluate(row)
            #expect(out.origin == .frame(row.info) && row.info.selectionProfile != nil)
            for d in SpectralShapeDescriptor.allCases {
                #expect(out[d]?.outcome == .unavailable(reason))
            }
            #expect(out.bandEnergies?.numerator == .unavailable(reason) && out.fit?.usedBins == 0)
        }
        let snapshot = try PreparedSpectralShape(
            layout: layout, configuration: profile(source: .longTermSpectrum)
        ).evaluate(mean)
        #expect(
            snapshot.selectionCoverage?.excludedSamples == 3
                && snapshot.selectionCoverage?.missingSamples == 3)
        #expect(snapshot.centroid?.outcome == .unavailable(.missingAcquisition))
    }

    @Test func liveFloatRowsMatchReplayAndSettingsHaveDistinctIdentities() throws {
        let layout = try source.layout(precision: .float32)
        let pcm = tone(4).map(Float.init) + [0, 0]
        let settings = try profile()
        let worker = try PreparedSpectralShape(layout: layout, configuration: settings)
        let fft = try PreparedSpectrogram<Float>(layout: layout, epoch: source.epoch)
        var results: [SpectralShapeResult] = []
        let emit: (BorrowedSpectrogramFrame<Float>) -> Void = { row in
            do {
                let live = try worker.evaluate(row)
                let owned = try worker.evaluate(row.owned())
                #expect(live == owned)
                results.append(live)
            } catch { Issue.record(error) }
        }
        _ = try pcm.withUnsafeBufferPointer {
            try fft.process($0, interval: source.source(0, pcm.count), emit: emit)
        }
        _ = try fft.finish(emit: emit)
        #expect(
            results.count == 2 && results.last?.centroid?.outcome == .unavailable(.insufficientData)
        )
        try verify(results.first?.centroid?.outcome, 64, tolerance: 1e-4)
        let variants = try [
            settings, profile(source: .longTermSpectrum), profile(weighting: .binRMSMagnitude),
            profile(dc: false), profile(floor: -60), profile(fraction: 0.90),
            profile(fit: 64...384),
            profile(regression: .shapeWeight), profile(coordinate: .hertz),
            profile(minimumFitBins: 5),
            profile(name: "custom-ratio"), profile(numerator: 0...160),
            profile(denominator: 160...512),
            profile(analysis: 0...513),
        ]
        #expect(try Set(variants.map { try $0.identity(for: layout) }).count == variants.count)
        #expect(try variants[2].identity(for: layout).identifier != worker.identity.identifier)
        #expect(
            try JSONDecoder().decode(
                SpectralShapeProfile.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(throws: ContractError.invalidConfiguration) { try profile(fraction: 0) }
        #expect(throws: ContractError.invalidConfiguration) { try profile(floor: 1) }
        #expect(throws: ContractError.invalidConfiguration) { try profile(minimumFitBins: 1) }
        #expect(throws: ContractError.invalidConfiguration) { try profile(analysis: 0...256) }
    }

    @Test func fixedPulseTrainThroughTwoResonantFilters() throws {
        let layout = try source.layout()
        let worker = try PreparedSpectralShape(layout: layout, configuration: profile(dc: false))
        // Same 32 Hz periodic excitation. A conjugate pole pair changes only the filter resonance.
        func filtered(resonance: Double) throws -> SpectralShapeResult {
            let radius = 0.95
            let feedback = 2 * radius * cos(2 * .pi * resonance / 1024)
            var previous = 0.0
            var earlier = 0.0
            let signal = (0..<1024).map { i in
                let sample =
                    (i.isMultiple(of: 32) ? 0.01 : 0) + feedback * previous - radius * radius
                    * earlier
                earlier = previous
                previous = sample
                return sample
            }
            return try worker.evaluate(try #require(try source.analyze(signal, layout).0.last))
        }
        let low = try filtered(resonance: 96)
        let high = try filtered(resonance: 288)
        let lowCentroid = try #require(low.centroid?.outcome.estimate?.value)
        let highCentroid = try #require(high.centroid?.outcome.estimate?.value)
        #expect(abs(lowCentroid - 96) < 16 && abs(highCentroid - 288) < 16)
        #expect(try #require(low.bandEnergyRatio?.outcome.estimate?.value) > 0)
        #expect(try #require(high.bandEnergyRatio?.outcome.estimate?.value) < 0)
    }
}

extension SpectralShapeTests {
    @Test func extremePowerContrastAndNarrowEnergyCell() throws {
        var powers = Array(repeating: 0.0, count: 33)
        powers[0] = 1e300
        powers[1] = 1e-300
        let input = try row(powers)
        let configuration = try profile(
            numerator: 0...Double.leastNonzeroMagnitude, denominator: 0...4,
            fraction: 1)
        let result = try PreparedSpectralShape(layout: input.layout, configuration: configuration)
            .evaluate(input)
        let spread = try #require(result.spread?.outcome.estimate?.value)
        #expect(abs(spread / 1.6e-299 - 1) < 1e-12)
        #expect(result.centroid?.outcome == .unavailable(.analysisFailure))
        try verify(result.rollOff?.outcome, 16)
        let tiny = try #require(result.bandEnergies?.numerator.estimate?.value)
        #expect(abs(tiny / (Double.leastNonzeroMagnitude * 1e300 / 8) - 1) < 1e-12)
        try verify(
            result.bandEnergyRatio?.outcome, 10 * (log10(Double.leastNonzeroMagnitude) - log10(4)))
    }
}

extension SpectralShapeTests {
    @Test func rollOffHonorsExactAndAdjacentFractions() throws {
        for weighting in [SpectralShapeWeighting.power, .binRMSMagnitude] {
            var powers = [Double](repeating: 0, count: 33)
            for (k, w) in [(1, 1.0), (4, 5.0), (22, 2.0)] {
                powers[k] = weighting == .power ? w : w * w
            }
            let frame = try row(powers)
            for (fraction, bin) in [(0.75.nextDown, 4), (0.75, 4), (0.75.nextUp, 22)] {
                let worker = try PreparedSpectralShape(
                    layout: frame.layout,
                    configuration: profile(weighting: weighting, fraction: fraction))
                try verify(worker.evaluate(frame).rollOff?.outcome, Double(bin) * 16)
            }
        }
    }

    @Test func rollOffSeesSubULPTailsAndThresholds() throws {
        var powers = [Double](repeating: 0, count: 33)
        powers[1] = 1
        powers[8] = 1
        powers[10] = Double(sign: .plus, exponent: -60, significand: 1)
        let input = try row(powers)
        let worker = try PreparedSpectralShape(
            layout: input.layout, configuration: profile(fraction: 0.5))
        try verify(worker.evaluate(input).rollOff?.outcome, 128)
        // Even an individually unrepresentable half-unit threshold must reach its first positive bin.
        powers = [Double](repeating: 0, count: 33)
        powers[7] = Double.leastNonzeroMagnitude
        try verify(worker.evaluate(row(powers)).rollOff?.outcome, 112)
        // A tiny fraction of a huge total can itself have an ordinary, representable cutoff.
        powers[7] = 1e-30
        powers[11] = 1
        powers[30] = Double.greatestFiniteMagnitude
        let smallest = try PreparedSpectralShape(
            layout: input.layout, configuration: profile(fraction: Double.leastNonzeroMagnitude))
        try verify(smallest.evaluate(row(powers)).rollOff?.outcome, 176)
    }

    @Test func weightedFitAcrossHundredsOfDecades() throws {
        var powers = [Double](repeating: 0, count: 33)
        powers[2] = 1e200
        powers[4] = 1e-200
        let frame = try row(powers)
        let worker = try PreparedSpectralShape(
            layout: frame.layout,
            configuration: profile(regression: .shapeWeight, minimumFitBins: 2))
        let result = try worker.evaluate(frame)
        try verify(result.slope?.outcome, -4000)
        #expect(
            result.fit?.usedBins == 2 && result.fit?.firstFrequencyHz == 32
                && result.fit?.lastFrequencyHz == 64)
        #expect(result.fit?.rSquared == 1 && result.fit?.residualRMSDB == 0)
        powers[8] = 1e-200
        let third = try worker.evaluate(row(powers))
        // The two small observations have equal weight. Centered at the dominant bin their
        // displacements are one and two octaves, and their level changes are both -4000 dB.
        try verify(third.slope?.outcome, -2400)
        #expect(third.fit?.usedBins == 3)
        let observed = try #require(third.fit?.residualRMSDB)
        #expect(abs(observed / (sqrt(1600.0 * 1600 + 800 * 800) * 1e-200) - 1) < 1e-12)
        try verify(.available(ScalarEstimate(value: try #require(third.fit?.rSquared))), 0.9)
    }

    @Test func scalarExportBindsMasksAcrossWorkerReuse() throws {
        let layout = try source.layout()
        let geometry = try profile(source: .longTermSpectrum)
        let aggregate = try PreparedSpectralShape(layout: layout, configuration: geometry)
        let frames = try PreparedSpectralShape(layout: layout, configuration: profile())
        var ids: [ProfileIdentity] = []
        for offset in [0, 64, 0] {
            let plan = try MaskPlan(
                source: source.source(0, 128),
                provenances: [
                    MaskProvenance(
                        kind: .externalAnnotation,
                        identifier: VersionedIdentifier(name: "mask", version: 1))
                ], policy: MaskSelectionPolicy(rejectedTags: [.nonSpeechDetected]),
                observations: [
                    MaskObservation(
                        source: source.source(offset, 64), provenanceIndex: 0,
                        tags: [.nonSpeechDetected])
                ])
            let (columns, mean) = try source.analyze(
                tone(4) + tone(12), layout, mask: MaskTimeline(plan))
            let result = try aggregate.evaluate(mean)
            let exported = try #require(try result.measurement(.centroid))
            let selection = try #require(mean.selectionProfile)
            let expected = try geometry.identity(for: layout, selectionProfile: selection)
            #expect(exported.profile == result.profile && exported.profile == expected)
            #expect(exported.timing.includedSampleCount == 64)
            ids.append(exported.profile)
            for column in columns {
                let frame = try frames.evaluate(column)
                #expect(
                    frame.profile
                        == (try frame.configuration.identity(
                            for: layout, selectionProfile: selection)))
                #expect(try frame.measurement(.rollOff)?.profile == frame.profile)
            }
        }
        #expect(ids[0] != ids[1] && ids[0] == ids[2] && ids[0] != aggregate.identity)
    }

    @Test func aggregateCountsAndSampledSnapshotSequence() throws {
        let layout = try source.layout(weighting: .newlyCoveredSamples)
        let (frames, mean) = try source.analyze(
            tone(4) + Array(repeating: Double.greatestFiniteMagnitude, count: 64), layout)
        #expect(frames.count == 2 && mean.status == .measured && mean.totalWeight == 64)
        let sink = RecordingSink()
        let worker = try PreparedSpectralShape(
            layout: layout, configuration: profile(source: .longTermSpectrum),
            diagnostics: WorkerDiagnostics(mode: .sampled, sink: sink))
        for _ in 0..<33 {
            let result = try worker.evaluate(mean)
            #expect(result.aggregateSupport?.measuredFrames == 1)
            #expect(result.aggregateSupport?.unavailableFrames == [.analysisFailure: 1])
        }
        let spans = sink.entries.compactMap { entry -> DiagnosticRecord? in
            if case .begin(let record) = entry, record.stage == .spectralShape { return record }
            return nil
        }
        #expect(spans.map(\.metadata.frameSequence) == [0, 16, 32])
        #expect(
            spans.allSatisfy {
                $0.metadata.elapsedProcessingCount == 1 && $0.metadata.sampleCount == 128
            })
        #expect(
            sink.entries.filter {
                if case .end(let record) = $0 { record.stage == .spectralShape } else { false }
            }.count == 3)
    }
}

extension SpectralShapeTests {
    @Test func literalFourFifthsUsesTheStoredBinaryFraction() throws {
        var powers = [Double](repeating: 0, count: 33)
        powers[4] = 4
        powers[12] = 1
        let frame = try row(powers)
        for (f, hz) in [(0.75, 64.0), (0.8.nextDown, 64), (0.8, 192), (0.85, 192)] {
            let worker = try PreparedSpectralShape(
                layout: frame.layout, configuration: profile(fraction: f))
            try verify(worker.evaluate(frame).rollOff?.outcome, hz)
        }
    }

    @Test func neighboringLevelsKeepTheSignOfSlopeAndRatio() throws {
        for (a, b) in [(0.01, 0.01.nextUp), (0.01.nextUp, 0.01)] {
            var powers = [Double](repeating: 0, count: 33)
            powers[1] = a
            powers[2] = b
            let frame = try row(powers)
            let worker = try PreparedSpectralShape(
                layout: frame.layout,
                configuration: profile(numerator: 8...24, denominator: 24...40, minimumFitBins: 2))
            let answer = try worker.evaluate(frame)
            let expected = 10 * log1p((b - a) / a) / log(10.0)
            let slope = try #require(answer.slope?.outcome.estimate?.value)
            let ratio = try #require(answer.bandEnergyRatio?.outcome.estimate?.value)
            #expect(abs(slope / expected - 1) < 1e-14 && abs(ratio / expected + 1) < 1e-14)
            #expect(answer.fit?.rSquared == 1)
        }
    }

    @Test func weakOutlierStillHasARepresentableFitResidual() throws {
        var powers = [Double](repeating: 0, count: 33)
        powers[1] = Double(sign: .plus, exponent: 200, significand: 1)
        powers[2] = Double(sign: .plus, exponent: 100, significand: 1)
        powers[4] = Double(sign: .plus, exponent: -1000, significand: 1)
        let frame = try row(powers)
        let worker = try PreparedSpectralShape(
            layout: frame.layout, configuration: profile(regression: .shapeWeight))
        let result = try worker.evaluate(frame)
        let residual = try #require(result.fit?.residualRMSDB)
        let expected = 10000 * log10(2.0) * Double(sign: .plus, exponent: -600, significand: 1)
        #expect(abs(residual / expected - 1) < 1e-12)
    }

    @Test func liveFloatDiagnosticScopeEndsBeforeFrameDeliveryReturns() throws {
        let layout = try source.layout(precision: .float32)
        let sink = RecordingSink()
        let worker = try PreparedSpectralShape(
            layout: layout, configuration: profile(),
            diagnostics: WorkerDiagnostics(mode: .detailed, sink: sink))
        let fft = try PreparedSpectrogram<Float>(layout: layout, epoch: source.epoch)
        _ = try tone(4).map(Float.init).withUnsafeBufferPointer {
            try fft.process($0, interval: source.source(0, 64)) { frame in
                do {
                    let value = try worker.evaluate(frame)
                    try verify(value.centroid?.outcome, 64, tolerance: 1e-4)
                    let entries = sink.entries
                    guard case .begin(let begin) = entries[entries.count - 2],
                        case .end(let end) = entries.last
                    else {
                        Issue.record("Expected paired descriptor signposts")
                        return
                    }
                    #expect(
                        begin == end && end.stage == .spectralShape
                            && end.metadata.frameSequence == 0)
                    #expect(end.metadata.sampleCount == 64)
                } catch { Issue.record(error) }
            }
        }
    }
}
