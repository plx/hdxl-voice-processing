import Foundation

/// Compensated signed updates reduce rounding between fresh-history rebuilds.
/// Compensation alone cannot recover arbitrarily small powers after cancellation.
private struct MaskCompensatedSum {
    var sum = 0.0
    var correction = 0.0
    var value: Double { sum + correction }
    mutating func add(_ value: Double) {
        let next = sum + value
        correction += abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
        sum = next
    }
}

/// Prepared rings, compact final features and interval scratch; no complete PCM
/// or time-by-frequency matrix is retained. The declared source bounds all arrays.
final class LTSFStorage {
    var layout: LTSFIntervalLayout
    let fft: PreparedFourierTransform<Double>
    let pcm: UnsafeMutableBufferPointer<Double>
    let window: UnsafeMutableBufferPointer<Double>
    let frame: UnsafeMutableBufferPointer<Double>
    let bins: UnsafeMutableBufferPointer<FourierBin<Double>>
    let spectra: UnsafeMutableBufferPointer<Double>
    let rawIntensity: UnsafeMutableBufferPointer<Double>
    let shortPowers: UnsafeMutableBufferPointer<Double>
    let shortLogs: UnsafeMutableBufferPointer<Double>
    private let powerSums: UnsafeMutableBufferPointer<MaskCompensatedSum>
    private let logSums: UnsafeMutableBufferPointer<MaskCompensatedSum>
    private let positiveCounts: UnsafeMutableBufferPointer<Int>
    private let maximumPowers: UnsafeMutableBufferPointer<Double>
    let flatness: UnsafeMutableBufferPointer<Double>
    let intensity: UnsafeMutableBufferPointer<Double>
    let spectralIntervals: ActivityIntervalBuffer
    let intensityIntervals: ActivityIntervalBuffer
    let combinedIntervals: ActivityIntervalBuffer
    let windowNormalization: Double
    let lookaheadFrames: Int
    private var pcmCursor = 0
    var received = 0
    var spectraCount = 0
    var featureCount = 0
    var intensityThreshold: Double?

    var scalarWorkspaceBytes: Int {
        let doubles =
            pcm.count + window.count + frame.count + spectra.count + rawIntensity.count
            + shortPowers.count + shortLogs.count + flatness.count + intensity.count
            + maximumPowers.count
        return doubles * MemoryLayout<Double>.stride + bins.count
            * MemoryLayout<FourierBin<Double>>.stride
            + (powerSums.count + logSums.count) * MemoryLayout<MaskCompensatedSum>.stride
            + positiveCounts.count * MemoryLayout<Int>.stride + fft.scalarWorkspaceBytes
            + (spectralIntervals.storage.count + intensityIntervals.storage.count
                + combinedIntervals.storage.count)
            * MemoryLayout<SpeechActivityInterval>.stride
    }

    init(layout: LTSFIntervalLayout, diagnostics: WorkerDiagnostics) throws {
        self.layout = layout
        let g = layout.spectral
        fft = try PreparedFourierTransform(
            FourierConfiguration(
                length: g.fftLength, sampleRate: layout.source.sampleRate, precision: .float64),
            diagnostics: diagnostics)
        func doubles(_ count: Int) -> UnsafeMutableBufferPointer<Double> {
            let buffer = UnsafeMutableBufferPointer<Double>.allocate(capacity: max(1, count))
            buffer.initialize(repeating: 0)
            return buffer
        }
        pcm = doubles(g.frameLength)
        window = doubles(g.frameLength)
        frame = doubles(g.frameLength)
        bins = .allocate(capacity: g.fftLength / 2 + 1)
        bins.initialize(repeating: FourierBin(real: 0))
        spectra = doubles(g.spectralRingFrameCount * g.frequencyBinCount)
        rawIntensity = doubles(g.spectralRingFrameCount)
        shortPowers = doubles(g.longFrameCount * g.frequencyBinCount)
        shortLogs = doubles(g.longFrameCount * g.frequencyBinCount)
        maximumPowers = doubles(g.frequencyBinCount)
        powerSums = .allocate(capacity: g.frequencyBinCount)
        logSums = .allocate(capacity: g.frequencyBinCount)
        powerSums.initialize(repeating: MaskCompensatedSum())
        logSums.initialize(repeating: MaskCompensatedSum())
        positiveCounts = .allocate(capacity: g.frequencyBinCount)
        positiveCounts.initialize(repeating: 0)
        flatness = doubles(layout.frameCount)
        intensity = doubles(layout.frameCount)
        spectralIntervals = ActivityIntervalBuffer(capacity: layout.frameCount + 1)
        intensityIntervals = ActivityIntervalBuffer(capacity: layout.frameCount + 1)
        combinedIntervals = ActivityIntervalBuffer(capacity: 2 * (layout.frameCount + 1))
        let denominator = g.physicalWindowSeconds / (1 / Double(layout.configuration.sampleRate))
        var energy = 0.0
        for index in 0..<g.frameLength {
            let coefficient = 0.5 * (1 - cos(2 * .pi * Double(index + 1) / denominator))
            window[index] = coefficient
            energy += coefficient * coefficient
        }
        windowNormalization = 1 / energy / Double(g.fftBinsPerSpectrogramBin)
        let shortHalf = g.shortAveragingEnabled ? layout.configuration.shortWindowSeconds / 2 : 0
        let intensityHalf = layout.configuration.relativeIntensityThresholdDB == nil ? 0 : 0.032
        lookaheadFrames = Int(ceil(max(shortHalf, intensityHalf) / layout.configuration.hopSeconds))
    }

