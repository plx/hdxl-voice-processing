import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Suite struct SpectralProductTests {
    let epoch = StreamEpoch(streamID: UUID())

    func layout(
        length: Int = 64, hop: Int = 64, fft: Int = 64, window: WindowDefinition = .rectangular,
        weighting: SpectralWeighting = .equalFrames, bandwidth: Double? = nil,
        precision: AnalysisPrecision = .float64
    ) throws -> SpectrogramLayout {
        try SpectrogramLayout(
            framing: FramingConfiguration(
                window: WindowSpecification(
                    definition: window,
                    sampleCount: length, sampleRate: 1024, precision: precision), hopLength: hop,
                partialWindowPolicy: .emitUnavailable),
            transformLength: fft, channels: PCMChannelSelection(channelIndex: 0),
            bandwidthHz: bandwidth, weighting: weighting)
    }

    func source(_ start: Int, _ count: Int, rate: Double = 1024) throws -> SourceInterval {
        try SourceInterval(
            epoch: epoch, startSample: Int64(start), sampleCount: Int64(count), sampleRate: rate)
    }

    func analyze(
        _ input: [Double], _ layout: SpectrogramLayout, chunk: Int = 67, mask: MaskTimeline? = nil
    )
        throws -> ([SpectrogramFrame], LongTermSpectrum)
    {
        let worker = try PreparedSpectrogram<Double>(layout: layout, epoch: epoch, selection: mask)
        let aggregate = try LongTermSpectrumAccumulator(
            layout: layout, epoch: epoch, selectionProfile: worker.selectionProfile)
        var rows: [SpectrogramFrame] = []
        let emit: (BorrowedSpectrogramFrame<Double>) -> Void = { row in
            rows.append(row.owned())
            do { try aggregate.append(row) } catch { Issue.record(error) }
        }
        try input.withUnsafeBufferPointer { buffer in
            for offset in stride(from: 0, to: input.count, by: chunk) {
                let count = min(chunk, input.count - offset)
                try worker.process(
                    UnsafeBufferPointer(rebasing: buffer[offset..<offset + count]),
                    interval: source(offset, count), emit: emit)
            }
        }
        let completion = try worker.finish(emit: emit)
        return (
            rows, try aggregate.snapshot(observedSource: completion.observedSource, selection: mask)
        )
    }

    @Test func mixtureAndEndpointsObeyOneSidedPowerAndDensity() throws {
        let profile = try layout()
        let pcm: [Double] = (0..<64).map { i in
            let phase = 2 * Double.pi * Double(i) / 64
            let tones = 0.5 * sin(4 * phase) + 0.25 * cos(9 * phase)
            return 0.25 + tones + (i.isMultiple(of: 2) ? 0.125 : -0.125)
        }
        let (rows, average) = try analyze(pcm, profile)
        let row = try #require(rows.first)
        #expect(row.info.status == .measured)
        #expect(average.timing.coverage == 1)
        #expect(profile.frequency.count == 33 && profile.frequency.coordinate(at: 32) == 512)
        #expect(profile.equivalentNoiseBandwidthHz == 16)
        #expect(abs(row.binPower[0] - 0.0625) < 1e-12)
        #expect(abs(row.binPower[4] - 0.125) < 1e-12)
        #expect(abs(row.binPower[9] - 0.03125) < 1e-12)
        #expect(abs(row.binPower[32] - 0.015625) < 1e-12)
        let direct = pcm.reduce(0) { $0 + $1 * $1 } / 64
        #expect(abs(row.binPower.reduce(0, +) - direct) < 1e-12)
        #expect(
            abs(
                (try #require(row.value(at: 4, presentation: .powerDensityPerHertz).estimate)).value
                    * 16 - 0.125) < 1e-12)
        #expect(
            abs(
                (try #require(row.value(at: 4, presentation: .binRMSAmplitude).estimate)).value
                    - sqrt(0.125)) < 1e-12)
    }

    @Test func impulseAndDifferencingFilterMatchTransferFunction() throws {
        let profile = try layout(fft: 128)
        for filtered in [false, true] {
            var input = [Double](repeating: 0, count: 64)
            input[12] = 1
            if filtered { input[13] = -1 }
            let (rows, _) = try analyze(input, profile)
            let powers = rows[0].binPower
            for k in powers.indices {
                let response = filtered ? 4 * pow(sin(.pi * Double(k) / 128), 2) : 1
                let sided = k == 0 || k == 64 ? 1.0 : 2.0
                #expect(abs(powers[k] - sided * response / (128 * 64)) < 1e-14)
            }
        }
        var state: UInt64 = 48271
        let noise = (0..<64).map { _ -> Double in
            state = (state * 48271) % 2_147_483_647
            return Double(state) / 1_073_741_824 - 1
        }
        let row = try analyze(noise, profile).0[0]
        for k in row.binPower.indices {
            var re = 0.0
            var im = 0.0
            for (n, value) in noise.enumerated() {
                let angle = -2 * .pi * Double(n * k) / 128
                re += value * cos(angle)
                im += value * sin(angle)
            }
            let sided = k == 0 || k == 64 ? 1.0 : 2.0
            #expect(abs(row.binPower[k] - sided * (re * re + im * im) / (64 * 128)) < 1e-12)
        }
    }

    @Test func bandwidthWindowLeakagePrecisionAndUnsupportedBins() throws {
        let hann = try layout(window: .hannPeriodic)
        #expect(abs(hann.equivalentNoiseBandwidthHz - 24) < 1e-12)
        let tone = (0..<64).map { sin(2 * .pi * 8.5 * Double($0) / 64) }
        let rectangular = try analyze(tone, layout()).0[0]
        let tapered = try analyze(tone, hann).0[0]
        #expect(tapered.binPower[20] < rectangular.binPower[20] / 100)
        let clipped = try layout(bandwidth: 143, precision: .float32)
        let worker = try PreparedSpectrogram<Float>(layout: clipped, epoch: epoch)
        let row: SpectrogramFrame = try {
            var output: SpectrogramFrame?
            _ = try tone.map(Float.init).withUnsafeBufferPointer {
                try worker.process($0, interval: source(0, 64)) { output = $0.owned() }
            }
            return try #require(output)
        }()
        #expect(row.binPower.count == 9 && row.layout.frequency.coordinate(at: 9) == nil)
        #expect(row.value(at: 9) == .unavailable(.unsupportedRange))
        #expect(abs(row.binPower[8] - rectangular.binPower[8]) < 1e-6)
        #expect(throws: ContractError.invalidConfiguration) { try layout(bandwidth: 513) }
    }

    @Test func linearAveragePrecedesLogarithmsAndDisplaysRetainTheirReferences() throws {
        let (rows, mean) = try analyze(
            Array(repeating: 0.1, count: 64) + Array(repeating: 1.0, count: 64), layout())
        let db = SpectrumPresentation.decibels(referencePower: 1)
        let meanDB = try #require(mean.value(at: 0, presentation: db).estimate).value
        let incorrect =
            try rows.map { try #require($0.value(at: 0, presentation: db).estimate).value }.reduce(
                0, +) / 2
        #expect(abs(meanDB - 10 * log10(0.505)) < 1e-12)
        #expect(abs(incorrect + 10) < 1e-12 && meanDB - incorrect > 6)
        let view = try mean.presented(.decibels(referencePower: 0.25), bins: 0..<34)
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as? [String: Any])
        let setting = try #require(
            (json["presentation"] as? [String: Any])?["decibels"] as? [String: Any])
        #expect(setting["referencePower"] as? Double == 0.25)
        #expect(json["unit"] as? String == "decibelsRatio")
        #expect(view.values[33] == .unavailable(.unsupportedRange))
        #expect(throws: ContractError.invalidConfiguration) {
            try mean.presented(.decibels(referencePower: 0), bins: 0..<1)
        }
    }

    @Test func silenceEmptyShortAndNumericalFailureRemainDistinct() throws {
        let profile = try layout()
        let (empty, emptyAverage) = try analyze([], profile)
        #expect(empty.isEmpty && emptyAverage.status == .unavailable(.insufficientData))
        #expect(emptyAverage.timing.coverage == 0 && emptyAverage.meanBinPower.isEmpty)
        let (silence, average) = try analyze(.init(repeating: 0, count: 68), profile)
        #expect(silence.map(\.info.status) == [.noEnergy, .unavailable(.insufficientData)])
        #expect(silence[0].value(at: 0).estimate?.value == 0)
        #expect(
            silence[0].value(at: 0, presentation: .decibels(referencePower: 1))
                == .unavailable(.silence))
        #expect(silence[1].binPower.isEmpty && silence[1].info.weight == 0)
        #expect(
            average.status == .noEnergy && average.timing.includedSampleCount == 64
                && average.warnings == [.partialCoverage])
        let (overflow, invalid) = try analyze(
            .init(repeating: Double.greatestFiniteMagnitude, count: 64), profile)
        #expect(overflow[0].binPower.isEmpty && invalid.status == .unavailable(.analysisFailure))
        #expect(throws: FramingError.nonfiniteSample) { try analyze([.nan], profile) }
    }
}

