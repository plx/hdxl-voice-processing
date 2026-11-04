import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func previewLayout(
    source: Int = 16_000, target: Int = 10_000,
    precision: AnalysisPrecision = .float64, emphasis: Double? = 50, capacity: Int = 256,
    lobes: Int = 32, cutoff: Double = 0.9
) throws -> PreviewConditioningLayout {
    try PreviewConditioningLayout(
        configuration: testConditioningConfiguration(
            source: source, target: target,
            precision: precision, emphasis: emphasis,
            method: .streamingPreview(lobes: lobes, cutoffFraction: cutoff)),
        outputBlockCapacity: capacity)
}

/// Independent, uncached binary64 convolution on absolute target times. No native phase clock,
/// coefficient cache, ring, pre-emphasis state, or production geometry is used by this oracle.
private func previewOracle(
    _ source: [Double], sourceRate: Int, targetRate: Int,
    lobes: Int, cutoffFraction: Double, emphasis: Double?
) -> [Double] {
    let rate = Double(targetRate) / Double(sourceRate)
    let half = Int(ceil(Double(lobes) / min(1, rate)))
    let cutoff = cutoffFraction * min(1, rate)
    let count = source.count * targetRate / sourceRate
    var result: [Double] = []
    for j in 0..<count {
        let center = (Double(j) + 0.5) / rate - 0.5
        let base = Int(floor(center))
        var sum = 0.0
        var weight = 0.0
        for n in (base - half)...(base + half) {
            let x = Double(n) - center
            guard abs(x) < Double(half) else { continue }
            let window =
                0.42 + 0.5 * cos(.pi * x / Double(half)) + 0.08 * cos(2 * .pi * x / Double(half))
            let kernel = (x == 0 ? cutoff : sin(.pi * cutoff * x) / (.pi * x)) * window
            weight += kernel
            if source.indices.contains(n) { sum += source[n] * kernel }
        }
        result.append(sum / weight)
    }
    if let emphasis {
        let alpha = exp(-2 * .pi * emphasis / Double(targetRate))
        for j in result.indices.dropFirst().reversed() { result[j] -= alpha * result[j - 1] }
    }
    return result
}

private func capturePreview<S: BinaryFloatingPoint & Sendable>(
    _ source: [S], layout: PreviewConditioningLayout,
    chunks: [Int], origin: Int64 = 0
) throws -> (values: [S], blocks: [PreviewConditionedBlock]) {
    let plan = try PreparedPreviewConditioner<S>(
        layout: layout, epoch: conditioningEpoch, startSample: origin)
    var values: [S] = []
    var blocks: [PreviewConditionedBlock] = []
    func emit(_ samples: UnsafeBufferPointer<S>, _ record: PreviewConditionedBlock) {
        #expect(record.outputStartIndex == Int64(values.count))
        #expect(record.outputSampleCount == samples.count)
        #expect(record.timing.source.startSample >= origin)
        #expect(record.timing.source.endSample <= origin + plan.receivedSampleCount)
        #expect(record.timing.includedSampleCount == record.timing.source.sampleCount)
        #expect(
            record.usesTrailingZeroExtension
                == (record.isFinalizing
                    && layout.position(record.outputStartIndex + Int64(samples.count) - 1).left
                        + Int64(layout.filterRadius) >= record.deliveryInputSampleCount)
        )
        #expect(
            record.timing.effectiveDelaySeconds <= layout.maximumFilterLookaheadSeconds
                + Double(samples.count) / Double(layout.configuration.targetSampleRate) + 1e-12)
        values.append(contentsOf: samples)
        blocks.append(record)
    }
    try source.withUnsafeBufferPointer { buffer in
        var offset = 0
        var part = 0
        while offset < source.count {
            let count = min(chunks[part % chunks.count], source.count - offset)
            let report = try plan.process(
                UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                interval: conditioningInterval(
                    count, start: origin + Int64(offset),
                    rate: layout.configuration.sourceSampleRate), emit: emit)
            #expect(report.consumedSampleCount == count)
            offset += count
            part += 1
        }
    }
    let completion = try plan.finish(emit: emit)
    #expect(completion.outputSampleCount == Int64(values.count))
    #expect(completion.hasOutput == !values.isEmpty)
    #expect(completion.source.sampleCount == Int64(source.count))
    #expect(!completion.isCancelled)
    #expect(try plan.finish { _, _ in Issue.record("Repeated preview finish") } == completion)
    return (values, blocks)
}

