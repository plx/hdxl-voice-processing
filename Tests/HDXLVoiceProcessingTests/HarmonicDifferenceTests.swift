import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct HarmonicReferences: Decodable {
    struct Row: Decodable {
        let name: String
        let sourceRate, periodSamples, periods: Int
        let f0: Double
        let formantsHz: [[Double]]
        let pcm16: [Int16]
        let sourcePeaksFS, praatPeaksFS, correctedDBFS: [Double]
        let poleGainsDB: [[Double]]
    }
    let cases: [Row]
}

struct HarmonicDifferenceTests {
    private let epoch = StreamEpoch(streamID: UUID())
    private func source(_ n: Int = 800, _ rate: Int = 16000, start: Int64 = 1200) throws
        -> SourceInterval
    {
        try .init(epoch: epoch, startSample: start, sampleCount: Int64(n), sampleRate: Double(rate))
    }
    private func config(
        rate: Int = 16000, periods: Int = 3, precision: AnalysisPrecision = .float64,
        pitch: HarmonicPitchRecipe? = nil
    ) throws -> HarmonicCorrectionProfile {
        let algorithm = try VersionedIdentifier(name: "analytic-mixture-pitch", version: 1)
        let recipe =
            try pitch
            ?? .frameLocal(
                .init(
                    identifier: algorithm,
                    measurement: .init(
                        kind: .fundamentalFrequency, unit: .hertz, algorithm: algorithm),
                    inputFormat: .init(
                        sampleRate: Double(rate), channelCount: 1, encoding: .float64),
                    channels: .arithmeticMean, precision: .float64, frameLength: rate / 20,
                    hopLength: rate / 100,
                    analysisSampleRate: Double(rate), window: .init(name: "analytic", version: 1),
                    preprocessing: [:],
                    algorithmSettings: ["frequency": .text("known-generating-frequency")],
                    partialWindowPolicy: .emitUnavailable))
        return try .init(
            fit: .init(
                sourceSampleRate: rate, inputPrecision: precision, periods: periods,
                pitch: recipe),
            formants: .init(
                sourceSampleRate: rate, inputPrecision: precision, ceilingHz: min(rate / 2, 5000)))
    }
    private func observation(
        _ f0: Double, _ source: SourceInterval, _ configuration: HarmonicCorrectionProfile,
        warnings: [MeasurementWarning] = []
    ) throws -> MeasurementResult {
        let id = configuration.fit.pitchProfile
        return try .init(
            measurement: .init(
                kind: .fundamentalFrequency, unit: .hertz,
                algorithm: configuration.fit.pitchAlgorithm),
            profile: id,
            timing: .init(
                source: source, includedSampleCount: source.sampleCount,
                sourceStartSeconds: 80, effectiveDelaySeconds: source.durationSeconds / 2),
            outcome: .available(.init(value: f0, warnings: warnings)))
    }
    private func poles(
        _ pairs: [[Double]], _ pitch: MeasurementResult, _ config: HarmonicCorrectionProfile,
        dependency: SourceInterval? = nil, rejections: [Int: [FormantRejection]] = [:],
        qualifyingAlgorithm: VersionedIdentifier? = nil
    ) throws -> BurgFormantFrame {
        let f0 = try #require(pitch.outcome.estimate?.value)
        let evidence = try FormantPitchEvidence(
            source: pitch.timing.source, profile: pitch.profile, frequencyHz: f0,
            algorithm: qualifyingAlgorithm ?? pitch.measurement.algorithm)
        let id = try BurgFormantProfile.bind(
            config.formants.identity(), to: pitch.profile, matched: true)
        let candidates = pairs.enumerated().map { index, pair in
            let rate = Double(config.formants.analysisSampleRate)
            let r = exp(-Double.pi * pair[1] / rate)
            let theta = 2 * Double.pi * pair[0] / rate
            return BurgFormantCandidate(
                real: r * cos(theta), imaginary: r * sin(theta), radius: r,
                frequencyHz: pair[0], bandwidthHz: pair[1], number: index + 1,
                rejections: rejections[index + 1] ?? [])
        }
        return .init(
            configuration: config.formants, profile: id, timing: pitch.timing,
            conditioningSupport: dependency ?? pitch.timing.source, centerSecondsFromOrigin: 0.025,
            index: 0, pitch: evidence, diagnostics: .init(fit: nil, solution: nil),
            failure: nil, cautions: [], candidates: candidates)
    }
    private func signal(
        _ n: Int, rate: Int = 16000, f0: Double = 147.31,
        first: Double = 0.4, second: Double = 0.12, dc: Double = 0.02
    ) -> [Double] {
        (0..<n).map { i in
            let t = Double(i) * 2 * Double.pi * f0 / Double(rate)
            return dc + first * cos(t + 0.72) + second * sin(2 * t - 0.21)
        }
    }

