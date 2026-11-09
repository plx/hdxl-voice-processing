/// A raw adjacent interval stays in the sequence even when rejected. Reliability
/// and continuity come from the caller/track graph; numerical bounds are separate.
struct JitterKernelPeriod {
    var durationSeconds: Double
    var selected: Bool
    var reliable: Bool
    var connectsToPrevious: Bool
}

struct JitterRequestedVariants: OptionSet {
    let rawValue: UInt8
    static let local = Self(rawValue: 1 << 0)
    static let absolute = Self(rawValue: 1 << 1)
    static let rap = Self(rawValue: 1 << 2)
    static let ppq5 = Self(rawValue: 1 << 3)
    static let ddp = Self(rawValue: 1 << 4)
    static let all: Self = [.local, .absolute, .rap, .ppq5, .ddp]

    init(rawValue: UInt8) { self.rawValue = rawValue }
    init(_ variant: JitterVariant) {
        self =
            switch variant {
            case .local: .local
            case .absolute: .absolute
            case .rap: .rap
            case .ppq5: .ppq5
            case .ddp: .ddp
            }
    }
}

/// Positive contributions use compensated accumulation. The rolling worker must
/// maintain bounded totals separately, rather than subtracting these sums forever.
struct JitterSum {
    private var sum = 0.0
    private var correction = 0.0
    var value: Double { sum + correction }

    mutating func add(_ value: Double) {
        let next = sum + value
        correction += abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
        sum = next
    }
}

struct JitterKernelResult {
    var selectedPeriodCount = 0
    var boundedReliablePeriodCount = 0
    var meanPeriodCount = 0
    var pairCount = 0
    var rapCount = 0
    var ppq5Count = 0
    var candidatePairCount = 0
    var candidateRAPCount = 0
    var candidatePPQ5Count = 0
    var belowMinimumCount = 0
    var aboveMaximumCount = 0
    var unreliablePeriodCount = 0
    var rejectedRatioPairCount = 0
    var discontinuousPairCount = 0
    var bothRatioRejectedPeriodCount = 0
    var acceptedPeriodSeconds = 0.0
    var meanPeriodSeconds: Double?
    var local: Double?
    var absolute: Double?
    var rap: Double?
    var ppq5: Double?
    var ddp: Double?

    func value(_ variant: JitterVariant) -> Double? {
        switch variant {
        case .local: local
        case .absolute: absolute
        case .rap: rap
        case .ppq5: ppq5
        case .ddp: ddp
        }
    }
}

