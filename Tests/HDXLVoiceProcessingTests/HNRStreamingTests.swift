import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct HNRCausalReference: Decodable {
    struct Input: Decodable {
        let sampleCount, sampleRate: Int
        let encodedSHA256, normalizedFloat64LESHA256: String
    }
    struct Grid: Decodable {
        let windowSampleCount, completeFrameCount, tailStartSample, tailSampleCount: Int
        let stepNumerator, stepDenominator: UInt64
    }
    struct Frame: Decodable {
        let frameIndex, startSample, sampleCount: Int
        let centerSecondsFromStreamOrigin, normalizationMean, normalizationPeak: Double
        let localMean, localPeak, relativeIntensity: Double
        let status: String
        let valueDB, periodicity: Double?
    }
    let name: String
    let profile: HNRConfiguration
    let profileSHA256: String
    let input: Input
    let grid: Grid
    let frames: [Frame]
}

private struct HNRCausalAudit: Encodable {
    let name, inputSHA256: String
    let profileIdentity: ProfileIdentity
    let configuration: HNRConfiguration
    let completeFrameCount, tailStartSample, tailSampleCount: Int
    let chunkResultsExactlyEqual: Bool
    let maximumBudgetFractions: [String: Double]
}

private struct HNRStreamingCapture: Equatable {
    let result: HNRFrameResult?
    let unavailable: HNRUnavailableFrame?
    let origin: AnalysisTiming
    let center: Double
    let candidates: [HNRPeakCandidate]
    let curve: [Double]
    let valid: [Bool]
    init(_ output: BorrowedHNRStreamingOutput) {
        origin = output.origin
        center = output.centerSecondsFromStreamOrigin
        switch output.frame {
        case .frame(let frame):
            result = frame.result
            unavailable = nil
            candidates = Array(frame.candidates)
            curve = Array(frame.correlation)
            valid = Array(frame.correlationValidity)
        case .unavailable(let frame):
            result = nil
            unavailable = frame
            candidates = []
            curve = []
            valid = []
        }
    }
}

private func hnrStreamOrigin(
    _ c: HNRConfiguration, start: Int64 = 123, epoch: StreamEpoch? = nil,
    seconds: Double? = 23.5, host: UInt64? = 1_000_000_000
) throws -> AnalysisTiming {
    try AnalysisTiming(
        source: SourceInterval(
            epoch: epoch ?? StreamEpoch(streamID: UUID()),
            startSample: start, sampleCount: 0, sampleRate: Double(c.sampleRate)),
        includedSampleCount: 0,
        sourceStartSeconds: seconds, hostStartNanoseconds: host)
}

private func hnrStream<Sample: BinaryFloatingPoint & Sendable>(
    _ samples: [Sample],
    profile: HNRConfiguration, origin: AnalysisTiming, chunks: [Int]
) throws
    -> ([HNRStreamingCapture], HNRStreamingCompletion)
{
    let worker = try PreparedHNRStream<Sample>(configuration: profile, origin: origin)
    let bytes = worker.preparedBufferBytes
    var result: [HNRStreamingCapture] = []
    var offset = 0
    var iteration = 0
    try samples.withUnsafeBufferPointer { input in
        while offset < input.count {
            let count = min(input.count - offset, chunks[iteration % chunks.count])
            let interval = try SourceInterval(
                epoch: origin.source.epoch,
                startSample: origin.source.startSample + Int64(offset), sampleCount: Int64(count),
                sampleRate: origin.source.sampleRate)
            let report = try worker.process(
                UnsafeBufferPointer(rebasing: input[offset..<offset + count]),
                interval: interval
            ) { result.append(HNRStreamingCapture($0)) }
            #expect(report.consumedSampleCount == count && !report.isCancelled)
            #expect(worker.preparedBufferBytes == bytes)
            offset += count
            iteration += 1
        }
    }
    let completion = try worker.finish { result.append(HNRStreamingCapture($0)) }
    #expect(
        try worker.finish { _ in Issue.record("Repeated streaming finish emitted") } == completion)
    #expect(worker.nextInputSample == origin.source.startSample + Int64(samples.count))
    return (result, completion)
}