    @Test func exactOffBinQuadraturesDeclareWindowPitchAndPeakReference() throws {
        let c = try config()
        let worker = try PreparedHarmonicDifference<Double>(c)
        let s = try source(start: Int64.max - 2000)
        let f0 = 147.31
        let obs = try observation(f0, s, c)
        let frame = try signal(800).withUnsafeBufferPointer {
            try worker.analyze($0, source: s, pitch: obs)
        }
        let length = Int((3 * s.sampleRate / f0).rounded())
        let offset = (800 - length) / 2
        #expect(frame.raw.measurement.timing.source.startSample == s.startSample + Int64(offset))
        #expect(frame.raw.measurement.timing.source.sampleCount == length)
        #expect(frame.raw.measurement.timing.sourceStartSeconds == 80 + Double(offset) / 16000)
        #expect(frame.raw.dependencySupport == s && frame.raw.pitch?.profile == c.fit.pitchProfile)
        #expect(abs(try #require(frame.raw.first).peakFS - 0.4) < 1e-12)
        #expect(abs(try #require(frame.raw.second).peakDBFS - 20 * log10(0.12)) < 1e-11)
        let db = try #require(frame.raw.measurement.outcome.estimate).value
        #expect(abs(db - 20 * log10(0.4 / 0.12)) < 1e-10)
        #expect(frame.failure == .missingFormants && frame.measurement.outcome.estimate == nil)
        #expect(
            frame.raw.measurement.measurement.kind == .h1MinusH2
                && frame.measurement.measurement.kind == .correctedH1MinusH2)
        #expect(frame.raw.measurement.profile != frame.measurement.profile)
    }

    @Test func pinnedSpectraAndFilteredSourceRecovery() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let fixtures = try JSONDecoder().decode(
            HarmonicReferences.self,
            from: Data(contentsOf: url.appendingPathComponent("Harmonics/h1-h2.json")))
        #expect(fixtures.cases.count == 8)
        var rawByName: [String: Double] = [:]
        for row in fixtures.cases {
            let c = try config(rate: row.sourceRate, periods: row.periods)
            let s = try source(row.pcm16.count, row.sourceRate)
            let obs = try observation(row.f0, s, c)
            let model = try poles(row.formantsHz, obs, c)
            let worker = try PreparedHarmonicDifference<Double>(c)
            let frame = try row.pcm16.map { Double($0) / 32768 }.withUnsafeBufferPointer {
                try worker.analyze($0, source: s, pitch: obs, formants: model)
            }
            let h1 = try #require(frame.raw.first)
            let h2 = try #require(frame.raw.second)
            for (actual, expected) in zip([h1.peakFS, h2.peakFS], row.praatPeaksFS) {
                #expect(abs(actual - expected) < 0.000004, "Pinned Praat Fourier bin \(row.name)")
            }
            rawByName[row.name] = frame.raw.measurement.outcome.estimate?.value
            if row.f0 >= 300 {
                #expect(frame.failure == .highPitch)
                continue
            }
            let db = try #require(frame.measurement.outcome.estimate).value
            #expect(abs(db - 20 * log10(row.sourcePeaksFS[0] / row.sourcePeaksFS[1])) < 0.004)
            #expect(abs(try #require(frame.correctedFirstDBFS) - row.correctedDBFS[0]) < 0.003)
            #expect(abs(try #require(frame.correctedSecondDBFS) - row.correctedDBFS[1]) < 0.003)
            #expect(frame.contributions.count == 2)
            for (component, expected) in zip(frame.contributions, row.poleGainsDB) {
                #expect(abs(component.firstGainDB - expected[0]) < 1e-8)
                #expect(abs(component.secondGainDB - expected[1]) < 1e-8)
            }
            if row.name == "narrow-at-h2" {
                #expect(frame.contributions[0].nearResonance)
                #expect(
                    frame.measurement.outcome.estimate?.warnings.contains(.lowConfidence) == true)
            }
        }
        let different = try #require(rawByName["same-source-different-filter"])
        #expect(abs(try #require(rawByName["source-a"]) - different) > 5)
    }

    @Test func rejectsMissingUncertainMismatchedAndUnresolvedInputsIndependently() throws {
        let c = try config()
        let w = try PreparedHarmonicDifference<Double>(c)
        let s = try source()
        let obs = try observation(147.31, s, c)
        func fit(_ pcm: [Double], _ p: MeasurementResult?) throws -> RawHarmonicFrame {
            try pcm.withUnsafeBufferPointer { try w.fit($0, source: s, pitch: p) }
        }
        let x = signal(800)
        let missing = try fit(x, nil)
        let uncertain = try fit(x, observation(147.31, s, c, warnings: [.lowConfidence]))
        #expect(missing.failure == .missingPitch && uncertain.failure == .uncertainPitch)
        let mismatch = try fit(x, observation(147.31, source(start: 1201), c))
        #expect(mismatch.failure == .pitchSupportMismatch)
        let weak = try fit(signal(800, second: 1e-9), obs)
        #expect(
            weak.failure == .secondHarmonicUnresolved && weak.first != nil && weak.second == nil)
        let none = try fit(Array(repeating: 0, count: 800), obs)
        #expect(none.failure == .silence && none.measurement.outcome == .unavailable(.silence))
        let partial = try source(30)
        let partialPitch = try observation(55, partial, c)
        let short = try x.prefix(30).withContiguousStorageIfAvailable {
            try w.fit($0, source: partial, pitch: partialPitch)
        }
        #expect(short?.failure == .shortWindow)
        var invalid = x
        invalid[400] = .nan
        let bad = try fit(invalid, obs)
        #expect(bad.failure == .nonfinitePCM)
        let lowRate = try config(rate: 8000)
        let sw = try PreparedHarmonicDifference<Double>(lowRate)
        let low = try source(400, 8000)
        let beyond = try observation(2000, low, lowRate)
        let boundary = try signal(400, rate: 8000, f0: 2000).withUnsafeBufferPointer {
            try sw.fit($0, source: low, pitch: beyond)
        }
        #expect(boundary.failure == .harmonicOutsideBandwidth)
    }

    @Test func correctedOutputRequiresTheQualifyingObservationAndMeasuredRanks() throws {
        let c = try config()
        let w = try PreparedHarmonicDifference<Double>(c)
        let s = try source()
        let obs = try observation(147.31, s, c)
        let raw = try signal(800).withUnsafeBufferPointer { try w.fit($0, source: s, pitch: obs) }
        let pairs = [[500.0, 85.0], [1450, 120]]
        let other = try w.correct(raw, formants: poles(pairs, observation(200, s, c), c))
        #expect(other.failure == .qualifyingPitchMismatch && other.raw == raw)
        let absent = try w.correct(raw, formants: poles([pairs[0]], obs, c))
        #expect(
            absent.failure == .secondFormantUnavailable
                && absent.measurement.outcome == .unavailable(.excluded))
        let shifted = try w.correct(
            raw, formants: poles(pairs, observation(147.31, source(start: 1201), c), c))
        #expect(shifted.failure == .formantSupportMismatch)
        let dependency = try source(4000, start: 0)
        let valid = try w.correct(raw, formants: poles(pairs, obs, c, dependency: dependency))
        let fitWindow = raw.measurement.timing.source
        let delay =
            (Double(dependency.endSample - fitWindow.startSample) - Double(fitWindow.sampleCount)
                / 2) / s.sampleRate
        #expect(
            valid.dependencySupport == dependency
                && abs(valid.measurement.timing.effectiveDelaySeconds - delay) < 1e-14)
        #expect(valid.formantPitch?.frequencyHz == 147.31 && valid.correctedSecondDBFS != nil)
        let clipped = try signal(800, first: 1.4).withUnsafeBufferPointer {
            try w.analyze($0, source: s, pitch: obs, formants: poles(pairs, obs, c))
        }
        #expect(
            clipped.failure == .clippedInput
                && clipped.raw.measurement.outcome.estimate?.warnings == [.clipping])
    }

    @Test func float32AndNoisySignalCompareToExactWideningAndSourceGain() throws {
        let c = try config(precision: .float32)
        let s = try source()
        let obs = try observation(147.31, s, c)
        let x = signal(800).enumerated().map {
            Float($0.element + 0.005 * cos(Double($0.offset) * 1.39))
        }
        let float = try PreparedHarmonicDifference<Float>(c)
        let double = try PreparedHarmonicDifference<Double>(config())
        let one = try x.withUnsafeBufferPointer { try float.fit($0, source: s, pitch: obs) }
        let two = try x.map(Double.init).withUnsafeBufferPointer {
            try double.fit($0, source: s, pitch: obs)
        }
        #expect(
            one.first == two.first && one.second == two.second
                && one.measurement.profile != two.measurement.profile)
        let value = try #require(one.measurement.outcome.estimate).value
        #expect(abs(value - 20 * log10(0.4 / 0.12)) < 0.015)
        #expect(throws: ConditioningError.precisionMismatch) {
            try PreparedHarmonicDifference<Double>(c)
        }
    }

    @Test func profileEncodingRoundTripsAndRejectsMissingVersion() throws {
        let c = try config()
        let raw = SessionArchiveProfile.harmonicFit(c.fit)
        let corrected = SessionArchiveProfile.harmonicCorrection(c)
        for profile in [raw, corrected] {
            let data = try JSONEncoder().encode(profile)
            let restored = try JSONDecoder().decode(SessionArchiveProfile.self, from: data)
            #expect(profile == restored)
            let a = try profile.identity()
            let b = try restored.identity()
            #expect(a == b)
        }
        let data = try JSONEncoder().encode(c.fit)
        var keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        keys.removeValue(forKey: "schemaVersion")
        let invalid = try JSONSerialization.data(withJSONObject: keys)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HarmonicFitProfile.self, from: invalid)
        }
        #expect(try c.fit.identity() != config(periods: 5).fit.identity())
    }
}

