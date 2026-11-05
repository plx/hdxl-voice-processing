import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func clockProfile(rate: Int = 10_000, window: Double, preview: Bool = true) throws
    -> CPPSProfile
{
    try CPPSProfile(
        cepstrogram: CepstrogramConfiguration(
            sourceSampleRate: rate, declaredInputBandwidthHz: Double(rate) / 2,
            conditioningMethod: preview
                ? .streamingPreview(lobes: 16, cutoffFraction: 0.9)
                : .praat7WholeInterval(interpolationDepth: 50)),
        settings: CPPSConfiguration(
            timeWindowSeconds: window, quefrencyWindowSeconds: 0,
            prominence: CPPConfiguration(fitEndSeconds: 0, fitMethod: .leastSquares)))
}

@Test func cppsClockAnchorsFollowCombinedSupportAtLargePositions() throws {
    for start in [Int64(10_000), (Int64(1) << 54) + 37] {
        for preview in [false, true] {
            for window in [0.0, 0.01] {
                for missingFirstAnchors in [false, true] {
                    let profile = try clockProfile(window: window, preview: preview)
                    let epoch = StreamEpoch(streamID: UUID())
                    let origin = try SourceInterval(
                        epoch: epoch, startSample: start, sampleCount: 0, sampleRate: 10_000)
                    let source = try SourceInterval(
                        epoch: epoch, startSample: start, sampleCount: 1240, sampleRate: 10_000)
                    let worker = try PreparedCPPS(profile: profile, origin: origin)
                    var results: [CPPSFrameResult] = []
                    try Array(repeating: 1.0, count: 513).withUnsafeBufferPointer { power in
                        for index in 0..<13 {
                            let offset = preview ? Int64(index * 20) : 0
                            let support = try SourceInterval(
                                epoch: epoch, startSample: start + offset,
                                sampleCount: preview ? 1000 : 1240, sampleRate: 10_000)
                            let anchored = !missingFirstAnchors || index >= 2
                            let timing = try AnalysisTiming(
                                source: support, includedSampleCount: support.sampleCount,
                                sourceStartSeconds: anchored ? 1000 + Double(offset) / 10_000 : nil,
                                hostStartNanoseconds: anchored
                                    ? 10_000_000_000 + UInt64(offset) * 100_000 : nil,
                                completedHostNanoseconds: 20_000_000_000)
                            let context = try CepstralFrameContext(
                                origin: origin, timing: timing, frameIndex: UInt64(index),
                                firstAnalysisSampleIndex: Int64(index * 20),
                                suppliedAnalysisSampleCount: 1000,
                                centerSecondsFromOrigin: 0.05 + Double(index) * 0.002)
                            try worker.appendPowerCepstrum(
                                power, context: context, sourceProfile: worker.sourceIdentity
                            ) { results.append($0.result) }
                        }
                    }
                    try worker.finish(source: source, expectedFrameCount: 13) {
                        results.append($0.result)
                    }
                    #expect(results.count == 13)
                    for (index, result) in results.enumerated() {
                        let first = max(0, index - worker.layout.lookaheadFrames)
                        let last = min(12, index + worker.layout.lookaheadFrames)
                        let offset = preview ? Int64(first * 20) : 0
                        let count = preview ? Int64((last - first) * 20 + 1000) : 1240
                        let timing = result.context.timing
                        #expect(timing.source.startSample == start + offset)
                        #expect(timing.source.sampleCount == count)
                        if !missingFirstAnchors || last >= 2 {
                            let expected = 1000 + Double(offset) / 10_000
                            #expect(abs(try #require(timing.sourceStartSeconds) - expected) < 1e-12)
                            #expect(
                                timing.hostStartNanoseconds == 10_000_000_000 + UInt64(offset)
                                    * 100_000)
                            #expect(
                                abs(timing.displayTimeSeconds - (expected + Double(count) / 20_000))
                                    < 1e-12)
                        } else {
                            #expect(timing.sourceStartSeconds == nil)
                            #expect(timing.hostStartNanoseconds == nil)
                        }
                        // Upstream completion does not measure the later CPPS computation.
                        #expect(timing.completedHostNanoseconds == nil)
                        #expect(result.observation != nil)
                    }
                }
            }
        }
    }
}

