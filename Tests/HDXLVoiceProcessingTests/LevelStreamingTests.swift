import Foundation
import Testing

@testable import HDXLVoiceProcessing

let levelEpoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!)

func levelConfiguration(
    rate: Int = 48_000, precision: AnalysisPrecision = .float64, window: Int = 128, hop: Int = 64,
    method: LevelAccumulation = .compensatedSliding,
    weighting: LevelWeighting = .bs1770Revision5(warmupSampleCount: 0),
    partial: PartialWindowPolicy = .emitUnavailable
) throws -> LevelConfiguration {
    try LevelConfiguration(
        sampleRate: rate, inputPrecision: precision, windowLength: window,
        hopLength: hop, accumulation: method, weighting: weighting, partialWindowPolicy: partial)
}

func levelInterval(
    _ count: Int, start: Int64 = 0, rate: Int = 48_000,
    epoch: StreamEpoch = levelEpoch
) throws -> SourceInterval {
    try SourceInterval(
        epoch: epoch, startSample: start, sampleCount: Int64(count), sampleRate: Double(rate))
}

func captureLevels<S: BinaryFloatingPoint & Sendable>(
    _ input: [S], configuration: LevelConfiguration, chunks: [Int] = [4096], origin: Int64 = 0
) throws -> (
    windows: [LevelWindowResult], completion: LevelCompletion, statistics: LevelExecutionStatistics
) {
    let worker = try PreparedLevelAnalyzer<S>(
        configuration: configuration, epoch: levelEpoch, startSample: origin)
    var windows: [LevelWindowResult] = []
    try input.withUnsafeBufferPointer { buffer in
        var offset = 0
        var chunk = 0
        while offset < buffer.count {
            let count = min(chunks[chunk % chunks.count], buffer.count - offset)
            let report = try worker.process(
                UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                interval: levelInterval(
                    count, start: origin + Int64(offset),
                    rate: configuration.sampleRate)
            ) {
                windows.append($0)
            }
            #expect(report.consumedSampleCount == count && !report.isCancelled)
            offset += count
            chunk += 1
        }
    }
    let report = try worker.finish { windows.append($0) }
    #expect(try worker.finish { _ in Issue.record("Repeated finish emitted a window") } == report)
    #expect(report.observedSource.sampleCount == Int64(input.count))
    return (windows, report, worker.executionStatistics)
}

private func checkLevelReference<S: BinaryFloatingPoint & Sendable>(
    _ type: S.Type, precision: AnalysisPrecision
) throws {
    let fixture = try LevelReferenceFixture.load()
    var maximumSampleError = 0.0
    var maximumEnergyError = 0.0
    for reference in fixture.cases where reference.inputPrecision == precision {
        let input = reference.input.map(S.init)
        let saved = input
        var filter = LevelKFilter(try KWeightingCoefficients(sampleRate: reference.sampleRate))
        let filtered = try input.map { try filter.process(Double($0)) }
        #expect(!filter.precisionLimited)
        for (index, expected) in zip(
            reference.selectedOutputIndices, reference.normalizedFilteredSamples)
        {
            let error = abs(filtered[index] / reference.referenceScale - expected)
            maximumSampleError = max(maximumSampleError, error)
            #expect(
                error <= fixture.nativeComparisonBudgets["normalizedSampleAbsolute"]!,
                "\(reference.name) @ \(reference.sampleRate)")
        }
        for method in [LevelAccumulation.direct, .compensatedSliding] {
            let configuration = try levelConfiguration(
                rate: reference.sampleRate, precision: precision, method: method)
            let one = try captureLevels(input, configuration: configuration)
            let split = try captureLevels(
                input, configuration: configuration, chunks: [1, 17, 64, 3, 127])
            #expect(one.windows == split.windows)
            #expect(one.completion == split.completion)
            #expect(one.completion.completeWindowCount == UInt64(reference.windows.count))
            #expect(one.windows.count == reference.windows.count + 1)
            for (actual, expected) in zip(one.windows, reference.windows) {
                #expect(actual.source.startSample == Int64(expected.startSample))
                #expect(actual.source.sampleCount == Int64(expected.sampleCount))
                #expect(actual.filterHistorySource?.startSample == 0)
                #expect(actual.filterHistorySource?.endSample == actual.source.endSample)
                let raw = try #require(actual.unweighted.energy)
                let weighted = try #require(actual.weighted?.energy)
                for (energy, expectedEnergy) in [
                    (raw, expected.unweightedNormalizedMeanSquare),
                    (weighted, expected.weightedNormalizedMeanSquare),
                ] {
                    let scale = energy.scale / reference.referenceScale
                    let normalized = scale * scale * energy.normalizedMeanSquare
                    let error = abs(normalized - expectedEnergy)
                    maximumEnergyError = max(maximumEnergyError, error)
                    #expect(
                        error <= fixture.nativeComparisonBudgets["normalizedMeanSquareAbsolute"]!,
                        "\(reference.name) @ \(reference.sampleRate): \(error)")
                }
            }
        }
        #expect(input == saved)
    }
    print(
        "K vectors \(precision): max normalized sample error=\(maximumSampleError), energy error=\(maximumEnergyError)"
    )
}