extension SpectralProductTests {
    @Test func wholeSupportSelectionCoverageWeightsAndEligibleOnlyReplay() throws {
        let plan = try MaskPlan(
            source: source(0, 34),
            provenances: [
                MaskProvenance(
                    kind: .externalAnnotation,
                    identifier: VersionedIdentifier(name: "selected-vowels", version: 1))
            ], policy: MaskSelectionPolicy(rejectedTags: [.nonSpeechDetected]),
            observations: [
                MaskObservation(
                    source: source(12, 4), provenanceIndex: 0, tags: [.nonSpeechDetected]),
                MaskObservation(
                    source: source(28, 2), provenanceIndex: 0, tags: [.missingAcquisition]),
            ])
        let timeline = try MaskTimeline(plan)
        let pcm = (0..<34).map { Double(($0 / 4) + 1) / 8 }
        for weighting in [SpectralWeighting.equalFrames, .newlyCoveredSamples] {
            let profile = try layout(length: 8, hop: 4, fft: 8, weighting: weighting)
            let (rows, average) = try analyze(pcm, profile, chunk: 1, mask: timeline)
            let (whole, wholeAverage) = try analyze(pcm, profile, chunk: 34, mask: timeline)
            #expect(whole == rows && wholeAverage == average)
            #expect(
                rows.map(\.info.status) == [
                    .measured, .measured, .unavailable(.excluded), .unavailable(.excluded),
                    .measured, .measured, .unavailable(.missingAcquisition),
                    .unavailable(.insufficientData),
                ])
            let eligible = rows.filter(\.info.status.isMeasured)
            #expect(eligible.map(\.info.newlyCoveredSamples) == [8, 4, 8, 4])
            #expect(
                eligible.map(\.info.weight)
                    == (weighting == .equalFrames ? [1, 1, 1, 1] : [8, 4, 8, 4]))
            #expect(
                average.timing.includedSampleCount == 24 && average.timing.source.sampleCount == 34)
            #expect(
                average.unavailableFrames == [
                    .excluded: 2, .missingAcquisition: 1, .insufficientData: 1,
                ])
            #expect(average.selectionCoverage?.selectedSamples == 28)
            #expect(average.selectionCoverage?.missingSamples == 2)
            #expect(average.selectionCoverage?.excludedSamples == 4)
            #expect(average.selectionCoverage?.selectedCoverage == 24.0 / 28)
            let replay = try LongTermSpectrumAccumulator(
                layout: profile, epoch: epoch, selectionProfile: average.selectionProfile)
            for row in eligible {
                let bytes = try JSONEncoder().encode(row)
                try replay.append(JSONDecoder().decode(SpectrogramFrame.self, from: bytes))
            }
            let reproduced = try replay.snapshot(observedSource: source(0, 34))
            #expect(
                reproduced.meanBinPower == average.meanBinPower
                    && reproduced.totalWeight == average.totalWeight)
            for k in average.meanBinPower.indices {
                let total = eligible.reduce(0.0) { $0 + $1.binPower[k] * Double($1.info.weight) }
                #expect(abs(average.meanBinPower[k] - total / Double(average.totalWeight)) < 1e-12)
            }
            #expect(throws: FramingError.unexpectedInterval) { try replay.append(eligible[0]) }
        }
    }

    @Test func excludedOnlyAndStridedCoverageAndRetriedInvalidInput() throws {
        let outside = try MaskTimeline(
            MaskPlan(
                source: source(100, 0), provenances: [], policy: MaskSelectionPolicy(),
                observations: []))
        let (_, excluded) = try analyze(.init(repeating: 1, count: 64), layout(), mask: outside)
        #expect(excluded.status == .unavailable(.excluded) && excluded.totalWeight == 0)
        let profile = try layout(length: 4, hop: 8, fft: 4)
        let (_, average) = try analyze(.init(repeating: 1, count: 20), profile)
        #expect(average.timing.includedSampleCount == 12 && average.measuredFrames == 3)
        let worker = try PreparedSpectrogram<Double>(layout: profile, epoch: epoch, startSample: 42)
        #expect(throws: FramingError.nonfiniteSample) {
            try [1.0, 2, .infinity, 4].withUnsafeBufferPointer {
                try worker.process($0, interval: source(42, 4)) { _ in
                    Issue.record("Invalid emission")
                }
            }
        }
        var rows = 0
        _ = try [1.0, 2, 3, 4].withUnsafeBufferPointer {
            try worker.process($0, interval: source(42, 4)) { row in
                #expect(row.info.frameIndex == 0 && row.info.source.startSample == 42)
                rows += 1
            }
        }
        #expect(rows == 1)
    }

    @Test func boundedRollingRetentionSourceIndependenceAndPeakPreservation() throws {
        let profile = try layout(length: 4, hop: 4, fft: 4)
        let ring = try RollingSpectralProducts(layout: profile, capacity: 4)
        #expect(throws: ContractError.intermediateBudgetExceeded) {
            try RollingSpectralProducts(layout: profile, capacity: 30_001)
        }
        let pcm = (0..<40).map { $0 >= 28 && $0 < 32 ? 1.0 : 0.0 }
        let (rows, _) = try analyze(pcm, profile)
        for row in rows.prefix(4) { try ring.append(row) }
        let old = ring.snapshot()
        for row in rows.dropFirst(4) { try ring.append(row) }
        let latest = ring.snapshot()
        #expect(
            old.columns.map(\.frameIndex) == [0, 1, 2, 3]
                && latest.columns.map(\.frameIndex) == [6, 7, 8, 9])
        #expect(latest.evictedCount == 6 && ring.count == 4)
        #expect(throws: FramingError.unexpectedInterval) { try ring.append(rows[9]) }
        #expect(ring.snapshot() == latest)
        let peak = try latest.displayColumns(framesPerColumn: 4, aggregation: .maximum)[0]
        let mean = try latest.displayColumns(framesPerColumn: 4, aggregation: .arithmeticMean)[0]
        #expect(peak.linearPower[0] == 1 && abs(mean.linearPower[0] - 0.25) < 1e-12)
        #expect(peak.sourceEnvelope == (try source(24, 16)) && peak.availableFrameCount == 4)
        #expect(latest.columns[0].powers[0] == 0 && latest.columns[1].powers[0] == 1)
        #expect(
            try latest.displayColumns(framesPerColumn: Int.max, aggregation: .maximum).count == 1)
        #expect(throws: ContractError.invalidConfiguration) {
            try latest.displayColumns(framesPerColumn: 0, aggregation: .maximum)
        }
    }

    @Test func canonicalCepstralRowsRoundTripIntoRollingProducts() throws {
        let configuration = try CepstrogramConfiguration(
            sourceSampleRate: 16_000, analysisSampleRate: 4000,
            inputPrecision: .float64, pitchFloorHz: 100, hopSeconds: 0.005,
            declaredInputBandwidthHz: 8000,
            conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
        let worker = try PreparedPreviewCepstrogram<Double>(
            configuration: configuration, epoch: epoch)
        let ring = try RollingSpectralProducts(configuration: configuration, capacity: 3)
        let canonical = try BoundedCepstrogram(
            configuration: configuration, maximumFrames: 100, maximumScalarCount: 30_000)
        let export = try PowerCepstrogramExporter(configuration: configuration)
        let signal = (0..<4000).map { 0.2 * sin(Double($0) * 0.13) }
        let emit: (BorrowedPowerCepstrum<Double>) -> Void = { row in
            do {
                try ring.append(row)
                try canonical.append(row)
                #expect(try export.owned(row) == canonical.frames.last)
            } catch { Issue.record(error) }
        }
        _ = try signal.withUnsafeBufferPointer {
            try worker.process($0, interval: source(0, signal.count, rate: 16_000), emit: emit)
        }
        _ = try worker.finish(emit: emit)
        let result = ring.snapshot()
        #expect(
            result.axis.unit == .seconds && result.powerUnit == .inverseSecondsSquared
                && result.axis.step == 1 / 4000.0)
        #expect(
            result.columns == canonical.frames.suffix(3).map(SpectralProductColumn.powerCepstrum))
        #expect(result.evictedCount == UInt64(canonical.frames.count - 3))
        let display = try result.displayColumns(framesPerColumn: 3, aggregation: .maximum)[0]
        #expect(
            display.availableFrameCount == 2 && display.unavailableFrames[.insufficientData] == 1)
        #expect(try JSONEncoder().encode(result).count > 0)
    }

    @Test func decodedSpectralFramesRejectCorruptGridWeightsAndEnergy() throws {
        let (rows, _) = try analyze(.init(repeating: 1, count: 64), layout())
        let good = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(rows[0])) as? [String: Any])
        for name in ["frequency", "profile", "weight", "powers", "negative", "energy"] {
            var object = good
            var layout = try #require(object["layout"] as? [String: Any])
            var info = try #require(object["info"] as? [String: Any])
            switch name {
            case "frequency":
                var axis = try #require(layout["frequency"] as? [String: Any])
                axis["step"] = 12
                layout["frequency"] = axis
            case "profile": layout["bandwidthHz"] = 200.0
            case "weight": info["weight"] = 0
            case "powers": object["binPower"] = []
            case "negative": object["binPower"] = Array(repeating: -1, count: 33)
            default: object["binPower"] = Array(repeating: 0, count: 33)
            }
            object["layout"] = layout
            object["info"] = info
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SpectrogramFrame.self, from: data)
            }
        }
    }
}