private func checkPreview<S: BinaryFloatingPoint & Sendable>(
    _ type: S.Type, precision: AnalysisPrecision
) throws {
    for (fs, ft) in [
        (16_000, 10_000), (44_100, 10_000), (48_000, 10_000),
        (44_100, 11_000), (48_000, 16_000), (16_000, 32_000), (16_000, 16_000),
        (192_000, 4000), (4000, 192_000),
    ] {
        let layout = try previewLayout(source: fs, target: ft, precision: precision, capacity: 37)
        for count in [0, 1, 2, 7, 257] {
            let input = (0..<count).map {
                S(0.2 * sin(Double($0) * 1.234) + 0.3 * cos(Double($0) * 0.037))
            }
            let oracle = previewOracle(
                input.map { Double($0) }, sourceRate: fs, targetRate: ft,
                lobes: 32, cutoffFraction: 0.9, emphasis: 50)
            let one = try capturePreview(input, layout: layout, chunks: [max(1, count)])
            #expect(one.values.count == oracle.count)
            let error = zip(one.values, oracle).map { abs(Double($0) - $1) }.max() ?? 0
            #expect(
                error < (precision == .float64 ? 2e-12 : 2e-6),
                "\(fs)->\(ft) N=\(count) error=\(error)")
            for chunks in [[1], [17, 64, 3, 127]] {
                let split = try capturePreview(
                    input, layout: layout, chunks: chunks, origin: Int64.max - Int64(count))
                #expect(split.values == one.values)
            }
            if let block = one.blocks.first {
                #expect(block.usesLeadingZeroExtension)
                #expect(
                    try JSONDecoder().decode(
                        PreviewConditionedBlock.self, from: JSONEncoder().encode(block)) == block)
            }
            if let block = one.blocks.last { #expect(block.usesTrailingZeroExtension) }
        }
    }
}

@Test func previewDoubleMatchesIndependentConvolutionAndPartitions() throws {
    try checkPreview(Double.self, precision: .float64)
}
@Test func previewFloatMatchesIndependentConvolutionAndPartitions() throws {
    try checkPreview(Float.self, precision: .float32)
}

@Test func previewPassbandPhaseDCAndAliasRejection() throws {
    for fs in [16_000, 44_100, 48_000] {
        let layout = try previewLayout(source: fs, emphasis: nil)
        let count = fs / 4
        let dc = try capturePreview(
            [Double](repeating: 0.25, count: count), layout: layout, chunks: [64, 1024])
        let validDC = dc.blocks.filter { !$0.usesBoundaryExtension }
        #expect(!validDC.isEmpty)
        for block in validDC {
            let first = Int(block.outputStartIndex)
            #expect(
                dc.values[first..<(first + block.outputSampleCount)].allSatisfy {
                    abs($0 - 0.25) < 2e-15
                })
        }
        for frequency in [100.0, 4000, 5500, Double(fs) * 0.49] {
            let input = (0..<count).map {
                sin(2 * .pi * frequency * (Double($0) + 0.5) / Double(fs) + 0.23)
            }
            let output = try capturePreview(input, layout: layout, chunks: [64, 127, 512, 1024])
            var maximumError = 0.0
            var energy = 0.0
            var used = 0
            for block in output.blocks where !block.usesBoundaryExtension {
                for j in Int(
                    block.outputStartIndex)..<(Int(block.outputStartIndex) + block.outputSampleCount)
                {
                    let expected = sin(2 * .pi * frequency * (Double(j) + 0.5) / 10_000 + 0.23)
                    maximumError = max(maximumError, abs(output.values[j] - expected))
                    energy += output.values[j] * output.values[j]
                    used += 1
                }
            }
            #expect(used > 1000)
            if frequency <= 4000 {
                #expect(maximumError < 0.0002, "Passband gain/phase error \(maximumError)")
            } else {
                #expect(sqrt(2 * energy / Double(used)) < 0.00032, "Less than 70 dB rejection")
            }
        }
    }
}

