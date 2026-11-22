import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct FormantReference: Decodable {
    struct Observation: Decodable {
        let centerSeconds: Double
        let candidatesHz: [[Double]]
        let selectedHz: [[Double]]

        func referencePolynomial(ceiling: Double) -> [Double] {
            var coefficients = [1.0]
            for pair in candidatesHz {
                let frequency = pair[0]
                let radius = exp(-Double.pi * pair[1] / (2 * ceiling))
                let factor: [Double]
                if frequency < 1e-8 {
                    factor = [1, -radius]
                } else if ceiling - frequency < 1e-8 {
                    factor = [1, radius]
                } else {
                    factor = [1, -2 * radius * cos(.pi * frequency / ceiling), radius * radius]
                }
                var product = Array(repeating: 0.0, count: coefficients.count + factor.count - 1)
                for i in coefficients.indices {
                    for j in factor.indices { product[i + j] += coefficients[i] * factor[j] }
                }
                coefficients = product
            }
            return coefficients
        }
    }
    struct Case: Decodable {
        let name: String
        let sampleRate, sampleCount, ceilingHz, order, hopMilliseconds: Int
        let syntheticPCM16: [Int16]?
        let corpusPath, corpusSHA256: String?
        let sourceOffset: Int?
        let pcm16LESHA256: String
        let f0Hz: Double?
        let frames: [Observation]
        func samples() throws -> [Double] {
            let values: [Double]
            if let syntheticPCM16 {
                values = syntheticPCM16.map { Double($0) / 32768 }
            } else {
                let file = try VoiceCorpus.bytes(try #require(corpusPath))
                #expect(VoiceCorpus.sha256(file) == corpusSHA256)
                let pcm = try CorpusPCM(data: file)
                let start = try #require(sourceOffset)
                #expect(pcm.sampleRate == sampleRate)
                values = Array(pcm.samples[start..<(start + sampleCount)])
            }
            var bytes = Data()
            for value in values {
                var q = Int16(value * 32768).littleEndian
                withUnsafeBytes(of: &q) { bytes.append(contentsOf: $0) }
            }
            #expect(VoiceCorpus.sha256(bytes) == pcm16LESHA256)
            return values
        }
    }
    let cases: [Case]
    static func load() throws -> Self {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let names = [
            "burg", "corpus-bl01-vowel-a", "corpus-bl02-vowel-i", "corpus-bl03-consonant-rich",
        ]
        let cases = try names.flatMap { name in
            let bytes = try Data(contentsOf: root.appending(path: "Formants/" + name + ".json"))
            return try JSONDecoder().decode(Self.self, from: bytes).cases
        }
        return Self(cases: cases)
    }
}

struct BurgFormantTests {
    private func support(_ n: Int, _ rate: Int, offset: Int64 = 0) throws -> SourceInterval {
        try .init(
            epoch: StreamEpoch(streamID: UUID()), startSample: offset, sampleCount: Int64(n),
            sampleRate: Double(rate))
    }

    @Test func burgMatchesExactRationalForwardBackwardPrediction() throws {
        let samples: [Double] = [2, -1, 3, 1, -2, 4, 0, 1]
        let kernel = FormantBurgWorkspace(
            weights: Array(repeating: 1, count: samples.count), order: 2)
        let fit = try samples.withUnsafeBufferPointer { try kernel.fit($0).get() }
        #expect(fit.coefficients.count == 3)
        #expect(abs(fit.coefficients[1] - 13936.0 / 43539) < 2e-15)
        #expect(abs(fit.coefficients[2] + 13903.0 / 130617) < 2e-15)
        #expect(abs(fit.predictionErrorRatio - 14703175760.0 / 17_060_800_689) < 2e-15)
        #expect(abs(fit.maximumReflectionMagnitude - 24.0 / 67) < 2e-15)
        let huge = samples.map { $0 * 1e290 }
        let scaled = try huge.withUnsafeBufferPointer { try kernel.fit($0).get() }
        #expect(zip(fit.coefficients, scaled.coefficients).allSatisfy { abs($0 - $1) < 1e-14 })
    }

    @Test func knownPolePairsGiveAnalyticFrequenciesAndBandwidths() throws {
        let rate = 10000.0
        let observed = [(500.0, 80.0), (1500.0, 120.0), (2500.0, 180.0)]
        var coefficients = [1.0]
        for (f, b) in observed {
            let r = exp(-Double.pi * b / rate)
            let poly = [1.0, -2 * r * cos(2 * Double.pi * f / rate), r * r]
            var next = Array(repeating: 0.0, count: coefficients.count + 2)
            for i in coefficients.indices {
                for j in poly.indices { next[i + j] += coefficients[i] * poly[j] }
            }
            coefficients = next
        }
        let solution = FormantPolynomial(coefficients: coefficients).solve()
        #expect(solution.converged)
        #expect(solution.sweeps <= 2 * FormantPolynomial.sweepLimit)
        let selection = FormantSelection(
            roots: solution.roots,
            profile: try BurgFormantProfile(sourceSampleRate: 10000, ceilingHz: 5000, order: 6),
            gainDB: 10, source: try support(500, 10000), pitch: nil)
        #expect(selection.candidates.count == 3)
        for (pole, pair) in zip(selection.candidates, observed) {
            #expect(pole.isCredible)
            #expect(abs(pole.frequencyHz - pair.0) < 1e-7)
            #expect(abs(try #require(pole.bandwidthHz) - pair.1) < 1e-7)
        }
        let limited = FormantPolynomial(coefficients: coefficients).solve(sweepLimit: 1)
        #expect(!limited.converged && limited.triedSecondStart && limited.sweeps == 2)
    }

    @Test func pinnedCandidateAndFinalFrequenciesMatchOnSyntheticAndLicensedVoice() throws {
        let reference = try FormantReference.load()
        #expect(reference.cases.count == 10)
        for row in reference.cases {
            let samples = try row.samples()
            let source = try support(samples.count, row.sampleRate, offset: 9_007_199_254_740_995)
            let profile = try BurgFormantProfile(
                sourceSampleRate: row.sampleRate, ceilingHz: row.ceilingHz, order: row.order,
                hopMilliseconds: row.hopMilliseconds)
            let analyzer = try PreparedBurgFormants<Double>(configuration: profile, source: source)
            let identity = try profile.identity()
            var frames: [BurgFormantFrame] = []
            try samples.withUnsafeBufferPointer { pcm in
                try analyzer.analyze(
                    pcm, source: source,
                    pitch: { window in
                        row.f0Hz.flatMap {
                            try? .init(source: window, profile: identity, frequencyHz: $0)
                        }
                    }
                ) { frames.append($0) }
            }
            var rawF = 0.0
            var rawB = 0.0
            var finalF = 0.0
            var finalB = 0.0
            var time = 0.0
            var mismatches = 0
            var failures = 0
            var retained = 0
            var maximumRelativeCoefficientError = 0.0
            for (frame, oracle) in zip(frames, row.frames) {
                if frame.failure != nil { failures += 1 }
                let coefficients = try #require(frame.diagnostics.coefficients)
                let reference = oracle.referencePolynomial(ceiling: Double(row.ceilingHz))
                #expect(reference.count == row.order + 1 && coefficients.count == reference.count)
                let scale = reference.map(abs).max() ?? 1
                for (actual, expected) in zip(coefficients, reference) {
                    maximumRelativeCoefficientError = max(
                        maximumRelativeCoefficientError, abs(actual - expected) / scale)
                }
                time = max(time, abs(frame.centerSecondsFromOrigin - oracle.centerSeconds))
                let ranked = frame.candidates.filter { $0.number != nil }
                if frame.candidates.count != oracle.candidatesHz.count
                    || ranked.count != oracle.selectedHz.count
                {
                    mismatches += 1
                }
                // Coincident real-pole frequencies at DC/Nyquist have no reference rank ordering.
                let nativePairs = frame.candidates.sorted { lhs, rhs in
                    let key: (BurgFormantCandidate) -> (Double, Double) = { pole in
                        (
                            abs(pole.imaginary) < 1e-12
                                ? (pole.real < 0 ? Double(row.ceilingHz) : 0) : pole.frequencyHz,
                            pole.bandwidthHz ?? .infinity
                        )
                    }
                    return key(lhs) < key(rhs)
                }
                let referencePairs = oracle.candidatesHz.sorted { lhs, rhs in
                    let key: ([Double]) -> (Double, Double) = { pair in
                        let hz =
                            pair[0] < 1e-8
                            ? 0
                            : (abs(pair[0] - Double(row.ceilingHz)) < 1e-8
                                ? Double(row.ceilingHz) : pair[0])
                        return (hz, pair[1])
                    }
                    return key(lhs) < key(rhs)
                }
                for (p, ref) in zip(nativePairs, referencePairs) {
                    rawF = max(rawF, abs(p.frequencyHz - ref[0]))
                    rawB = max(rawB, abs((p.bandwidthHz ?? .infinity) - ref[1]))
                }
                for (i, pair) in zip(ranked, oracle.selectedHz).enumerated() {
                    let (p, ref) = pair
                    #expect(p.number == i + 1)
                    #expect(frame.formant(i + 1) == (p.isCredible ? p : nil))
                    finalF = max(finalF, abs(p.frequencyHz - ref[0]))
                    finalB = max(finalB, abs((p.bandwidthHz ?? .infinity) - ref[1]))
                    if p.isCredible { retained += 1 }
                }
                #expect((row.f0Hz == nil) == (frame.profile == identity))
                #expect(frame.conditioningSupport == source)
                #expect(
                    frame.timing.source.startSample >= source.startSample
                        && frame.timing.source.endSample <= source.endSample)
            }
            print(
                "BURG_PARITY", row.name, frames.count, row.frames.count, "grid", time, "counts",
                mismatches, "failures", failures, "candidate Hz", rawF, rawB, "selected Hz", finalF,
                finalB, "credible", retained, "relative coefficient error",
                maximumRelativeCoefficientError)
            #expect(maximumRelativeCoefficientError < 1e-7)
            #expect(frames.count == row.frames.count && time < 1e-12, "\(row.name) frame grid")
            #expect(failures == 0 && mismatches == 0, "\(row.name) candidate counts")
            #expect(
                max(rawF, finalF) < 0.01 && max(rawB, finalB) < 0.02,
                "\(row.name) frequencies and bandwidths")
        }
    }
}