/// Allocation-free original equations. Input validation belongs to the prepared
/// API boundary; records must have finite positive durations. Selection describes
/// the query only. A reliability failure is a hard continuity boundary, whereas
/// an out-of-bounds but otherwise reliable period still supplies denominator
/// ratio context, as established by the direct reference fixtures.
enum JitterKernel {
    static func evaluate(
        _ periods: UnsafeBufferPointer<JitterKernelPeriod>, configuration: JitterConfiguration,
        requested: JitterRequestedVariants = .all
    ) -> JitterKernelResult {
        let lower = configuration.minimumPeriodSeconds
        let upper = configuration.maximumPeriodSeconds
        let maximumFactor = configuration.maximumAdjacentPeriodFactor
        func bounded(_ i: Int) -> Bool {
            (lower...upper).contains(periods[i].durationSeconds)
        }
        func connected(_ right: Int) -> Bool {
            right > 0 && periods[right].connectsToPrevious
                && periods[right - 1].reliable && periods[right].reliable
        }
        func ratioRejected(_ right: Int) -> Bool {
            let a = periods[right - 1].durationSeconds
            let b = periods[right].durationSeconds
            return max(a, b) / min(a, b) > maximumFactor
        }
        var result = JitterKernelResult()
        var meanSum = JitterSum()
        var acceptedDuration = JitterSum()
        var absoluteSum = JitterSum()
        var rapSum = JitterSum()
        var ppq5Sum = JitterSum()
        let computeLocal = !requested.intersection([.local, .absolute]).isEmpty
        let computeRAP = !requested.intersection([.rap, .ddp]).isEmpty
        // Runs of complete query periods determine candidate counts; eligible
        // runs additionally require reliability, bounds and every connecting edge.
        var selectedRun = 0
        var eligibleRun = 0
        for i in periods.indices {
            let p = periods[i]
            if p.selected {
                result.selectedPeriodCount += 1
                selectedRun += 1
                if selectedRun >= 2 { result.candidatePairCount += 1 }
                if selectedRun >= 3 { result.candidateRAPCount += 1 }
                if selectedRun >= 5 { result.candidatePPQ5Count += 1 }
                if p.durationSeconds < lower { result.belowMinimumCount += 1 }
                if p.durationSeconds > upper { result.aboveMaximumCount += 1 }
                if !p.reliable { result.unreliablePeriodCount += 1 }
                if i > 0 && periods[i - 1].selected {
                    if !connected(i) { result.discontinuousPairCount += 1 }
                    if ratioRejected(i) { result.rejectedRatioPairCount += 1 }
                }
            } else {
                selectedRun = 0
            }
            let included = p.selected && p.reliable && bounded(i)
            if included {
                result.boundedReliablePeriodCount += 1
                acceptedDuration.add(p.durationSeconds)
                let leftBad = connected(i) && ratioRejected(i)
                let rightBad = i + 1 < periods.count && connected(i + 1) && ratioRejected(i + 1)
                if leftBad && rightBad {
                    result.bothRatioRejectedPeriodCount += 1
                } else {
                    result.meanPeriodCount += 1
                    meanSum.add(p.durationSeconds)
                }
                eligibleRun =
                    eligibleRun > 0 && connected(i) && !ratioRejected(i) ? eligibleRun + 1 : 1
            } else {
                eligibleRun = 0
            }
            if eligibleRun >= 2 {
                result.pairCount += 1
                if computeLocal {
                    absoluteSum.add(abs(p.durationSeconds - periods[i - 1].durationSeconds))
                }
            }
            if eligibleRun >= 3 {
                result.rapCount += 1
                if computeRAP {
                    let center = periods[i - 1].durationSeconds
                    let difference =
                        (periods[i - 2].durationSeconds - center)
                        + (p.durationSeconds - center)
                    rapSum.add(abs(difference) / 3)
                }
            }
            if eligibleRun >= 5 {
                result.ppq5Count += 1
                if requested.contains(.ppq5) {
                    let center = periods[i - 2].durationSeconds
                    var difference = JitterSum()
                    difference.add(periods[i - 4].durationSeconds - center)
                    difference.add(periods[i - 3].durationSeconds - center)
                    difference.add(periods[i - 1].durationSeconds - center)
                    difference.add(p.durationSeconds - center)
                    ppq5Sum.add(abs(difference.value) / 5)
                }
            }
        }
        result.acceptedPeriodSeconds = acceptedDuration.value
        if result.meanPeriodCount > 0 {
            result.meanPeriodSeconds = meanSum.value / Double(result.meanPeriodCount)
        }
        if result.pairCount > 0 && computeLocal {
            let absolute = absoluteSum.value / Double(result.pairCount)
            if requested.contains(.absolute) { result.absolute = absolute }
            if requested.contains(.local), let mean = result.meanPeriodSeconds, mean > 0 {
                result.local = absolute / mean
            }
        }
        if let mean = result.meanPeriodSeconds, mean > 0 {
            if result.rapCount > 0 && computeRAP {
                let rap = (rapSum.value / Double(result.rapCount)) / mean
                if requested.contains(.rap) { result.rap = rap }
                if requested.contains(.ddp) { result.ddp = 3 * rap }
            }
            if result.ppq5Count > 0 && requested.contains(.ppq5) {
                result.ppq5 = (ppq5Sum.value / Double(result.ppq5Count)) / mean
            }
        }
        return result
    }
}