@Test func previewIntegerClockHasNoLongRunDriftOrAbsoluteOriginLoss() throws {
    let layout = try previewLayout(source: 44_100, emphasis: nil)
    for n: Int64 in [
        0, 1, 440, 441, 442, 2_646_000, PreviewConditioningLayout.maximumInputSampleCount,
    ] {
        let expected = n / 441 * 100 + n % 441 * 100 / 441
        #expect(try layout.outputSampleCount(inputSampleCount: n) == expected)
        if expected > 0 {
            let position = layout.position(expected - 1)
            // Reverse the exact rational map in integer space, with all products below Int64.max.
            #expect(
                2 * 100 * position.left + position.remainder == (2 * (expected - 1) + 1) * 441 - 100
            )
        }
    }
    let plan = try PreparedPreviewConditioner<Double>(
        layout: layout, epoch: conditioningEpoch,
        startSample: Int64.max - 2_646_000)
    let zeros = [Double](repeating: 0, count: 997)
    var offset = 0
    var outputs: Int64 = 0
    func emit(_ samples: UnsafeBufferPointer<Double>, _ record: PreviewConditionedBlock) {
        #expect(record.outputStartIndex == outputs)
        #expect(samples.allSatisfy { $0 == 0 })
        outputs += Int64(samples.count)
    }
    try zeros.withUnsafeBufferPointer { buffer in
        while offset < 2_646_000 {
            let count = min(buffer.count, 2_646_000 - offset)
            try plan.process(
                UnsafeBufferPointer(rebasing: buffer[..<count]),
                interval: conditioningInterval(
                    count, start: plan.origin.startSample + Int64(offset), rate: 44_100), emit: emit
            )
            offset += count
        }
    }
    let final = try plan.finish(emit: emit)
    #expect(outputs == 600_000)
    #expect(final.source.endSample == Int64.max)
    #expect(throws: ConditioningError.capacityExceeded) {
        try layout.outputSampleCount(
            inputSampleCount: PreviewConditioningLayout.maximumInputSampleCount + 1)
    }
}