extension BurgFormantTests {
    @Test func syntheticVowelRecoversImposedPolesSeparatelyFromPraatAgreement() throws {
        let row = try #require(FormantReference.load().cases.first { $0.name == "five-pole-pairs" })
        let x = try row.samples()
        let source = try support(x.count, row.sampleRate)
        let plan = try PreparedBurgFormants<Double>(
            configuration: BurgFormantProfile(
                sourceSampleRate: row.sampleRate, ceilingHz: 5000, preEmphasisFromHz: nil),
            source: source)
        var estimates = Array(repeating: [(Double, Double)](), count: 5)
        try x.withUnsafeBufferPointer { pcm in
            try plan.analyze(pcm, source: source) { frame in
                for (i, p) in frame.candidates.enumerated() where i < 5 {
                    if let bw = p.bandwidthHz { estimates[i].append((p.frequencyHz, bw)) }
                }
            }
        }
        let truth = [(550.0, 70.0), (1480, 110), (2550, 170), (3450, 210), (4250, 255)]
        for (i, series) in estimates.enumerated() {
            try #require(series.count >= 12)
            let medianF = series.map(\.0).sorted()[series.count / 2]
            let medianB = series.map(\.1).sorted()[series.count / 2]
            #expect(abs(medianF - truth[i].0) < 100)
            #expect(abs(medianB - truth[i].1) < 200)
        }
    }