@Test func cppsClockAnchorsAreIndependentAndKeepExactHostIntegers() throws {
    for sourceSeconds: Double? in [nil, 1000] {
        for hostNanoseconds: UInt64? in [nil, 0, UInt64.max] {
            let profile = try clockProfile(window: 0)
            let epoch = StreamEpoch(streamID: UUID())
            let origin = try SourceInterval(
                epoch: epoch, startSample: 10_000, sampleCount: 0, sampleRate: 10_000)
            let source = try SourceInterval(
                epoch: epoch, startSample: 10_000, sampleCount: 1000, sampleRate: 10_000)
            let timing = try AnalysisTiming(
                source: source, includedSampleCount: 1000,
                sourceStartSeconds: sourceSeconds, hostStartNanoseconds: hostNanoseconds)
            let context = try CepstralFrameContext(
                origin: origin, timing: timing, frameIndex: 0,
                firstAnalysisSampleIndex: 0, suppliedAnalysisSampleCount: 1000,
                centerSecondsFromOrigin: 0.05)
            let worker = try PreparedCPPS(profile: profile, origin: origin)
            var result: CPPSFrameResult?
            try Array(repeating: 1.0, count: 513).withUnsafeBufferPointer {
                try worker.appendPowerCepstrum(
                    $0, context: context, sourceProfile: worker.sourceIdentity
                ) { result = $0.result }
            }
            let actual = try #require(result).context.timing
            #expect(actual.sourceStartSeconds == sourceSeconds)
            #expect(actual.hostStartNanoseconds == hostNanoseconds)
            #expect(
                abs(actual.displayTimeSeconds - (sourceSeconds == nil ? 1.05 : 1000.05)) < 1e-12)
        }
    }
}

@Test func cppsHostAnchorRebasingRoundsAndRejectsUnderflow() throws {
    for host: UInt64 in [40_000_000_000, 500] {
        let profile = try clockProfile(rate: 11_025, window: 0.01)
        let epoch = StreamEpoch(streamID: UUID())
        let start: Int64 = (1 << 54) + 37
        let origin = try SourceInterval(
            epoch: epoch, startSample: start, sampleCount: 0, sampleRate: 11_025)
        let worker = try PreparedCPPS(profile: profile, origin: origin)
        var first: CPPSFrameResult?
        let append = {
            try Array(repeating: 1.0, count: 513).withUnsafeBufferPointer { power in
                for index in 0..<4 {
                    let support = try SourceInterval(
                        epoch: epoch, startSample: start + Int64(index * 22),
                        sampleCount: 1103, sampleRate: 11_025)
                    let timing = try AnalysisTiming(
                        source: support, includedSampleCount: 1103,
                        sourceStartSeconds: index == 1 ? 1000 + 22.0 / 11_025 : nil,
                        hostStartNanoseconds: index == 1 ? host : nil)
                    let context = try CepstralFrameContext(
                        origin: origin, timing: timing, frameIndex: UInt64(index),
                        firstAnalysisSampleIndex: Int64(index * 20),
                        suppliedAnalysisSampleCount: 1000,
                        centerSecondsFromOrigin: 0.05 + Double(index) * 0.002)
                    try worker.appendPowerCepstrum(
                        power, context: context, sourceProfile: worker.sourceIdentity
                    ) { first = $0.result }
                }
            }
        }
        if host == 500 {
            #expect(throws: ContractError.invalidTiming, performing: append)
            #expect(first == nil && worker.emittedFrameCount == 0)
        } else {
            try append()
            let timing = try #require(first).context.timing
            // 22 source samples at 11,025 Hz span 1,995,464.8526... ns.
            #expect(timing.hostStartNanoseconds == host - 1_995_465)
            #expect(abs(try #require(timing.sourceStartSeconds) - 1000) < 1e-12)
            #expect(timing.source.startSample == start)
        }
    }
}
