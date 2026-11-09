import Foundation

struct ShimmerKernelAmplitude {
    var timeSeconds: Double
    var amplitude: Double
    var selected: Bool
    var reliable: Bool
    var connectsToPrevious: Bool
}

struct ShimmerRequestedVariants: OptionSet {
    let rawValue: UInt8
    static let local = Self(rawValue: 1 << 0)
    static let db = Self(rawValue: 1 << 1)
    static let apq3 = Self(rawValue: 1 << 2)
    static let apq5 = Self(rawValue: 1 << 3)
    static let apq11 = Self(rawValue: 1 << 4)
    static let dda = Self(rawValue: 1 << 5)
    static let all: Self = [.local, .db, .apq3, .apq5, .apq11, .dda]

    init(rawValue: UInt8) { self.rawValue = rawValue }
    init(_ variant: ShimmerVariant) {
        self =
            switch variant {
            case .local: .local
            case .db: .db
            case .apq3: .apq3
            case .apq5: .apq5
            case .apq11: .apq11
            case .dda: .dda
            }
    }
}

struct ShimmerSum {
    private var sum = 0.0
    private var correction = 0.0
    var value: Double { sum + correction }
    mutating func add(_ value: Double) {
        let next = sum + value
        correction += abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
        sum = next
    }
}

struct ShimmerKernelResult {
    var selectedAmplitudeCount = 0
    var acceptedAmplitudeCount = 0
    var positiveAmplitudeCount = 0
    var zeroAmplitudeCount = 0
    var unreliableAmplitudeCount = 0
    var normalizationCount = 0
    var normalizationScale = 0.0
    var scaledMeanAmplitude = 0.0
    var meanAmplitude: Double?
    var pairCount = 0
    var apq3Count = 0
    var apq5Count = 0
    var apq11Count = 0
    var candidatePairCount = 0
    var candidateAPQ3Count = 0
    var candidateAPQ5Count = 0
    var candidateAPQ11Count = 0
    var belowMinimumPairCount = 0
    var aboveMaximumPairCount = 0
    var amplitudeRatioPairCount = 0
    var zeroAmplitudePairCount = 0
    var discontinuousPairCount = 0
    var acceptedPairSeconds = 0.0
    var local: Double?
    var db: Double?
    var apq3: Double?
    var apq5: Double?
    var apq11: Double?
    var dda: Double?

    func value(_ variant: ShimmerVariant) -> Double? {
        switch variant {
        case .local: local
        case .db: db
        case .apq3: apq3
        case .apq5: apq5
        case .apq11: apq11
        case .dda: dda
        }
    }
}