    @Test func formantApplicabilityPreservesRawCandidatesAndOriginalRanks() throws {
        let source = try support(500, 10000)
        let profile = try BurgFormantProfile(sourceSampleRate: 10000, ceilingHz: 5000)
        let pitch = try FormantPitchEvidence(
            source: source, profile: profile.identity(), frequencyHz: 350)
        func pole(_ f: Double, _ b: Double) -> FormantRoot {
            let r = exp(-.pi * b / 10000)
            let angle = 2 * .pi * f / 10000
            return FormantRoot(r * cos(angle), r * sin(angle))
        }
        let roots = [
            FormantRoot(1.1), FormantRoot(-0.7, 1e-13), pole(40, 65), pole(500, 75), pole(1600, 85),
            pole(3000, 1200), pole(4650, 200),
        ]
        let s = FormantSelection(
            roots: roots, profile: profile, gainDB: 11, source: source, pitch: pitch)
        #expect(s.cautions.contains(.highPitch) && s.cautions.contains(.ceilingSensitive))
        #expect(s.candidates.contains { $0.rejections.contains(.unstablePole) && $0.number == nil })
        #expect(
            s.candidates.contains { $0.rejections.contains(.realOrNearReal) && $0.number == nil })
        #expect(s.candidates.contains { $0.number == 1 && $0.rejections == [.sparseHarmonics] })
        #expect(s.candidates.contains { $0.number == 2 && $0.isCredible })
        #expect(s.candidates.contains { $0.number == 3 && $0.rejections == [.broadBandwidth] })
        let unmatched = FormantSelection(
            roots: roots, profile: profile, gainDB: 1, source: try support(500, 10000), pitch: pitch
        )
        #expect(
            unmatched.cautions.contains(.pitchSupportMismatch)
                && unmatched.cautions.contains(.weakPrediction))
        #expect(!unmatched.candidates.contains { $0.isCredible })
    }

    @Test func silenceConstantShortMalformedAndDifferentSettingsHaveSeparateOutcomes() throws {
        let p = try BurgFormantProfile(sourceSampleRate: 16000, ceilingHz: 5000)
        let source = try support(1600, 16000)
        let processor = try PreparedBurgFormants<Double>(configuration: p, source: source)
        for (value, expected) in [(0.0, FormantFitFailure.silent), (0.2, .constant)] {
            try Array(repeating: value, count: 1600).withUnsafeBufferPointer { pcm in
                try processor.analyze(pcm, source: source) { frame in
                    #expect(
                        frame.failure == expected && frame.f1 == nil && frame.candidates.isEmpty)
                    let outcome = try frame.measurement(number: 1, kind: .formantFrequency).outcome
                    #expect(outcome == .unavailable(expected.reason))
                }
            }
        }
        let short = try support(400, 16000)
        let shortPlan = try PreparedBurgFormants<Double>(configuration: p, source: short)
        var count = 0
        try Array(repeating: 0.1, count: 400).withUnsafeBufferPointer { pcm in
            try shortPlan.analyze(pcm, source: short) { frame in
                #expect(frame.failure == .shortWindow && frame.timing.source == short)
                count += 1
            }
        }
        #expect(count == 1)
        #expect(throws: ContractError.self) {
            try BurgFormantProfile(sourceSampleRate: 8000, ceilingHz: 5000)
        }
        #expect(throws: ContractError.self) {
            try BurgFormantProfile(sourceSampleRate: 16000, ceilingHz: 5000, order: 18)
        }
        #expect(throws: ContractError.self) {
            try BurgFormantProfile(
                sourceSampleRate: 16000, ceilingHz: 5000, declaredBandwidthHz: 4900)
        }
        #expect(throws: ConditioningError.self) {
            try PreparedBurgFormants<Float>(configuration: p, source: source)
        }
        let changed = try BurgFormantProfile(sourceSampleRate: 16000, ceilingHz: 6000, order: 12)
        #expect(try changed.identity() != p.identity())
        #expect(
            try JSONDecoder().decode(BurgFormantProfile.self, from: JSONEncoder().encode(p)) == p)
        let junk = Data(
            #"{"sourceSampleRate":16000,"inputPrecision":"float64","ceilingHz":6000,"order":999,"hopMilliseconds":5,"declaredBandwidthHz":8000}"#
                .utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BurgFormantProfile.self, from: junk)
        }
    }
}