    deinit {
        for buffer in [
            pcm, window, frame, spectra, rawIntensity, shortPowers, shortLogs, flatness, intensity,
        ] {
            buffer.deinitialize()
            buffer.deallocate()
        }
        bins.deinitialize()
        bins.deallocate()
        powerSums.deinitialize()
        powerSums.deallocate()
        logSums.deinitialize()
        logSums.deallocate()
        maximumPowers.deinitialize()
        maximumPowers.deallocate()
        positiveCounts.deinitialize()
        positiveCounts.deallocate()
    }

    func appendPCM<Sample: BinaryFloatingPoint>(_ samples: UnsafeBufferPointer<Sample>) {
        for sample in samples {
            pcm[pcmCursor] = Double(sample)
            pcmCursor += 1
            if pcmCursor == pcm.count { pcmCursor = 0 }
        }
        received += samples.count
    }

    func analyzeSpectrum() throws -> UnsafeBufferPointer<Double> {
        let g = layout.spectral
        for index in 0..<frame.count {
            frame[index] = pcm[(pcmCursor + index) % pcm.count] * window[index]
        }
        try fft.forwardReal(UnsafeBufferPointer(frame), into: bins)
        let slot = spectraCount % g.spectralRingFrameCount
        let offset = slot * g.frequencyBinCount
        for band in 0..<g.frequencyBinCount {
            let start = band * g.fftBinsPerSpectrogramBin
            var power = 0.0
            for index in start..<(start + g.fftBinsPerSpectrogramBin) {
                let bin = bins[index]
                power += bin.real * bin.real + bin.imaginary * bin.imaginary
            }
            let normalized = power * windowNormalization
            guard normalized.isFinite else { throw MaskError.nonfiniteResult }
            spectra[offset + band] = normalized
        }
        if layout.configuration.relativeIntensityThresholdDB != nil {
            let first = max(1, Int(floor(80 / g.frequencyStepHz))) - 1
            let last = min(g.frequencyBinCount, Int(ceil(8000 / g.frequencyStepHz))) - 1
            var total = 0.0
            if first <= last {
                for band in first...last { total += spectra[offset + band] }
            }
            rawIntensity[slot] = total / 4e-10
            guard rawIntensity[slot].isFinite else { throw MaskError.nonfiniteResult }
        }
        spectraCount += 1
        while featureCount + lookaheadFrames < spectraCount { try analyzeFeature() }
        return UnsafeBufferPointer(
            start: spectra.baseAddress!.advanced(by: offset), count: g.frequencyBinCount)
    }

    func finishFeatures() throws {
        while featureCount < spectraCount { try analyzeFeature() }
    }