@Test func hnrCausalHopMatchesIndependentRationalCheckpoints() throws {
    // Independently evaluated with Python Fraction.from_float(rate * hop), not
    // accumulated floating additions or this implementation's phase state.
    let cases: [(Int, Double, UInt64, UInt64, [Int])] = [
        (44100, 0.005, 441, 2, [220, 441, 661, 2205, 22050, 220500, 220_500_000]),
        (
            16000, 0.0037, 4_165_829_655_317_709, 70_368_744_177_664,
            [59, 118, 177, 592, 5920, 59200, 59_200_000]
        ),
        (
            44100, 0.00500453514739229, 3_882_595_460_002_611, 17_592_186_044_416,
            [220, 441, 662, 2206, 22069, 220699, 220_699_999]
        ),
        (9871, 1.0 / 9871, 1, 1, [1, 2, 3, 10, 100, 1000, 1_000_000]),
    ]
    let indices = [1, 2, 3, 10, 100, 1000, 1_000_000]
    for (rate, seconds, numerator, denominator, expected) in cases {
        let c = try HNRConfiguration(
            method: .autocorrelation, sampleRate: rate,
            hopSeconds: seconds, normalization: .causalWindow)
        let hop = try HNRCausalHop(configuration: c)
        #expect(hop.fractionDenominator == denominator)
        #expect(UInt64(hop.wholeSamples) * denominator + hop.fractionNumerator == numerator)
        var phase: UInt64 = 0
        var position = 0
        var checkpoint = 0
        for index in 1...1_000_000 {
            position += hop.advance(phase: &phase)
            if index == indices[checkpoint] {
                #expect(position == expected[checkpoint])
                checkpoint += 1
                if checkpoint == indices.count { break }
            }
        }
    }
}