extension BurgFormantTests {
    @Test func ownedFramesAndFloatWideningPreserveSelectionProvenanceAcrossReuse() throws {
        let row = try #require(FormantReference.load().cases.first { $0.name == "low-f0" })
        let x = try row.samples()
        let floats = x.map(Float.init)
        let source = try support(x.count, row.sampleRate)
        let p = try BurgFormantProfile(sourceSampleRate: 16000, ceilingHz: 5500, hopMilliseconds: 5)
        let fp = try BurgFormantProfile(
            sourceSampleRate: 16000, inputPrecision: .float32, ceilingHz: 5500, hopMilliseconds: 5)
        let analyzer = try PreparedBurgFormants<Double>(configuration: p, source: source)
        let floatAnalyzer = try PreparedBurgFormants<Float>(configuration: fp, source: source)
        let a = try p.identity()
        let b = try fp.identity()
        func frame(pitchProfile: ProfileIdentity?, stale: Bool = false) throws -> BurgFormantFrame {
            var first: BurgFormantFrame?
            try x.withUnsafeBufferPointer { pcm in
                try analyzer.analyze(
                    pcm, source: source,
                    pitch: { window in
                        pitchProfile.flatMap {
                            try? FormantPitchEvidence(
                                source: stale ? source : window, profile: $0, frequencyHz: 105)
                        }
                    }
                ) { if first == nil { first = $0 } }
            }
            return try #require(first)
        }
        let unassessed = try frame(pitchProfile: nil)
        let original = try frame(pitchProfile: a)
        let other = try frame(pitchProfile: b)
        let stale = try frame(pitchProfile: a, stale: true)
        #expect(
            Set([original.profile, other.profile, stale.profile, unassessed.profile]).count == 4)
        #expect(try frame(pitchProfile: a) == original)
        #expect(
            stale.cautions.contains(.pitchSupportMismatch)
                && unassessed.cautions.contains(.pitchUnassessed))
        let f = try original.measurement(number: 1, kind: .formantFrequency)
        let bw = try original.measurement(number: 1, kind: .formantBandwidth)
        #expect(
            f.profile == original.profile && f.timing == original.timing
                && f.measurement.unit == .hertz)
        #expect(
            bw.measurement.kind == .formantBandwidth
                && bw.outcome.estimate?.value == original.f1?.bandwidthHz)
        var fromFloat: BurgFormantFrame?
        try floats.withUnsafeBufferPointer { input in
            try floatAnalyzer.analyze(input, source: source) {
                if fromFloat == nil { fromFloat = $0 }
            }
        }
        let widened = try #require(fromFloat)
        #expect(
            widened.candidates == unassessed.candidates && widened.profile != unassessed.profile)
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        #expect(json["credibilityRule"] as? String == BurgFormantProfile.credibilityRule)
        #expect(
            json["frequencyUnit"] as? String == "hertz"
                && json["bandwidthUnit"] as? String == "hertz")
        let baselineF1 = try #require(unassessed.f1?.frequencyHz)
        for (ceiling, order) in [(6000, 10), (5500, 12)] {
            let profile = try BurgFormantProfile(
                sourceSampleRate: 16000, ceilingHz: ceiling, order: order, hopMilliseconds: 5)
            let changed = try PreparedBurgFormants<Double>(configuration: profile, source: source)
            var shifted: BurgFormantFrame?
            try x.withUnsafeBufferPointer { input in
                try changed.analyze(input, source: source) { if shifted == nil { shifted = $0 } }
            }
            let first = try #require(shifted)
            let frequency = try #require(first.f1?.frequencyHz)
            #expect(first.profile != unassessed.profile && abs(frequency - baselineF1) > 0.01)
        }
    }

    @Test func throwsAndReentryLeaveThePreparedWorkerReusable() throws {
        enum Stop: Error { case requested }
        let first = try #require(FormantReference.load().cases.first)
        let x = try first.samples()
        let source = try support(x.count, first.sampleRate)
        let p = try BurgFormantProfile(sourceSampleRate: 10000, ceilingHz: 5000)
        let worker = try PreparedBurgFormants<Double>(configuration: p, source: source)
        try x.withUnsafeBufferPointer { pcm in
            #expect(throws: Stop.self) {
                try worker.analyze(pcm, source: source) { _ in
                    #expect(throws: ConditioningError.reentrantCall) {
                        try worker.analyze(pcm, source: source) { _ in }
                    }
                    throw Stop.requested
                }
            }
            var n = 0
            try worker.analyze(pcm, source: source) { _ in n += 1 }
            #expect(n == worker.frameCount)
        }
        var bad = x
        bad[bad.count / 2] = .nan
        #expect(throws: ConditioningError.nonfiniteInput) {
            try bad.withUnsafeBufferPointer { try worker.analyze($0, source: source) { _ in } }
        }
    }

    @Test func sampledFrameScopesCoverTheThreeKernelsWithBoundedMetadata() throws {
        let first = try #require(FormantReference.load().cases.first)
        let x = try first.samples()
        let source = try support(x.count, first.sampleRate)
        let p = try BurgFormantProfile(sourceSampleRate: 10000, ceilingHz: 5000)
        let sink = RecordingSink()
        let worker = try PreparedBurgFormants<Double>(
            configuration: p, source: source,
            diagnostics: WorkerDiagnostics(mode: .sampled, sink: sink))
        for _ in 0..<2 {
            try x.withUnsafeBufferPointer { try worker.analyze($0, source: source) { _ in } }
        }
        let stages: [DiagnosticStage] = [.burgFormants, .burgLPC, .formantRoots, .formantSelection]
        for stage in stages {
            let began = sink.entries.compactMap { entry -> DiagnosticRecord? in
                if case .begin(let record) = entry, record.stage == stage { return record }
                return nil
            }
            #expect(began.map(\.metadata.frameSequence) == [0, 16])
            #expect(
                began.allSatisfy {
                    $0.metadata.profileToken == 4601 && $0.metadata.sampleCount == 500
                })
            #expect(
                sink.entries.filter {
                    if case .end(let record) = $0 { record.stage == stage } else { false }
                }.count == began.count)
        }
    }
}