@Test func levelFloatMatchesIndependentFilterAndWindowVectors() throws {
    try checkLevelReference(Float.self, precision: .float32)
}
@Test func levelDoubleMatchesIndependentFilterAndWindowVectors() throws {
    try checkLevelReference(Double.self, precision: .float64)
}

@Test func levelKnownSignalsHaveDeclaredPeakReferenceAndCrest() throws {
    for method in [LevelAccumulation.direct, .compensatedSliding] {
        let config = try levelConfiguration(window: 480, hop: 480, method: method, weighting: .none)
        let sine = (0..<480).map { sin(2 * .pi * Double($0) / 48) }
        let full = try #require(captureLevels(sine, configuration: config).windows.first)
        let half = try #require(
            captureLevels(sine.map { $0 / 2 }, configuration: config).windows.first)
        #expect(full.peakAmplitude.estimate?.value == 1)
        #expect(abs(try #require(full.unweighted.rms.estimate?.value) - sqrt(0.5)) < 1e-14)
        #expect(
            abs(try #require(full.unweighted.digitalLevel.finiteDecibels) + 3.010299956639812)
                < 1e-12)
        #expect(abs(try #require(full.crestFactor.estimate?.value) - sqrt(2)) < 1e-14)
        #expect(abs(try #require(full.crestFactorDB.estimate?.value) - 3.010299956639812) < 1e-12)
        let difference =
            try #require(full.unweighted.digitalLevel.finiteDecibels) - #require(
                half.unweighted.digitalLevel.finiteDecibels)
        #expect(abs(difference - 6.020599913279624) < 1e-12)
        #expect(full.samplePeakDBFS.finiteDecibels == 0)
        #expect(full.weighted == nil && full.filterHistorySource == nil)
        for constant in [0.0, -0.25, 1.0, -2.0] {
            let result = try #require(
                captureLevels([Double](repeating: constant, count: 480), configuration: config)
                    .windows.first)
            #expect(result.unweighted.meanSquare.estimate?.value == constant * constant)
            #expect(result.unweighted.rms.estimate?.value == abs(constant))
            #expect(result.input.isSilent == (constant == 0))
            #expect(result.possibleClippingFraction == (abs(constant) >= 1 ? 1 : 0))
            #expect(
                result.crestFactor
                    == (constant == 0
                        ? .unavailable(.silence) : .available(try ScalarEstimate(value: 1))))
        }
    }
}

@Test func levelSlidingWindowsRecoverAfterExtremeDynamicRangeChanges() throws {
    // Independent closed form at every sample: the rectangular window contains only A or B.
    for (large, small) in [
        (1e150, 1e-150), (Double.greatestFiniteMagnitude, 1e-300),
        (1.0, Double.leastNonzeroMagnitude),
    ] {
        let n = 257
        let input = [Double](repeating: large, count: n) + [Double](repeating: small, count: n * 2)
        let config = try levelConfiguration(window: n, hop: 1, weighting: .none, partial: .discard)
        let result = try captureLevels(input, configuration: config, chunks: [13, 101, 2])
        for (index, window) in result.windows.enumerated() {
            let remaining = max(0, n - index)
            let energy = try #require(window.unweighted.energy)
            #expect(!energy.isZero)
            #expect(energy.scale == (remaining > 0 ? large : small))
            let expected = remaining > 0 ? Double(remaining) / Double(n) : 1
            #expect(abs(energy.normalizedMeanSquare - expected) < 2e-14)
        }
        #expect(result.statistics.unweightedRebaseCount > 0)
        if small * small == 0 || !(large * large).isFinite {
            #expect(result.statistics.unweightedFallbackWindowCount > 0)
        }
    }
}

@Test func levelLongStreamsAgreeWithDirectWindowsAndChunkBoundaries() throws {
    // 90,000 samples exercise many deterministic rebases and arbitrary window/hop alignment.
    let input = (0..<90_000).map { i in
        let amplitude = i < 30_000 ? 0.8 : (i < 60_000 ? 1e-9 : 0.125)
        return amplitude * (sin(Double(i) * 0.131) + 0.2 * cos(Double(i) * 0.073))
    }
    for n in [441, 2205, 17_640] {
        let direct = try levelConfiguration(
            rate: 44_100, window: n, hop: 441, method: .direct, partial: .discard)
        let recursive = try levelConfiguration(rate: 44_100, window: n, hop: 441, partial: .discard)
        let reference = try captureLevels(input, configuration: direct)
        let actual = try captureLevels(input, configuration: recursive, chunks: [1, 4096, 511, 7])
        #expect(actual.windows.count == reference.windows.count)
        for (a, b) in zip(actual.windows, reference.windows) {
            for (x, y) in [
                (a.unweighted, b.unweighted), (try #require(a.weighted), try #require(b.weighted)),
            ] {
                let xe = try #require(x.energy)
                let ye = try #require(y.energy)
                #expect(xe.scale == ye.scale)
                #expect(abs(xe.normalizedMeanSquare - ye.normalizedMeanSquare) < 2e-12)
            }
        }
    }
}