extension HarmonicDifferenceTests {
    @Test func archivedSeriesKeepDistinctRecipesAndActualDependencies() throws {
        let c = try config()
        let w = try PreparedHarmonicDifference<Double>(c)
        let metadata = try sessionTestSource(start: 0)
        let epoch = metadata.origin.source.epoch
        let window = try SourceInterval(
            epoch: epoch, startSample: 1200, sampleCount: 800, sampleRate: 16000)
        let support = try SourceInterval(
            epoch: epoch, startSample: 400, sampleCount: 2500, sampleRate: 16000)
        let obs = try observation(147.31, window, c)
        let f = try poles([[620, 80], [1490, 130]], obs, c, dependency: support)
        let complete = try signal(800).withUnsafeBufferPointer {
            try w.analyze($0, source: window, pitch: obs, formants: f)
        }
        let timestamp = try SessionArchiveTimestamp(
            sourceSample: complete.measurement.timing.source.startSample)
        let rows = [
            (
                SessionArchiveProfile.harmonicFit(c.fit),
                SessionArchiveMeasurement(timestamp: timestamp, rawHarmonics: complete.raw)
            ),
            (
                .harmonicCorrection(c),
                SessionArchiveMeasurement(timestamp: timestamp, correctedHarmonics: complete)
            ),
        ]
        var bytes = Data()
        let writer = try SessionArchiveWriter(
            header: sessionTestHeader(), limits: SessionArchiveLimits()
        ) { bytes.append($0) }
        let sourceIndex = try writer.addSource(metadata)
        for (profile, record) in rows {
            let index = try writer.addProfile(profile)
            let series = try writer.addSeries(
                .init(
                    profileIndex: index, sourceIndex: sourceIndex,
                    measurement: record.result.measurement, clock: .sourceSamples))
            #expect(throws: SessionArchiveError.invalidMetadata) {
                try writer.append(.init(timestamp: timestamp, result: record.result), to: series)
            }
            try writer.append(record, to: series)
        }
        try writer.finish(.completed)
        var offset = 0
        let reader = try SessionArchiveReader(limits: SessionArchiveLimits()) { requested in
            let size = min(requested, bytes.count - offset)
            defer { offset += size }
            return Data(bytes[offset..<(offset + size)])
        }
        var observed: [SessionArchiveMeasurement] = []
        while let event = try reader.next() {
            if case .measurement(_, let record) = event { observed.append(record) }
        }
        #expect(observed == rows.map(\.1))
        #expect(observed.map(\.conditioningSupport) == [window, support])
        let encoded = try JSONEncoder().encode(complete)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect((json["contributions"] as? [[String: Any]])?.count == 2)
        #expect(
            json["formantPitch"] != nil && json["correctedFirstDBFS"] != nil && json["raw"] != nil)
    }

    @Test func continuousPitchAndResonancePerturbationsHaveObservableEffects() throws {
        let c = try config()
        let w = try PreparedHarmonicDifference<Double>(c)
        let s = try source()
        let pcm = signal(800, f0: 170)
        let obs = try observation(170, s, c)
        let raw = try pcm.withUnsafeBufferPointer { try w.fit($0, source: s, pitch: obs) }
        let a = try w.correct(raw, formants: poles([[360, 45], [1500, 100]], obs, c))
        let b = try w.correct(raw, formants: poles([[385, 45], [1500, 100]], obs, c))
        let wide = try w.correct(raw, formants: poles([[360, 120], [1500, 100]], obs, c))
        let aValue = try #require(a.measurement.outcome.estimate?.value)
        #expect(abs(aValue - (try #require(b.measurement.outcome.estimate?.value))) > 1)
        #expect(abs(aValue - (try #require(wide.measurement.outcome.estimate?.value))) > 1)
        let altered = try observation(179, s, c)
        let shifted = try pcm.withUnsafeBufferPointer {
            try w.analyze(
                $0, source: s, pitch: altered,
                formants: poles([[360, 45], [1500, 100]], altered, c))
        }
        let shiftedValue = try #require(shifted.measurement.outcome.estimate?.value)
        #expect(abs(aValue - shiftedValue) > 1)
        #expect(a.raw.measurement == b.raw.measurement && a.raw.measurement == wide.raw.measurement)
    }
}