    private func analyzeFeature() throws {
        let g = layout.spectral
        let config = layout.configuration
        let index = featureCount
        let currentSlot = index % g.longFrameCount
        let ringOffset = currentSlot * g.frequencyBinCount
        let half = config.shortWindowSeconds / 2 / config.hopSeconds
        var result = 0.0
        let rebase = index.isMultiple(of: 1024)
        for band in g.firstFlatnessBin...g.lastFlatnessBin {
            let power: Double
            if g.shortAveragingEnabled {
                guard
                    let mean = sampledLinearMean(
                        count: layout.frameCount, lower: Double(index) - half,
                        upper: Double(index) + half,
                        domainLower: -0.5, domainUpper: Double(layout.frameCount) - 0.5,
                        value: {
                            spectra[($0 % g.spectralRingFrameCount) * g.frequencyBinCount + band]
                        })
                else { throw MaskError.invalidState }
                power = mean
            } else {
                power = spectra[(index % g.spectralRingFrameCount) * g.frequencyBinCount + band]
            }
            let offset = ringOffset + band
            // A stale compensation residue may be positive, zero, or negative
            // after the largest power expires. Rebuild before that old scale can
            // dominate the smaller retained history; checking only <=0 is too late.
            // Equal/larger incoming powers retain a safe scale and need no rebuild.
            let rebuild =
                rebase
                || (index >= g.longFrameCount
                    && shortPowers[offset] >= maximumPowers[band]
                    && power < maximumPowers[band])
            if !rebuild, index >= g.longFrameCount, shortPowers[offset] > 0 {
                powerSums[band].add(-shortPowers[offset])
                logSums[band].add(-shortLogs[offset])
                positiveCounts[band] -= 1
            }
            shortPowers[offset] = power
            shortLogs[offset] = power > 0 ? log10(power) : 0
            if rebuild {
                powerSums[band] = MaskCompensatedSum()
                logSums[band] = MaskCompensatedSum()
                positiveCounts[band] = 0
                maximumPowers[band] = 0
                for previous in max(0, index - g.longFrameCount + 1)...index {
                    let location = (previous % g.longFrameCount) * g.frequencyBinCount + band
                    if shortPowers[location] > 0 {
                        powerSums[band].add(shortPowers[location])
                        logSums[band].add(shortLogs[location])
                        positiveCounts[band] += 1
                        maximumPowers[band] = max(maximumPowers[band], shortPowers[location])
                    }
                }
            } else if power > 0 {
                powerSums[band].add(power)
                logSums[band].add(shortLogs[offset])
                positiveCounts[band] += 1
                maximumPowers[band] = max(maximumPowers[band], power)
            }
            let count = positiveCounts[band]
            if count > 0 {
                let arithmetic = powerSums[band].value / Double(count)
                guard arithmetic.isFinite, arithmetic > 0 else { throw MaskError.nonfiniteResult }
                result += logSums[band].value / Double(count) - log10(arithmetic)
            }
        }
        guard result.isFinite else { throw MaskError.nonfiniteResult }
        flatness[index] = result
        if config.relativeIntensityThresholdDB != nil {
            let halfIntensity = 0.032 / config.hopSeconds
            guard
                let energy = sampledLinearMean(
                    count: layout.frameCount, lower: Double(index) - halfIntensity,
                    upper: Double(index) + halfIntensity,
                    domainLower: -0.5, domainUpper: Double(layout.frameCount) - 0.5,
                    value: { rawIntensity[$0 % g.spectralRingFrameCount] })
            else { throw MaskError.invalidState }
            let decibels = energy < 1e-30 ? -300 : 10 * log10(energy)
            guard decibels.isFinite else { throw MaskError.nonfiniteResult }
            intensity[index] = decibels
        }
        featureCount += 1
    }

    func buildIntervals() throws {
        let config = layout.configuration
        try spectralIntervals.build(layout: layout) { flatness[$0] < config.flatnessThreshold }
        spectralIntervals.clean(
            minimumSpeech: config.minimumSpeechSeconds,
            minimumNonSpeech: config.minimumNonSpeechSeconds)
        if let relative = config.relativeIntensityThresholdDB {
            let maximum = interpolatedIntensityMaximum(
                UnsafeBufferPointer(start: intensity.baseAddress, count: featureCount))
            let threshold = maximum + relative
            intensityThreshold = threshold
            try intensityIntervals.build(layout: layout) { intensity[$0] >= threshold }
            intensityIntervals.clean(
                minimumSpeech: config.minimumSpeechSeconds,
                minimumNonSpeech: config.minimumNonSpeechSeconds)
            try combinedIntervals.combine(
                spectral: spectralIntervals, intensity: intensityIntervals)
        } else {
            combinedIntervals.count = spectralIntervals.count
            for index in 0..<spectralIntervals.count {
                combinedIntervals.storage[index] = spectralIntervals.storage[index]
            }
        }
    }

    func reset() {
        pcmCursor = 0
        received = 0
        spectraCount = 0
        featureCount = 0
        intensityThreshold = nil
        spectralIntervals.count = 0
        intensityIntervals.count = 0
        combinedIntervals.count = 0
        // Every rolling value is replaced before use; index zero rebases sums.
        // Raw PCM is fully replaced before the first eligible frame is analyzed.
    }
}
