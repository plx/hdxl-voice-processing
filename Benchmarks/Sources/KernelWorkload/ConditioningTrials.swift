#if KernelBenchmarks
    import Benchmark
    import Foundation
    import HDXLVoiceProcessing

    extension KernelCase {
        func conditioningTrial<S: BinaryFloatingPoint & Sendable>(_ type: S.Type) throws
            -> KernelTrial
        {
            let config = try conditioning(precision, source: sourceRate, target: targetRate!)
            let layout = try IntervalConditioningLayout(
                configuration: config, inputSampleCount: inputSamples)
            let worker = try KernelBenchmarkConditioner<S>(layout)
            if operation == .resamplerPrepare {
                return KernelTrial(expected: Double(worker.scalarWorkspaceBytes)) {
                    let prepared = try KernelBenchmarkConditioner<S>(layout)
                    blackHole(prepared)
                    return Double(prepared.scalarWorkspaceBytes)
                }
            }
            let mid = layout.outputSampleCount / 2
            if operation == .preEmphasis {
                let samples = Buffer(
                    (0..<layout.outputSampleCount).map { S(Double($0 % 31 - 15) / 16) })
                let a = S(config.preEmphasisCoefficient!)
                let expected = samples.values[mid] - a * samples.values[mid - 1]
                return KernelTrial(expected: Double(expected)) {
                    worker.loadOutput(samples.input)
                } run: {
                    try worker.preEmphasize()
                    return Double(worker.output(at: mid))
                }
            }
            let signal = Buffer(
                (0..<inputSamples).map {
                    S(0.5 * sin(2 * .pi * Double($0) * 350 / Double(sourceRate)))
                })
            worker.loadInput(signal.input)
            // Compare the isolated stage with the composed public entry point with emphasis disabled.
            let raw = try conditioning(
                precision, source: sourceRate, target: targetRate!, preEmphasis: nil)
            let interval = try SourceInterval(
                epoch: StreamEpoch(streamID: UUID()), startSample: 0,
                sampleCount: Int64(inputSamples), sampleRate: Double(sourceRate))
            let reference = try PreparedIntervalConditioner<S>(configuration: raw, source: interval)
            try reference.append(signal.input, interval: interval)
            var expected = Double.nan
            try reference.finish { buffer, _ in expected = Double(buffer[mid]) }
            return KernelTrial(expected: expected) {
                try worker.resample()
                return Double(worker.output(at: mid))
            }
        }

        func levelTrial<S: BinaryFloatingPoint & Sendable>(_ type: S.Type, amplitude: Double) throws
            -> KernelTrial
        {
            let signal = Buffer((0..<inputSamples).map { S(amplitude * Double($0 % 17 - 8) / 8) })
            if operation == .levelReduction {
                let maximum = signal.values.map { abs(Double($0)) }.max()!
                let normalized =
                    signal.values.reduce(0.0) { $0 + pow(Double($1) / maximum, 2) }
                    / Double(inputSamples)
                return KernelTrial(expected: maximum * sqrt(normalized)) {
                    let energy = try benchmarkLevelReduction(signal.input)
                    return energy.scale * sqrt(energy.normalizedMeanSquare)
                }
            }
            let coefficients = try KWeightingCoefficients(sampleRate: sourceRate)
            if operation == .filterPrepare {
                return KernelTrial(expected: coefficients.shelf.b0) {
                    let prepared = try KernelBenchmarkFilter(sampleRate: sourceRate)
                    blackHole(prepared)
                    return prepared.shelfGain
                }
            }
            // Independent direct form I. The production filter uses transposed direct form II.
            func reference(_ input: [Double], _ c: LevelBiquadCoefficients) -> [Double] {
                var y = Array(repeating: 0.0, count: input.count)
                for i in input.indices {
                    y[i] = c.b0 * input[i]
                    if i >= 1 { y[i] += c.b1 * input[i - 1] - c.a1 * y[i - 1] }
                    if i >= 2 { y[i] += c.b2 * input[i - 2] - c.a2 * y[i - 2] }
                }
                return y
            }
            let mid = inputSamples / 2
            let expected = reference(
                reference(signal.values.map(Double.init), coefficients.shelf), coefficients.highpass
            )[mid]
            let output = Buffer(Array(repeating: 0.0, count: inputSamples))
            var filter = try KernelBenchmarkFilter(sampleRate: sourceRate)
            return KernelTrial(expected: expected) {
                filter.reset()
            } run: {
                try filter.apply(signal.input, into: output.values)
                return output.values[mid]
            }
        }
    }
#endif