extension BurgFormantTests {
    @Test func singularPredictorsAndZeroPolesRemainDiagnosable() throws {
        let alternating = (0..<64).map { $0.isMultiple(of: 2) ? 1.0 : -1.0 }
        let workspace = FormantBurgWorkspace(
            weights: Array(repeating: 1, count: alternating.count), order: 8)
        let fit = alternating.withUnsafeBufferPointer { workspace.fit($0) }
        guard case .failure(let reason) = fit else {
            Issue.record("A perfect reflection must reject the predictor")
            return
        }
        #expect(reason == .unstableRecursion)

        let padded = FormantPolynomial(coefficients: [1, -0.5, 0, 0]).solve()
        #expect(padded.converged && padded.sweeps == 0)
        let selected = FormantSelection(
            roots: padded.roots,
            profile: try BurgFormantProfile(sourceSampleRate: 10000, ceilingHz: 5000),
            gainDB: 10, source: try support(500, 10000), pitch: nil)
        #expect(
            selected.candidates.count == 3 && selected.candidates.allSatisfy { $0.number == nil })
        #expect(
            selected.candidates.filter {
                $0.rejections.contains(.zeroRadius) && $0.bandwidthHz == nil
            }.count == 2)
        #expect(selected.cautions.contains(.ceilingSensitive))
        let malformed = FormantPolynomial(coefficients: [1, .nan, 0.8]).solve()
        #expect(
            !malformed.converged && malformed.roots.isEmpty
                && malformed.maximumRelativeResidual == nil)
    }
}