extension HarmonicDifferenceTests {
    @Test func rawOnlyNarrowbandPropagatesUnavailabilityAndOriginalClock() throws {
        let c = try config()
        let fit = try HarmonicFitProfile(
            sourceSampleRate: 16000, declaredBandwidthHz: 1800,
            pitch: c.fit.pitchRecipe)
        let worker = try PreparedHarmonicFit<Double>(fit)
        let s = try source()
        let base = try observation(147.31, s, c)
        let timing = try AnalysisTiming(
            source: s, includedSampleCount: s.sampleCount, sourceStartSeconds: 99,
            hostStartNanoseconds: 5_000_000_000)
        func pitch(_ outcome: MeasurementOutcome, algorithm: VersionedIdentifier? = nil) throws
            -> MeasurementResult
        {
            try .init(
                measurement: .init(
                    kind: .fundamentalFrequency, unit: .hertz,
                    algorithm: algorithm ?? base.measurement.algorithm),
                profile: base.profile, timing: timing, outcome: outcome)
        }
        let x = signal(800)
        let result = try x.withUnsafeBufferPointer {
            try worker.fit($0, source: s, pitch: pitch(base.outcome))
        }
        let offset = result.measurement.timing.source.startSample - s.startSample
        #expect(
            result.measurement.timing.hostStartNanoseconds == 5_000_000_000 + UInt64(offset)
                * 62_500)
        #expect(result.measurement.timing.completedHostNanoseconds == nil)
        let gap = try x.withUnsafeBufferPointer {
            try worker.fit($0, source: s, pitch: pitch(.unavailable(.discontinuity)))
        }
        #expect(
            gap.failure == .missingPitchEstimate
                && gap.measurement.outcome == .unavailable(.discontinuity))
        let wrong = try x.withUnsafeBufferPointer {
            try worker.fit(
                $0, source: s,
                pitch: pitch(base.outcome, algorithm: .init(name: "other-f0", version: 1)))
        }
        #expect(wrong.failure == .wrongPitchMeasurement)
    }

    @Test func publicYINAndBurgSupplyAnActualCorrectedObservation() throws {
        struct Vowel: Decodable {
            let name: String
            let syntheticPCM16: [Int16]
        }
        struct Vowels: Decodable { let cases: [Vowel] }
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let data = try Data(contentsOf: root.appendingPathComponent("Formants/burg.json"))
        let row = try #require(
            JSONDecoder().decode(Vowels.self, from: data).cases.first { $0.name == "low-f0" })
        let rate = 16000
        let count = 800
        let s = try source(count, rate)
        let pcm = row.syntheticPCM16[1600..<2400].map { Double($0) / 32768 }
        let yin = try PreparedYIN<Double>(
            .init(
                sampleRate: rate, pitchFloorHz: 80, pitchCeilingHz: 450,
                integrationLength: 599, hopLength: 160))
        var result: YINFrameResult?
        try pcm.withUnsafeBufferPointer { ptr in
            try yin.analyze(ptr, timing: .init(source: s, includedSampleCount: s.sampleCount)) {
                result = $0.result
            }
        }
        let obs = try #require(result).measurementResult()
        let hz = try #require(obs.outcome.estimate?.value)
        #expect(abs(hz - 105) < 3)
        let c = try config(pitch: .yin(yin.configuration))
        let w = try PreparedHarmonicDifference<Double>(c)
        let burg = try PreparedBurgFormants<Double>(configuration: c.formants, source: s)
        let evidence = try FormantPitchEvidence(measurement: obs)
        var model: BurgFormantFrame?
        try pcm.withUnsafeBufferPointer { ptr in
            try burg.analyze(ptr, source: s, pitch: { _ in evidence }, emit: { model = $0 })
        }
        let frame = try pcm.withUnsafeBufferPointer {
            try w.analyze($0, source: s, pitch: obs, formants: model)
        }
        #expect(frame.failure == nil, "\(String(describing: frame.failure))")
        #expect(frame.raw.first != nil && frame.raw.second != nil && frame.contributions.count == 2)
        #expect(frame.formantPitch == evidence && frame.raw.pitch?.profile == yin.identity)
    }
}