@Test func previewSupportAndDelayHaveIndependentSourceCoordinates() throws {
    let layout = try previewLayout(capacity: 1)
    let result = try capturePreview(
        [Double](repeating: 1, count: 257), layout: layout, chunks: [257], origin: 1000)
    let first = try #require(result.blocks.first)
    #expect(first.outputStartIndex == 0)
    #expect(try first.timing.source == conditioningInterval(53, start: 1000))
    #expect(first.deliveryInputSampleCount == 53)
    #expect(abs(first.timing.effectiveDelaySeconds - (53.0 / 16_000 - 0.5 / 10_000)) < 1e-15)
    let middle = result.blocks[100]
    #expect(middle.outputStartIndex == 100)
    // Current resample needs [108,213); raw pre-emphasis also needs previous [106,211).
    #expect(try middle.timing.source == conditioningInterval(107, start: 1106))
    #expect(!middle.usesBoundaryExtension)
    #expect(middle.deliveryInputSampleCount == 213)
    let last = try #require(result.blocks.last)
    #expect(last.outputStartIndex == 159)
    #expect(try last.timing.source == conditioningInterval(56, start: 1201))
    #expect(last.usesTrailingZeroExtension)
    #expect(!last.usesLeadingZeroExtension)
    #expect(last.deliveryInputSampleCount == 257)
    #expect(abs(last.timing.effectiveDelaySeconds - (257.0 / 16_000 - 159.5 / 10_000)) < 1e-15)
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(middle)) as? [String: Any])
    object["usesTrailingZeroExtension"] = true
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            PreviewConditionedBlock.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@Test func previewResetRejectsGapsAndRestoresBothFilterHistories() throws {
    let layout = try previewLayout(capacity: 17)
    let plan = try PreparedPreviewConditioner<Double>(layout: layout, epoch: conditioningEpoch)
    let samples = (0..<257).map { 0.2 * sin(Double($0) * 0.37) }
    let expected = try capturePreview(samples, layout: layout, chunks: [257]).values
    try [1.0, 2, 3].withUnsafeBufferPointer { buffer in
        try plan.process(buffer, interval: conditioningInterval(3)) { _, _ in
            Issue.record("Too early")
        }
        #expect(throws: ConditioningError.unexpectedInterval) {
            try plan.process(buffer, interval: conditioningInterval(3, start: 4)) { _, _ in }
        }
        #expect(throws: ConditioningError.unexpectedInterval) {
            try plan.process(
                buffer,
                interval: conditioningInterval(3, start: 3, epoch: conditioningEpoch.successor())
            ) { _, _ in }
        }
        #expect(throws: ConditioningError.unexpectedInterval) {
            try plan.process(buffer, interval: conditioningInterval(3, start: 3, rate: 48_000)) {
                _, _ in
            }
        }
    }
    #expect(throws: ConditioningError.nonfiniteInput) {
        try [0.0, .infinity].withUnsafeBufferPointer {
            try plan.process($0, interval: conditioningInterval(2, start: 3)) { _, _ in }
        }
    }
    #expect(plan.receivedSampleCount == 3)
    let bytes = plan.scalarWorkspaceBytes
    let next = try conditioningEpoch.successor()
    try plan.reset(epoch: next, startSample: 1000)
    #expect(plan.scalarWorkspaceBytes == bytes)
    var result: [Double] = []
    func emit(_ values: UnsafeBufferPointer<Double>, _ record: PreviewConditionedBlock) {
        #expect(record.origin.epoch == next)
        #expect(record.origin.startSample == 1000)
        result.append(contentsOf: values)
    }
    _ = try samples.withUnsafeBufferPointer {
        try plan.process(
            $0, interval: conditioningInterval(samples.count, start: 1000, epoch: next), emit: emit)
    }
    try plan.finish(emit: emit)
    #expect(result == expected)
    #expect(throws: ConditioningError.invalidState) {
        _ = try samples.withUnsafeBufferPointer {
            try plan.process(
                $0, interval: conditioningInterval(samples.count, start: 1257, epoch: next),
                emit: emit)
        }
    }
    try plan.reset(epoch: next, startSample: 2000)
    #expect(plan.receivedSampleCount == 0)
    #expect(plan.emittedSampleCount == 0)
}

@Test func previewCancellationAndReentrancyPreserveCurrentBorrow() throws {
    let layout = try previewLayout(capacity: 1)
    for duringFinish in [false, true] {
        let plan = try PreparedPreviewConditioner<Double>(layout: layout, epoch: conditioningEpoch)
        let samples = [Double](repeating: 0.25, count: duringFinish ? 7 : 1024)
        var callbacks = 0
        func emit(_ values: UnsafeBufferPointer<Double>, _ record: PreviewConditionedBlock) {
            callbacks += 1
            let saved = Array(values)
            #expect(throws: ConditioningError.reentrantCall) {
                try plan.reset(epoch: conditioningEpoch)
            }
            #expect(throws: ConditioningError.reentrantCall) { try plan.finish { _, _ in } }
            #expect(throws: ConditioningError.reentrantCall) {
                try [Double]().withUnsafeBufferPointer {
                    try plan.process(
                        $0, interval: conditioningInterval(0, start: plan.receivedSampleCount)
                    ) { _, _ in }
                }
            }
            plan.cancel()
            #expect(Array(values) == saved)
            #expect(plan.scalarWorkspaceBytes == 0)
        }
        let report = try samples.withUnsafeBufferPointer {
            try plan.process($0, interval: conditioningInterval(samples.count), emit: emit)
        }
        if duringFinish {
            #expect(callbacks == 0)
            let final = try plan.finish(emit: emit)
            #expect(final.isCancelled)
            #expect(final.outputSampleCount == 1)
        } else {
            #expect(report.isCancelled)
            #expect(report.consumedSampleCount == 53)
            #expect(report.emittedSampleCount == 1)
        }
        #expect(callbacks == 1)
        #expect(plan.isCancelled)
        #expect(throws: ConditioningError.invalidState) { try plan.finish { _, _ in } }
    }
}