@Test func hnrStreamingMatchesIndependentCausalWindowsAndArbitraryChunks() throws {
    let directory = try hnrFixtureDirectory("HNRCausal")
    struct Manifest: Decodable { let catalog: [String] }
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    var compared = 0
    var audits: [HNRCausalAudit] = []
    for name in manifest.catalog {
        let r = try JSONDecoder().decode(
            HNRCausalReference.self,
            from: Data(contentsOf: directory.appending(path: name + ".json")))
        let data = try Data(contentsOf: directory.appending(path: name + ".wav"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(hash == r.input.encodedSHA256)
        let pcm = try CorpusPCM(data: data)
        try #require(
            pcm.sampleRate == r.input.sampleRate && pcm.samples.count == r.input.sampleCount)
        var bytes = Data()
        for sample in pcm.samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        #expect(
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                == r.input.normalizedFloat64LESHA256)
        #expect(try r.profile.identity().sha256 == r.profileSHA256)
        let origin = try hnrStreamOrigin(r.profile)
        let batch: ([HNRStreamingCapture], HNRStreamingCompletion)
        let pieces: ([HNRStreamingCapture], HNRStreamingCompletion)
        if r.profile.inputPrecision == .float32 {
            batch = try hnrStream(
                pcm.samples.map(Float.init), profile: r.profile, origin: origin,
                chunks: [pcm.samples.count])
            pieces = try hnrStream(
                pcm.samples.map(Float.init), profile: r.profile, origin: origin,
                chunks: [1, 17, 223, 7, 509])
        } else {
            batch = try hnrStream(
                pcm.samples, profile: r.profile, origin: origin, chunks: [pcm.samples.count])
            pieces = try hnrStream(
                pcm.samples, profile: r.profile, origin: origin, chunks: [1, 17, 223, 7, 509])
        }
        #expect(batch.0 == pieces.0 && batch.1 == pieces.1)
        #expect(batch.0.count == r.frames.count + 1)
        let complete = batch.0.filter { $0.result != nil }
        #expect(complete.count == r.grid.completeFrameCount)
        var budgets = Dictionary(
            uniqueKeysWithValues: [
                "center", "normalizationMean",
                "normalizationPeak", "localMean", "localPeak", "relativeIntensity", "periodicity",
                "decibels",
            ].map { ($0, 0.0) })
        func retainBudget(_ key: String, _ difference: Double, _ limit: Double) {
            budgets[key] = max(budgets[key]!, abs(difference) / limit)
        }
        for (actual, expected) in zip(complete, r.frames) {
            let value = try #require(actual.result)
            #expect(value.frameIndex == UInt64(expected.frameIndex))
            #expect(
                value.dependencyTiming.source.startSample == origin.source.startSample
                    + Int64(expected.startSample))
            #expect(value.dependencyTiming.source.sampleCount == Int64(expected.sampleCount))
            #expect(abs(actual.center - expected.centerSecondsFromStreamOrigin) <= 1e-12)
            #expect(
                abs(
                    value.scaledNormalizationMean - expected.normalizationMean
                        / value.normalizationAmplitudeScale) <= 2e-14)
            #expect(
                abs(
                    value.scaledNormalizationPeak - expected.normalizationPeak
                        / value.normalizationAmplitudeScale) <= 2e-14)
            #expect(
                abs(value.scaledLocalMean - expected.localMean / value.frameAmplitudeScale) <= 2e-14
            )
            #expect(
                abs(value.scaledLocalPeak - expected.localPeak / value.frameAmplitudeScale) <= 2e-14
            )
            #expect(abs(value.relativeIntensity - expected.relativeIntensity) <= 2e-14)
            if let db = expected.valueDB, let periodicity = expected.periodicity {
                let selected = try #require(value.selectedObservation)
                #expect(selected.status == .finite)
                #expect(abs(selected.referenceReportingDecibels - db) <= 1e-4)
                #expect(abs(selected.periodicity - periodicity) <= 2e-14)
            } else {
                #expect(value.selectedObservation == nil && value.unavailability == .silence)
                // Silence selection retains raw candidates.
                #expect(value.strongestObservation != nil)
            }
            #expect(value.dependencyTiming.completedHostNanoseconds == nil)
            let delta =
                (UInt64(expected.startSample) * 1_000_000_000 + UInt64(r.input.sampleRate) / 2)
                / UInt64(r.input.sampleRate)
            #expect(value.dependencyTiming.hostStartNanoseconds == 1_000_000_000 + delta)
            retainBudget("center", actual.center - expected.centerSecondsFromStreamOrigin, 1e-12)
            retainBudget(
                "normalizationMean",
                value.scaledNormalizationMean - expected.normalizationMean
                    / value.normalizationAmplitudeScale, 2e-14)
            retainBudget(
                "normalizationPeak",
                value.scaledNormalizationPeak - expected.normalizationPeak
                    / value.normalizationAmplitudeScale, 2e-14)
            retainBudget(
                "localMean", value.scaledLocalMean - expected.localMean / value.frameAmplitudeScale,
                2e-14)
            retainBudget(
                "localPeak", value.scaledLocalPeak - expected.localPeak / value.frameAmplitudeScale,
                2e-14)
            retainBudget(
                "relativeIntensity", value.relativeIntensity - expected.relativeIntensity, 2e-14)
            if let selected = value.selectedObservation, let db = expected.valueDB,
                let periodicity = expected.periodicity
            {
                retainBudget("periodicity", selected.periodicity - periodicity, 2e-14)
                retainBudget("decibels", selected.referenceReportingDecibels - db, 1e-4)
            }
            compared += 1
        }
        #expect(complete.prefix(3).allSatisfy { $0.result?.selectedObservation != nil })
        #expect(complete.suffix(3).allSatisfy { $0.result?.selectedObservation != nil })
        let tail = try #require(batch.0.last?.unavailable)
        #expect(tail.reason == .insufficientData)
        #expect(
            tail.timing.source.startSample == origin.source.startSample
                + Int64(r.grid.tailStartSample))
        #expect(tail.timing.source.sampleCount == Int64(r.grid.tailSampleCount))
        audits.append(
            HNRCausalAudit(
                name: name, inputSHA256: hash,
                profileIdentity: try r.profile.identity(), configuration: r.profile,
                completeFrameCount: complete.count,
                tailStartSample: Int(tail.timing.source.startSample - origin.source.startSample),
                tailSampleCount: Int(tail.timing.source.sampleCount),
                chunkResultsExactlyEqual: batch.0 == pieces.0 && batch.1 == pieces.1,
                maximumBudgetFractions: budgets))
        #expect(batch.1.framing.disposition == .unavailablePartial && !batch.1.isCancelled)
        #expect(
            batch.1.availableFrameCount + batch.1.unavailableFrameCount == UInt64(batch.0.count))
    }
    #expect(manifest.catalog.count == 12 && compared == 312)
    if let path = ProcessInfo.processInfo.environment["HDXL_HNR_CAUSAL_REPORT"] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(audits).write(to: URL(filePath: path), options: .atomic)
    }
}