extension BurgFormantTests {
    @Test func pitchSupportUsesExactInputCellBoundaries() throws {
        for rate in [10000, 11000, 12000] {
            let n = rate / 5
            let source = try support(n, rate, offset: Int64.max - Int64(n))
            let profile = try BurgFormantProfile(
                sourceSampleRate: rate, ceilingHz: rate / 2, hopMilliseconds: 5)
            let worker = try PreparedBurgFormants<Double>(configuration: profile, source: source)
            let identity = try profile.identity()
            let zero = [Double](repeating: 0, count: n)
            try zero.withUnsafeBufferPointer { samples in
                try worker.analyze(
                    samples, source: source,
                    pitch: { window in
                        // At equal rates the exact source footprint is the number of physical window cells.
                        try? FormantPitchEvidence(
                            source: SourceInterval(
                                epoch: source.epoch, startSample: window.startSample,
                                sampleCount: Int64(profile.windowSamples), sampleRate: Double(rate)),
                            profile: identity, frequencyHz: 110)
                    }
                ) { frame in
                    #expect(frame.timing.source.sampleCount == Int64(profile.windowSamples))
                    #expect(!frame.cautions.contains(.pitchSupportMismatch))
                }
            }
        }
    }
}

extension BurgFormantTests {
    @Test func originalSilentAndConstantWindowsRejectConditionerRinging() throws {
        let profile = try BurgFormantProfile(sourceSampleRate: 16000)
        let source = try support(3200, 16000, offset: 121)
        let worker = try PreparedBurgFormants<Double>(configuration: profile, source: source)
        for (trailing, failure) in [(0.0, FormantFitFailure.silent), (0.125, .constant)] {
            let tone = (0..<1600).map { sin(2 * Double.pi * 135 * Double($0) / 16000) }
            let signal = tone + [Double](repeating: trailing, count: 1600)
            var windows = 0
            try signal.withUnsafeBufferPointer { pcm in
                try worker.analyze(pcm, source: source) { frame in
                    if frame.timing.source.startSample >= source.startSample + 1600 {
                        windows += 1
                        #expect(
                            frame.failure == failure && frame.f1 == nil && frame.candidates.isEmpty)
                        #expect(
                            try frame.measurement(number: 1, kind: .formantBandwidth).outcome
                                == .unavailable(failure.reason))
                    }
                }
            }
            #expect(windows >= 5)
        }
    }

    @Test func exactPhysicalWindowAndExplicitDisabledPreEmphasis() throws {
        let off = try BurgFormantProfile(sourceSampleRate: 16000, preEmphasisFromHz: nil)
        let bytes = try JSONEncoder().encode(off)
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(json["preEmphasisFromHz"] is NSNull)
        #expect(try JSONDecoder().decode(BurgFormantProfile.self, from: bytes) == off)
        json.removeValue(forKey: "preEmphasisFromHz")
        let missing = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: ContractError.self) {
            try JSONDecoder().decode(BurgFormantProfile.self, from: missing)
        }
        for (count, expected) in [(798, 0), (800, 1), (802, 1)] {
            let source = try support(count, 16000)
            let worker = try PreparedBurgFormants<Double>(configuration: off, source: source)
            #expect(worker.frameCount == expected)
            let pcm = (0..<count).map { sin(Double($0) * 0.04) + cos(Double($0) * 0.37) }
            var frames: [BurgFormantFrame] = []
            try pcm.withUnsafeBufferPointer { input in
                try worker.analyze(input, source: source) { frames.append($0) }
            }
            #expect(frames.count == 1)
            #expect((frames[0].failure == .shortWindow) == (expected == 0))
            if expected > 0 { #expect(frames[0].diagnostics.coefficients != nil) }
        }
    }

    @Test func frequencyAndBandwidthRoundTripThroughSessionWriterAndReader() throws {
        let row = try #require(FormantReference.load().cases.first { $0.name == "low-f0" })
        let pcm = try row.samples()
        let source = try sessionTestSource(start: 100, rate: 16000)
        let input = try SourceInterval(
            epoch: source.origin.source.epoch, startSample: 100, sampleCount: Int64(pcm.count),
            sampleRate: 16000)
        let config = try BurgFormantProfile(sourceSampleRate: 16000, hopMilliseconds: 5)
        let worker = try PreparedBurgFormants<Double>(configuration: config, source: input)
        let pitchProfile = try YINConfiguration(
            sampleRate: 16000, pitchFloorHz: 80, pitchCeilingHz: 400, hopLength: 160
        ).identity()
        for mode in [0, 1, 2] {
            var first: BurgFormantFrame?
            try pcm.withUnsafeBufferPointer { x in
                try worker.analyze(
                    x, source: input,
                    pitch: { support in
                        mode == 0
                            ? nil
                            : try? FormantPitchEvidence(
                                source: mode == 1 ? support : input, profile: pitchProfile,
                                frequencyHz: 105)
                    }
                ) { if first == nil { first = $0 } }
            }
            let frame = try #require(first)
            let recipe = frame.archiveProfile
            #expect(try recipe.identity() == frame.profile)
            #expect(
                try JSONDecoder().decode(
                    SessionArchiveProfile.self, from: JSONEncoder().encode(recipe)) == recipe)
            var bytes = Data()
            let writer = try SessionArchiveWriter(
                header: sessionTestHeader(), limits: SessionArchiveLimits()
            ) { bytes.append($0) }
            let profileIndex = try writer.addProfile(recipe)
            let sourceIndex = try writer.addSource(source)
            var expected: [MeasurementResult] = []
            for kind in [MeasurementKind.formantFrequency, .formantBandwidth] {
                let value = try frame.measurement(number: 2, kind: kind)
                expected.append(value)
                let series = try writer.addSeries(
                    SessionArchiveSeries(
                        profileIndex: profileIndex, sourceIndex: sourceIndex,
                        measurement: value.measurement, clock: .sourceSamples))
                try writer.append(
                    SessionArchiveMeasurement(
                        timestamp: SessionArchiveTimestamp(
                            sourceSample: frame.timing.source.startSample), result: value),
                    to: series)
            }
            try writer.finish(.completed)
            var offset = 0
            let reader = try SessionArchiveReader(limits: SessionArchiveLimits()) { requested in
                let count = min(requested, bytes.count - offset)
                defer { offset += count }
                return Data(bytes[offset..<(offset + count)])
            }
            var actual: [MeasurementResult] = []
            while let event = try reader.next() {
                if case .measurement(_, let record) = event { actual.append(record.result) }
            }
            #expect(actual == expected && reader.seal?.measurementCount == 2)
        }
    }
}