/// Original allocation-free amplitude equations. Values are nonnegative and
/// finite; unavailable/rejected source records remain in the ordered sequence.
/// The denominator omits the final source-eligible selected amplitude globally,
/// independently of numerator-edge rejection. Hard gaps never join windows.
enum ShimmerKernel {
    static func evaluate(
        _ amplitudes: UnsafeBufferPointer<ShimmerKernelAmplitude>,
        configuration: ShimmerConfiguration, requested: ShimmerRequestedVariants = .all
    ) -> ShimmerKernelResult {
        var result = ShimmerKernelResult()
        var lastAccepted: Int?
        // Scaling by the denominator's peak avoids sum overflow and preserves
        // gain invariance even when the actual mean would be subnormal.
        for i in amplitudes.indices where amplitudes[i].selected {
            result.selectedAmplitudeCount += 1
            guard amplitudes[i].reliable else {
                result.unreliableAmplitudeCount += 1
                continue
            }
            result.acceptedAmplitudeCount += 1
            if amplitudes[i].amplitude > 0 {
                result.positiveAmplitudeCount += 1
            } else {
                result.zeroAmplitudeCount += 1
            }
            if let lastAccepted {
                result.normalizationCount += 1
                result.normalizationScale = max(
                    result.normalizationScale, amplitudes[lastAccepted].amplitude)
            }
            lastAccepted = i
        }
        let scale = result.normalizationScale
        var meanSum = ShimmerSum()
        var localSum = ShimmerSum()
        var dbSum = ShimmerSum()
        var apq3Sum = ShimmerSum()
        var apq5Sum = ShimmerSum()
        var apq11Sum = ShimmerSum()
        var durationSum = ShimmerSum()
        var selectedRun = 0
        var eligibleRun = 0
        let computeAPQ3 = !requested.intersection([.apq3, .dda]).isEmpty

        func centralDeviation(endingAt end: Int, width: Int) -> Double {
            let center = amplitudes[end - width / 2].amplitude
            var sum = ShimmerSum()
            for j in (end - width + 1)...end {
                sum.add((amplitudes[j].amplitude - center) / scale)
            }
            return abs(sum.value) / Double(width)
        }

        for i in amplitudes.indices {
            let a = amplitudes[i]
            if a.selected {
                selectedRun += 1
                if selectedRun >= 2 { result.candidatePairCount += 1 }
                if selectedRun >= 3 { result.candidateAPQ3Count += 1 }
                if selectedRun >= 5 { result.candidateAPQ5Count += 1 }
                if selectedRun >= 11 { result.candidateAPQ11Count += 1 }
            } else {
                selectedRun = 0
            }
            if a.selected && a.reliable && i != lastAccepted && scale > 0 {
                meanSum.add(a.amplitude / scale)
            }
            var validEdge = false
            var seconds = 0.0
            if i > 0 && a.selected && amplitudes[i - 1].selected {
                let previous = amplitudes[i - 1]
                seconds = a.timeSeconds - previous.timeSeconds
                let connected = a.connectsToPrevious && a.reliable && previous.reliable
                let below = seconds < configuration.minimumPeriodSeconds
                let above = seconds > configuration.maximumPeriodSeconds
                let positive = a.amplitude > 0 && previous.amplitude > 0
                let ratioRejected =
                    positive
                    && max(a.amplitude, previous.amplitude)
                        / min(a.amplitude, previous.amplitude)
                        > configuration.maximumAmplitudeFactor
                if !connected { result.discontinuousPairCount += 1 }
                if below { result.belowMinimumPairCount += 1 }
                if above { result.aboveMaximumPairCount += 1 }
                if (a.reliable && a.amplitude == 0)
                    || (previous.reliable && previous.amplitude == 0)
                {
                    result.zeroAmplitudePairCount += 1
                }
                if ratioRejected { result.amplitudeRatioPairCount += 1 }
                validEdge = connected && !below && !above && positive && !ratioRejected
            }
            if a.selected && a.reliable && a.amplitude > 0 {
                eligibleRun = validEdge && eligibleRun > 0 ? eligibleRun + 1 : 1
            } else {
                eligibleRun = 0
            }
            if eligibleRun >= 2 {
                result.pairCount += 1
                durationSum.add(seconds)
                let previous = amplitudes[i - 1].amplitude
                if requested.contains(.local) && scale > 0 {
                    localSum.add(abs(a.amplitude - previous) / scale)
                }
                if requested.contains(.db) {
                    // log1p preserves nearly equal amplitudes and avoids taking
                    // a logarithm of a ratio rounded to one.
                    dbSum.add(
                        20 * log1p(abs(a.amplitude - previous) / min(a.amplitude, previous))
                            / log(10))
                }
            }
            if eligibleRun >= 3 {
                result.apq3Count += 1
                if computeAPQ3 && scale > 0 { apq3Sum.add(centralDeviation(endingAt: i, width: 3)) }
            }
            if eligibleRun >= 5 {
                result.apq5Count += 1
                if requested.contains(.apq5) && scale > 0 {
                    apq5Sum.add(centralDeviation(endingAt: i, width: 5))
                }
            }
            if eligibleRun >= 11 {
                result.apq11Count += 1
                if requested.contains(.apq11) && scale > 0 {
                    apq11Sum.add(centralDeviation(endingAt: i, width: 11))
                }
            }
        }
        result.acceptedPairSeconds = durationSum.value
        if result.normalizationCount > 0 {
            result.scaledMeanAmplitude = meanSum.value / Double(result.normalizationCount)
            let mean = scale * result.scaledMeanAmplitude
            // An unrepresentably small positive mean is not numerical zero.
            // Its exact scale/normalized mean remain inspectable in coverage.
            if mean > 0 || scale == 0 { result.meanAmplitude = mean }
        }
        if result.pairCount > 0 && requested.contains(.db) {
            result.db = dbSum.value / Double(result.pairCount)
        }
        let mean = result.scaledMeanAmplitude
        if mean > 0 {
            if result.pairCount > 0 && requested.contains(.local) {
                result.local = (localSum.value / Double(result.pairCount)) / mean
            }
            if result.apq3Count > 0 && computeAPQ3 {
                let apq3 = (apq3Sum.value / Double(result.apq3Count)) / mean
                if requested.contains(.apq3) { result.apq3 = apq3 }
                if requested.contains(.dda) { result.dda = 3 * apq3 }
            }
            if result.apq5Count > 0 && requested.contains(.apq5) {
                result.apq5 = (apq5Sum.value / Double(result.apq5Count)) / mean
            }
            if result.apq11Count > 0 && requested.contains(.apq11) {
                result.apq11 = (apq11Sum.value / Double(result.apq11Count)) / mean
            }
        }
        return result
    }
}