@Test func hnrStreamingGapClockCancellationAndReconfigurationAreTransactional() throws {
    let c = try HNRConfiguration(
        method: .forwardCrossCorrelation, sampleRate: 4000,
        pitchFloorHz: 500, periodsPerWindow: 2, hopSeconds: 0.00025, normalization: .causalWindow)
    let origin = try hnrStreamOrigin(c, start: Int64.max - 100)
    let worker = try PreparedHNRStream<Double>(configuration: c, origin: origin)
    let interval = try SourceInterval(
        epoch: origin.source.epoch, startSample: origin.source.startSample,
        sampleCount: 100, sampleRate: 4000)
    let values = (0..<100).map { sin(Double($0) * 2 * .pi / 7) }
    let gap = try SourceInterval(
        epoch: interval.epoch, startSample: interval.startSample + 1,
        sampleCount: 99, sampleRate: interval.sampleRate)
    #expect(throws: HNRError.unexpectedContext) {
        try values.dropLast().withUnsafeBufferPointer {
            try worker.process($0, interval: gap) { _ in }
        }
    }
    #expect(throws: ContractError.invalidTiming) {
        try values.withUnsafeBufferPointer {
            try worker.process($0, interval: interval, completedHostNanoseconds: 1_000_000_001) {
                _ in
            }
        }
    }
    var invalid = values
    invalid[99] = .nan
    #expect(throws: HNRError.invalidInput) {
        try invalid.withUnsafeBufferPointer { try worker.process($0, interval: interval) { _ in } }
    }
    #expect(worker.nextInputSample == origin.source.startSample)
    var calls = 0
    let report = try values.withUnsafeBufferPointer { input in
        try worker.process(input, interval: interval, completedHostNanoseconds: 2_000_000_000) {
            output in
            calls += 1
            guard case .frame(let frame) = output.frame else {
                Issue.record("Unexpected partial frame")
                return
            }
            #expect(
                output.centerSecondsFromStreamOrigin == Double(c.causalWindowSampleCount) / 8000)
            #expect(frame.result.dependencyTiming.completedHostNanoseconds == 2_000_000_000)
            #expect(throws: HNRError.reentrantCall) { try worker.finish { _ in } }
            #expect(throws: HNRError.reentrantCall) {
                try worker.process(input, interval: interval) { _ in }
            }
            let curve = Array(frame.correlation)
            worker.cancel()
            #expect(Array(frame.correlation) == curve)
            #expect(worker.preparedBufferBytes == 0)
        }
    }
    #expect(
        calls == 1 && report.isCancelled && report.consumedSampleCount == c.causalWindowSampleCount)
    #expect(worker.nextInputSample == origin.source.startSample + Int64(c.causalWindowSampleCount))
    #expect(throws: HNRError.invalidState) { try worker.finish { _ in } }
    let nextEpoch = try origin.source.epoch.successor()
    let missing = try SourceInterval(
        epoch: origin.source.epoch, startSample: worker.nextInputSample,
        sampleCount: interval.endSample - worker.nextInputSample, sampleRate: 4000)
    try worker.reset(
        for: SourceDiscontinuity(
            previousEpoch: origin.source.epoch, nextEpoch: nextEpoch,
            reason: .droppedAudio, missingSource: missing))
    #expect(worker.nextInputSample == 0 && worker.preparedBufferBytes > 0)
    #expect(worker.origin.hostStartNanoseconds == nil && worker.origin.sourceStartSeconds == nil)
    let oldIdentity = worker.identity
    let offline = try HNRConfiguration(method: .autocorrelation, sampleRate: 4000)
    #expect(throws: HNRError.invalidConfiguration) {
        try worker.reconfigure(to: offline, epoch: nextEpoch.successor())
    }
    #expect(
        worker.identity == oldIdentity && worker.epoch == nextEpoch && worker.nextInputSample == 0)
    let replacement = try HNRConfiguration(
        method: .autocorrelation, sampleRate: 4000,
        pitchFloorHz: 500, periodsPerWindow: 2, normalization: .causalWindow)
    try worker.reconfigure(to: replacement, epoch: nextEpoch.successor())
    #expect(worker.identity != oldIdentity && worker.nextInputSample == 0)
    let short = try SourceInterval(
        epoch: worker.epoch, startSample: 0, sampleCount: 5, sampleRate: 4000)
    try [1.0, 0, -1, 0, 1].withUnsafeBufferPointer {
        try worker.process($0, interval: short) { _ in Issue.record("Warmup emitted complete frame")
        }
    }
    let completion = try worker.finish { output in
        guard case .unavailable(let frame) = output.frame else {
            Issue.record("Short support was padded")
            return
        }
        #expect(frame.timing.source == short && frame.reason == .insufficientData)
        worker.cancel()
    }
    #expect(completion.isCancelled && completion.framing.completeFrameCount == 0)
    #expect(completion.unavailableFrameCount == 1 && worker.preparedBufferBytes == 0)
}