extension HarmonicDifferenceTests {
    @Test func stationaryUpperHarmonicsAndNoiseCannotQualifyAnAbsentH2InFixtures() throws {
        let c = try config()
        let worker = try PreparedHarmonicFit<Double>(c.fit)
        let s = try source()
        let pitch = try observation(147.31, s, c)
        for noise in [0.0, 0.015, 0.07] {
            var state: UInt32 = 52
            let pcm = (0..<800).map { index in
                let phase = 2 * Double.pi * 147.31 * Double(index) / 16000
                state = state &* 1_664_525 &+ 1_013_904_223
                return 0.2 * sin(phase) + 0.45 * cos(3 * phase + 0.3) + 0.15 * sin(5 * phase)
                    + noise * (Double(state) / Double(UInt32.max) - 0.5)
            }
            let raw = try pcm.withUnsafeBufferPointer {
                try worker.fit($0, source: s, pitch: pitch)
            }
            #expect(
                raw.first != nil && raw.second == nil && raw.failure == .secondHarmonicUnresolved)
            #expect(try #require(raw.relativeDetectionFloor) > 0)
        }
    }

    @Test func rejectedBandwidthAndUnstableGainPreserveTheOffendingPole() throws {
        let c = try config()
        let w = try PreparedHarmonicDifference<Double>(c)
        let s = try source()
        let obs = try observation(147.31, s, c)
        let raw = try signal(800).withUnsafeBufferPointer { try w.fit($0, source: s, pitch: obs) }
        let broad = try poles(
            [[500, 80], [2000, 1200]], obs, c, rejections: [2: [.broadBandwidth]])
        let rejected = try w.correct(raw, formants: broad)
        #expect(rejected.failure == .secondFormantUnavailable && rejected.raw == raw)
        #expect(
            rejected.unusableFormant?.rejections == [.broadBandwidth]
                && rejected.measurement.outcome == .unavailable(.lowConfidence))
        #expect(rejected.unusableFormant?.bandwidthHz == 1200 && rejected.contributions.count == 1)
        let narrow = try w.correct(
            raw, formants: poles([[2 * 147.31, 0.01], [1440, 90]], obs, c))
        #expect(narrow.failure == .unstableCorrection && narrow.unusableFormant?.number == 1)
        #expect(narrow.correctedFirstDBFS == nil && narrow.correctedSecondDBFS == nil)
    }

    @Test func equalAmplitudesRemainAvailableAndWholeSourceClippingIsReported() throws {
        let c = try config()
        let w = try PreparedHarmonicDifference<Double>(c)
        let s = try source()
        let obs = try observation(147.31, s, c)
        let formants = try poles([[600, 80], [1450, 110]], obs, c)
        var pcm = signal(800, first: 0.1, second: 0.1)
        func read(_ samples: [Double]) throws -> CorrectedHarmonicFrame {
            try samples.withUnsafeBufferPointer {
                try w.analyze($0, source: s, pitch: obs, formants: formants)
            }
        }
        let valid = try read(pcm)
        let zero = try #require(valid.raw.measurement.outcome.estimate?.value)
        #expect(abs(zero) < 1e-11 && valid.failure == nil)
        pcm[0] = -1
        let clipped = try read(pcm)
        #expect(clipped.raw.measurement.outcome.estimate?.warnings == [.clipping])
        #expect(clipped.failure == .clippedInput && clipped.raw.first == valid.raw.first)
        pcm[799] = .infinity
        #expect(try read(pcm).raw.failure == .nonfinitePCM)
    }

    @Test func weakImageSeparationCannotCreateANearNyquistSecondHarmonic() throws {
        let c = try config(rate: 8000)
        let w = try PreparedHarmonicFit<Double>(c.fit)
        let s = try source(400, 8000)
        let f0 = 1999.9
        let pcm = (0..<400).map { index in
            let t = 2 * Double.pi * Double(index) / 8000
            return 0.2 * cos(f0 * t) + 0.001 * sin(3200 * t + 0.2)
        }
        let frame = try pcm.withUnsafeBufferPointer {
            try w.fit($0, source: s, pitch: observation(f0, s, c))
        }
        #expect(frame.failure == .insufficientNyquistSeparation)
        #expect(frame.second == nil && frame.measurement.outcome == .unavailable(.lowConfidence))
    }

    @Test func correctionReportsOnlyConsumedSupportAndPropagatesUpstreamBurgStatus() throws {
        let c = try config()
        let worker = try PreparedHarmonicDifference<Double>(c)
        let s = try source(480)
        let pitch = try observation(200, s, c)
        let model = try PreparedBurgFormants<Double>(configuration: c.formants, source: s)
        let pcm = signal(480, f0: 200)
        let evidence = try FormantPitchEvidence(measurement: pitch)
        var failed: BurgFormantFrame?
        try pcm.withUnsafeBufferPointer { samples in
            try model.analyze(samples, source: s, pitch: { _ in evidence }, emit: { failed = $0 })
        }
        let correction = try pcm.withUnsafeBufferPointer {
            try worker.analyze($0, source: s, pitch: pitch, formants: failed)
        }
        #expect(correction.raw.failure == nil && correction.formantFailure == .shortWindow)
        #expect(
            correction.failure == .formantFitFailed
                && correction.measurement.outcome == .unavailable(.insufficientData))

        let wider = try source(4800, start: 0)
        let supplied = try poles([[500, 90], [1500, 110]], pitch, c, dependency: wider)
        let clipped = Array(repeating: -1.0, count: 480)
        let missing = try clipped.withUnsafeBufferPointer {
            try worker.analyze($0, source: s, pitch: nil, formants: supplied)
        }
        #expect(missing.failure == .missingPitch && missing.raw.clipped)
        #expect(missing.formantConditioningSupport == wider && missing.dependencySupport == s)
        #expect(
            missing.measurement.timing.effectiveDelaySeconds
                == missing.raw.measurement.timing.effectiveDelaySeconds)
    }

    @Test func exportedPitchRecipeIsSelfContainedAndRejectsTrackingHistory() throws {
        let yin = try YINConfiguration(
            sampleRate: 16000, pitchFloorHz: 80, pitchCeilingHz: 450,
            integrationLength: 599, hopLength: 160, threshold: 0.125)
        let tracker = try YINProfile(estimator: yin, tracker: .init(continuityWeight: 0.12))
        let schedule = try AnalysisScheduleProfile(
            inputFormat: .init(sampleRate: 16000, channelCount: 1, encoding: .float64),
            channels: .arithmeticMean, pitch: tracker)
        let trackedAlgorithm = try tracker.identity().identifier
        #expect(throws: ContractError.invalidConfiguration) {
            try HarmonicFitProfile(
                sourceSampleRate: 16000, pitch: .schedule(schedule),
                pitchAlgorithm: trackedAlgorithm)
        }
        let c = try config(pitch: .schedule(schedule))
        let history = try source(1120)
        let measured = try MeasurementResult(
            measurement: .init(
                kind: .fundamentalFrequency, unit: .hertz, algorithm: trackedAlgorithm),
            profile: schedule.identity(),
            timing: .init(source: history, includedSampleCount: history.sampleCount),
            outcome: .available(.init(value: 147.31)))
        let w = try PreparedHarmonicFit<Double>(c.fit)
        let result = try signal(1120).withUnsafeBufferPointer {
            try w.fit($0, source: history, pitch: measured)
        }
        #expect(result.failure == .wrongPitchMeasurement)
        let restored = try JSONDecoder().decode(
            HarmonicFitProfile.self, from: JSONEncoder().encode(c.fit))
        guard case .schedule(let stored) = restored.pitchRecipe else {
            Issue.record("Missing pitch schedule")
            return
        }
        #expect(
            stored.pitch?.estimator.threshold == 0.125
                && stored.pitch?.estimator.integrationLength == 599)
        #expect(
            try stored.identity() == restored.pitchProfile
                && restored.pitchAlgorithm == yin.identity().identifier)
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(c.fit)) as? [String: Any])
        json["pitchProfile"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(yin.identity()))
        let forged = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: ContractError.invalidFingerprint) {
            try JSONDecoder().decode(HarmonicFitProfile.self, from: forged)
        }
    }

    @Test func swipePitchAndMultiEstimatorScheduleSelectTheDeclaredRawAlgorithm() throws {
        let yin = try YINConfiguration(sampleRate: 16000, hopLength: 160)
        let swipe = try SWIPEPrimeConfiguration(
            sampleRate: 16000, pitchFloorHz: 80,
            pitchCeilingHz: 450, hopLength: 160)
        let schedule = try AnalysisScheduleProfile(
            inputFormat: .init(sampleRate: 16000, channelCount: 1, encoding: .float64),
            channels: .arithmeticMean, pitch: .init(estimator: yin), swipePrime: swipe)
        #expect(throws: ContractError.invalidConfiguration) {
            try HarmonicFitProfile(sourceSampleRate: 16000, pitch: .schedule(schedule))
        }
        let algorithm = try swipe.identity().identifier
        let selected = try HarmonicFitProfile(
            sourceSampleRate: 16000, pitch: .schedule(schedule), pitchAlgorithm: algorithm)
        #expect(
            try selected.pitchProfile == schedule.identity() && selected.pitchAlgorithm == algorithm
        )
        let fit = try HarmonicFitProfile(sourceSampleRate: 16000, pitch: .swipePrime(swipe))
        let estimator = try PreparedSWIPEPrime<Double>(swipe)
        let raw = try PreparedHarmonicFit<Double>(fit)
        let n = swipe.requiredSampleCount
        let interval = try source(n)
        let samples = signal(n, f0: 200, first: 0.4, second: 0.15)
        let timing = try AnalysisTiming(source: interval, includedSampleCount: Int64(n))
        var pitch: SWIPEPrimeFrameResult?
        try samples.withUnsafeBufferPointer { pcm in
            try estimator.analyze(pcm, timing: timing) { pitch = $0.result }
        }
        let observation = try #require(pitch).measurementResult()
        let parsed = try samples.withUnsafeBufferPointer {
            try raw.fit($0, source: interval, pitch: observation)
        }
        #expect(parsed.failure == nil && parsed.pitch?.profile == fit.pitchProfile)
    }

    @Test func gainTransitionsDoNotQualifyAnAbsentSecondHarmonicAtHigherSamplingRates() throws {
        for rate in [8000, 16000, 44100, 48000, 96000] {
            let c = try config(rate: rate)
            let w = try PreparedHarmonicFit<Double>(c.fit)
            let s = try source(rate / 20, rate)
            let obs = try observation(200, s, c)
            let pcm = (0..<Int(s.sampleCount)).map { index in
                let gain = index < rate / 40 ? 0.2 : 0.4
                return gain * sin(2 * Double.pi * 200 * Double(index) / Double(rate))
            }
            let frame = try pcm.withUnsafeBufferPointer { try w.fit($0, source: s, pitch: obs) }
            #expect(
                frame.failure == .secondHarmonicUnresolved && frame.first != nil
                    && frame.second == nil)
            #expect(try #require(frame.relativeCycleVariation) > 0.1)
        }
    }

    @Test func nativePitchCapacityFrequencyRangeAndSupportAreCheckedAgainstTheRecipe() throws {
        let rate = 16000
        let yin = try YINConfiguration(sampleRate: rate, hopLength: 160)
        let swipe = try SWIPEPrimeConfiguration(sampleRate: rate, hopLength: 160)
        let schedule = try AnalysisScheduleProfile(
            inputFormat: .init(sampleRate: 16000, channelCount: 1, encoding: .float64),
            channels: .arithmeticMean,
            pitch: .init(estimator: yin), swipePrime: swipe)
        #expect(throws: ContractError.invalidConfiguration) {
            try HarmonicFitProfile(sourceSampleRate: rate, pitch: .swipePrime(swipe))
        }
        #expect(throws: ContractError.invalidConfiguration) {
            try HarmonicFitProfile(
                sourceSampleRate: rate, pitch: .schedule(schedule),
                pitchAlgorithm: swipe.identity().identifier)
        }
        let rawOnly = try HarmonicFitProfile(
            sourceSampleRate: rate, pitch: .schedule(schedule),
            pitchAlgorithm: yin.identity().identifier)
        #expect(throws: ContractError.invalidConfiguration) {
            try HarmonicCorrectionProfile(
                fit: rawOnly, formants: .init(sourceSampleRate: rate, ceilingHz: 5000))
        }
        let restricted = try YINConfiguration(
            sampleRate: rate, pitchFloorHz: 80, pitchCeilingHz: 180, integrationLength: 599,
            hopLength: 160)
        let c = try config(pitch: .yin(restricted))
        let w = try PreparedHarmonicFit<Double>(c.fit)
        func measure(_ n: Int, outcome: MeasurementOutcome) throws -> RawHarmonicFrame {
            let s = try source(n)
            let p = try MeasurementResult(
                measurement: .init(
                    kind: .fundamentalFrequency, unit: .hertz, algorithm: c.fit.pitchAlgorithm),
                profile: c.fit.pitchProfile,
                timing: .init(source: s, includedSampleCount: s.sampleCount), outcome: outcome)
            return try signal(n).withUnsafeBufferPointer { try w.fit($0, source: s, pitch: p) }
        }
        let outside = try measure(800, outcome: .available(.init(value: 250)))
        let partial = try measure(799, outcome: .available(.init(value: 150)))
        let unavailable = try measure(799, outcome: .unavailable(.discontinuity))
        #expect(outside.failure == .pitchOutOfRange && partial.failure == .pitchSupportMismatch)
        #expect(
            unavailable.failure == .missingPitchEstimate
                && unavailable.measurement.outcome == .unavailable(.discontinuity))
    }

    @Test func rejectedPitchClocksAndAlternativeBurgQualifiersRemainSeparate() throws {
        let yin = try YINConfiguration(
            sampleRate: 16000, pitchFloorHz: 80, pitchCeilingHz: 450, integrationLength: 599,
            hopLength: 160)
        let tracked = try YINProfile(estimator: yin, tracker: .init())
        let schedule = try AnalysisScheduleProfile(
            inputFormat: .init(sampleRate: 16000, channelCount: 1, encoding: .float64),
            channels: .arithmeticMean, pitch: tracked)
        let c = try config(pitch: .schedule(schedule))
        let w = try PreparedHarmonicDifference<Double>(c)
        let s = try source()
        let correct = try observation(147.31, s, c)
        let trackerID = try tracked.identity().identifier
        let other = try MeasurementResult(
            measurement: .init(kind: .fundamentalFrequency, unit: .hertz, algorithm: trackerID),
            profile: correct.profile,
            timing: .init(
                source: s, includedSampleCount: s.sampleCount,
                sourceStartSeconds: 14, hostStartNanoseconds: 100000, effectiveDelaySeconds: 2),
            outcome: correct.outcome)
        let pcm = signal(800)
        let rejected = try pcm.withUnsafeBufferPointer { try w.fit($0, source: s, pitch: other) }
        #expect(
            rejected.failure == .wrongPitchMeasurement
                && rejected.pitch?.timing.effectiveDelaySeconds == 2)
        #expect(
            rejected.measurement.timing.sourceStartSeconds == nil
                && rejected.measurement.timing.hostStartNanoseconds == nil)
        #expect(rejected.measurement.timing.effectiveDelaySeconds == s.durationSeconds / 2)
        let raw = try pcm.withUnsafeBufferPointer { try w.fit($0, source: s, pitch: correct) }
        let pairs = [[620.0, 90.0], [1500.0, 110.0]]
        let wrong = try w.correct(
            raw, formants: poles(pairs, correct, c, qualifyingAlgorithm: trackerID))
        let accepted = try w.correct(raw, formants: poles(pairs, correct, c))
        #expect(wrong.failure == .qualifyingPitchMismatch && accepted.failure == nil)
        #expect(accepted.formantPitch?.algorithm == c.fit.pitchAlgorithm)
    }

    @Test func subnormalPeaksAndDecibelsDescribeTheSameRepresentableAmplitudes() throws {
        let c = try config()
        let w = try PreparedHarmonicFit<Double>(c.fit)
        let s = try source(240)
        let pcm = (0..<240).map { i in
            let phase = 2 * Double.pi * Double(i) / 80
            return (cos(phase) + 1.4 * sin(2 * phase)).rounded() * Double.leastNonzeroMagnitude
        }
        let fitted = try pcm.withUnsafeBufferPointer {
            try w.fit($0, source: s, pitch: observation(200, s, c))
        }
        let first = try #require(fitted.first)
        let second = try #require(fitted.second)
        #expect(first.peakFS == second.peakFS && first.peakDBFS == second.peakDBFS)
        #expect(fitted.measurement.outcome.estimate?.value == 0)
    }

}