@Test func previewExplicitQualityLimitsAndBoundaryRecipes() throws {
    #expect(throws: ConditioningError.capacityExceeded) {
        try previewLayout(source: 192_000, target: 4001, lobes: 64)
    }
    #expect(throws: ConditioningError.capacityExceeded) { try previewLayout(capacity: 0) }
    #expect(throws: ConditioningError.invalidQuality) {
        try PreviewConditioningLayout(configuration: testConditioningConfiguration())
    }
    #expect(throws: ConditioningError.precisionMismatch) {
        try PreparedPreviewConditioner<Float>(layout: previewLayout(), epoch: conditioningEpoch)
    }
    var seed: UInt32 = 31
    let noise: [Double] = (0..<257).map { _ in
        seed = 1_664_525 &* seed &+ 1_013_904_223
        return (Double(seed) - 2_147_483_648) / 4_294_967_296
    }
    let recipes = [
        (0..<257).map { $0 == 0 ? 1.0 : 0 },
        (0..<257).map { $0 == 128 ? 1.0 : 0 },
        (0..<257).map { $0 < 128 ? 0.0 : 0.25 },
        (0..<257).map { sin(.pi * 0.99 * Double($0 * $0) / 257) }, noise,
    ]
    for (lobes, cutoff) in [(8, 0.5), (32, 0.9), (64, 0.98)] {
        for emphasis: Double? in [nil, 0, 50, 5000] {
            let layout = try previewLayout(
                emphasis: emphasis, capacity: 37, lobes: lobes, cutoff: cutoff)
            for source in recipes {
                let expected = previewOracle(
                    source, sourceRate: 16_000, targetRate: 10_000,
                    lobes: lobes, cutoffFraction: cutoff, emphasis: emphasis)
                let result = try capturePreview(source, layout: layout, chunks: [64, 7, 1, 1024])
                #expect(zip(result.values, expected).allSatisfy { abs($0 - $1) < 2e-13 })
                let doubled = try capturePreview(
                    source.map { 2 * $0 }, layout: layout, chunks: [257])
                #expect(zip(result.values, doubled.values).allSatisfy { $0 * 2 == $1 })
            }
        }
    }
}

@Test func previewDelayRetainsSubsamplePrecisionAtMaximumContinuityLength() throws {
    let layout = try previewLayout(source: 4000, target: 192_000, capacity: 1)
    let n = PreviewConditioningLayout.maximumInputSampleCount
    let total = try layout.outputSampleCount(inputSampleCount: n)
    let record = try PreviewConditionedBlock(
        layout: layout,
        origin: conditioningInterval(0, rate: 4000), outputStartIndex: total - 1,
        outputSampleCount: 1, deliveryInputSampleCount: n, isFinalizing: true)
    #expect(abs(record.timing.effectiveDelaySeconds - 0.5 / 192_000) < 1e-18)
    #expect(record.usesTrailingZeroExtension)
    #expect(
        try JSONDecoder().decode(PreviewConditionedBlock.self, from: JSONEncoder().encode(record))
            == record)
}

@Test func previewNonfiniteOutputFailsUntilExplicitReset() throws {
    let layout = try previewLayout(target: 16_000, emphasis: nil)
    let plan = try PreparedPreviewConditioner<Double>(layout: layout, epoch: conditioningEpoch)
    // The step response overshoots a finite input whose magnitude already reaches the type limit.
    let extreme = [Double](repeating: .greatestFiniteMagnitude, count: 100)
    #expect(throws: ConditioningError.nonfiniteResult) {
        try extreme.withUnsafeBufferPointer {
            try plan.process($0, interval: conditioningInterval(extreme.count)) { _, _ in
                Issue.record("Overflowing pending block must not be emitted")
            }
        }
    }
    #expect(throws: ConditioningError.invalidState) { try plan.finish { _, _ in } }
    try plan.reset(epoch: conditioningEpoch.successor())
    var output: [Double] = []
    let input = [Double](repeating: 0.25, count: 100)
    _ = try input.withUnsafeBufferPointer {
        try plan.process($0, interval: conditioningInterval(100, epoch: plan.origin.epoch)) {
            values, _ in
            output.append(contentsOf: values)
        }
    }
    try plan.finish { values, _ in output.append(contentsOf: values) }
    #expect(try output == capturePreview(input, layout: layout, chunks: [100]).values)
}