@Test func hnrStreamingLargeHopsDoNotStitchUnanalyzedSamplesAndEmptyFinishIsExplicit() throws {
    let c = try HNRConfiguration(
        method: .forwardCrossCorrelation, sampleRate: 4000,
        pitchFloorHz: 500, periodsPerWindow: 2, hopSeconds: 0.01, normalization: .causalWindow)
    let origin = try hnrStreamOrigin(c, start: 0, seconds: nil, host: nil)
    let empty = try PreparedHNRStream<Double>(configuration: c, origin: origin).finish { _ in
        Issue.record("Empty stream emitted")
    }
    #expect(empty.framing.disposition == .empty && empty.framing.observedSource.sampleCount == 0)
    var samples = Array(repeating: 0.0, count: 107)
    samples[30] = 0.75
    samples[70] = 0.8
    samples[105] = -1
    let (outputs, completion) = try hnrStream(
        samples, profile: c, origin: origin, chunks: [3, 17, 41])
    #expect(outputs.count == 3)
    #expect(outputs.compactMap { $0.result?.dependencyTiming.source.startSample } == [0, 40, 80])
    #expect(outputs.allSatisfy { $0.result?.unavailability == .silence })
    #expect(
        completion.framing.observedSource.sampleCount == 107 && completion.framing.tailSource == nil
    )
    #expect(completion.framing.disposition == .complete && completion.unavailableFrameCount == 3)
}

@Test func hnrStreamingSourceLimitHostOverflowAndResetDiscardHistory() throws {
    let c = try HNRConfiguration(
        method: .forwardCrossCorrelation, sampleRate: 4000, pitchFloorHz: 500,
        periodsPerWindow: 2, hopSeconds: 0.01, normalization: .causalWindow)
    let size = c.causalWindowSampleCount
    let origin = try hnrStreamOrigin(c, start: Int64.max - Int64(size), seconds: nil, host: nil)
    let (frames, end) = try hnrStream(
        Array(repeating: 0.0, count: size), profile: c,
        origin: origin, chunks: [7])
    #expect(frames.count == 1 && frames[0].result?.unavailability == .silence)
    #expect(end.framing.observedSource.endSample == Int64.max)
    #expect(end.framing.tailSource == nil && end.framing.disposition == .complete)

    let overflowOrigin = try hnrStreamOrigin(c, start: 0, seconds: nil, host: UInt64.max - 1)
    let overflow = try PreparedHNRStream<Double>(configuration: c, origin: overflowOrigin)
    let one = try SourceInterval(
        epoch: overflow.epoch, startSample: 0, sampleCount: 1, sampleRate: 4000)
    #expect(throws: ContractError.invalidTiming) {
        try [0.0].withUnsafeBufferPointer { try overflow.process($0, interval: one) { _ in } }
    }
    #expect(overflow.nextInputSample == 0)
    #expect(
        try overflow.finish { _ in Issue.record("Overflowing input was consumed") }.framing
            .disposition == .empty)

    let worker = try PreparedHNRStream<Double>(configuration: c, epoch: origin.source.epoch)
    let capacity = worker.preparedBufferBytes
    let half = try SourceInterval(
        epoch: worker.epoch, startSample: 0,
        sampleCount: Int64(size / 2), sampleRate: 4000)
    try Array(repeating: 0.75, count: size / 2).withUnsafeBufferPointer {
        try worker.process($0, interval: half) { _ in Issue.record("Incomplete input emitted") }
    }
    let next = try worker.epoch.successor()
    try worker.reset(
        for: SourceDiscontinuity(
            previousEpoch: worker.epoch, nextEpoch: next,
            reason: .explicitReset))
    #expect(worker.preparedBufferBytes == capacity && worker.nextInputSample == 0)
    let full = try SourceInterval(
        epoch: next, startSample: 0, sampleCount: Int64(size), sampleRate: 4000)
    var count = 0
    try Array(repeating: 0.0, count: size).withUnsafeBufferPointer {
        try worker.process($0, interval: full) { output in
            count += 1
            guard case .frame(let frame) = output.frame else {
                Issue.record("Unexpected tail")
                return
            }
            #expect(frame.result.frameIndex == 0 && frame.result.unavailability == .silence)
            #expect(
                frame.result.normalizationAmplitudeScale == 0
                    && frame.result.frameAmplitudeScale == 0)
            #expect(throws: HNRError.reentrantCall) {
                try worker.reset(
                    for: SourceDiscontinuity(
                        previousEpoch: next, nextEpoch: next.successor(),
                        reason: .explicitReset))
            }
        }
    }
    #expect(count == 1)
}
