private struct JitterRollingEntry {
    let period: JitterPeriodInput
    let dependency: SourceInterval
}

/// Every neighborhood belongs to its first period. Removing an old leaf thus
/// removes every numerator that began there, without joining surviving periods.
private struct JitterRollingTotals {
    var raw = JitterKernelResult()
    var reasons = JitterRejectionCounts()
    var meanSeconds = 0.0
    var absoluteSeconds = 0.0
    var rapSeconds = 0.0
    var ppq5Seconds = 0.0
    var dependencyStart: Int64 = .max

    static func + (a: Self, b: Self) -> Self {
        var r = Self()
        r.raw.selectedPeriodCount = a.raw.selectedPeriodCount + b.raw.selectedPeriodCount
        r.raw.boundedReliablePeriodCount =
            a.raw.boundedReliablePeriodCount + b.raw.boundedReliablePeriodCount
        r.raw.meanPeriodCount = a.raw.meanPeriodCount + b.raw.meanPeriodCount
        r.raw.pairCount = a.raw.pairCount + b.raw.pairCount
        r.raw.rapCount = a.raw.rapCount + b.raw.rapCount
        r.raw.ppq5Count = a.raw.ppq5Count + b.raw.ppq5Count
        r.raw.candidatePairCount = a.raw.candidatePairCount + b.raw.candidatePairCount
        r.raw.candidateRAPCount = a.raw.candidateRAPCount + b.raw.candidateRAPCount
        r.raw.candidatePPQ5Count = a.raw.candidatePPQ5Count + b.raw.candidatePPQ5Count
        r.raw.belowMinimumCount = a.raw.belowMinimumCount + b.raw.belowMinimumCount
        r.raw.aboveMaximumCount = a.raw.aboveMaximumCount + b.raw.aboveMaximumCount
        r.raw.unreliablePeriodCount = a.raw.unreliablePeriodCount + b.raw.unreliablePeriodCount
        r.raw.rejectedRatioPairCount = a.raw.rejectedRatioPairCount + b.raw.rejectedRatioPairCount
        r.raw.discontinuousPairCount = a.raw.discontinuousPairCount + b.raw.discontinuousPairCount
        r.raw.bothRatioRejectedPeriodCount =
            a.raw.bothRatioRejectedPeriodCount + b.raw.bothRatioRejectedPeriodCount
        r.raw.acceptedPeriodSeconds = a.raw.acceptedPeriodSeconds + b.raw.acceptedPeriodSeconds
        r.reasons.excluded = a.reasons.excluded + b.reasons.excluded
        r.reasons.discontinuity = a.reasons.discontinuity + b.reasons.discontinuity
        r.reasons.unreliable = a.reasons.unreliable + b.reasons.unreliable
        r.reasons.missingAcquisition = a.reasons.missingAcquisition + b.reasons.missingAcquisition
        r.reasons.invalidInput = a.reasons.invalidInput + b.reasons.invalidInput
        r.reasons.silence = a.reasons.silence + b.reasons.silence
        r.meanSeconds = a.meanSeconds + b.meanSeconds
        r.absoluteSeconds = a.absoluteSeconds + b.absoluteSeconds
        r.rapSeconds = a.rapSeconds + b.rapSeconds
        r.ppq5Seconds = a.ppq5Seconds + b.ppq5Seconds
        r.dependencyStart = min(a.dependencyStart, b.dependencyStart)
        return r
    }

    func result(requested: JitterRequestedVariants, excluded: Bool) -> JitterKernelResult {
        var r = raw
        if excluded {
            r.boundedReliablePeriodCount = 0
            r.meanPeriodCount = 0
            r.pairCount = 0
            r.rapCount = 0
            r.ppq5Count = 0
            r.unreliablePeriodCount = r.selectedPeriodCount
            r.discontinuousPairCount = r.candidatePairCount
            r.bothRatioRejectedPeriodCount = 0
            r.acceptedPeriodSeconds = 0
            return r
        }
        if r.meanPeriodCount > 0 { r.meanPeriodSeconds = meanSeconds / Double(r.meanPeriodCount) }
        if r.pairCount > 0 {
            let absolute = absoluteSeconds / Double(r.pairCount)
            if requested.contains(.absolute) { r.absolute = absolute }
            if requested.contains(.local), let mean = r.meanPeriodSeconds {
                r.local = absolute / mean
            }
        }
        if let mean = r.meanPeriodSeconds {
            if r.rapCount > 0 {
                let rap = (rapSeconds / Double(r.rapCount)) / mean
                if requested.contains(.rap) { r.rap = rap }
                if requested.contains(.ddp) { r.ddp = 3 * rap }
            }
            if r.ppq5Count > 0, requested.contains(.ppq5) {
                r.ppq5 = (ppq5Seconds / Double(r.ppq5Count)) / mean
            }
        }
        return r
    }
}

/// A ring with a balanced, nonnegative sum tree. Totals are rebuilt from child
/// nodes, never by indefinitely subtracting expired floating-point contributions.
final class JitterRollingStorage {
    let capacity: Int
    let preparedBytes: Int
    private let configuration: JitterConfiguration
    private let requested: JitterRequestedVariants
    private let entries: UnsafeMutableBufferPointer<JitterRollingEntry?>
    private let tree: UnsafeMutableBufferPointer<JitterRollingTotals>
    private let leafBase: Int
    private var head = 0
    private var preceding: JitterRollingEntry?
    private(set) var count = 0
    private(set) var nodeUpdateCount: UInt64 = 0
    var inputCount: Int { count + (preceding == nil ? 0 : 1) }

    init(configuration: JitterConfiguration, capacity: Int, requested: JitterRequestedVariants)
        throws
    {
        guard (1...JitterConfiguration.maximumPeriodCount).contains(capacity) else {
            throw JitterError.capacityExceeded
        }
        var base = 1
        while base < capacity { base *= 2 }
        let bytes =
            capacity * MemoryLayout<JitterRollingEntry?>.stride
            + 2 * base * MemoryLayout<JitterRollingTotals>.stride
        guard bytes <= 512 * 1024 * 1024 else { throw JitterError.capacityExceeded }
        self.configuration = configuration
        self.requested = requested
        self.capacity = capacity
        leafBase = base
        preparedBytes = bytes
        entries = .allocate(capacity: capacity)
        entries.initialize(repeating: nil)
        tree = .allocate(capacity: 2 * base)
        tree.initialize(repeating: JitterRollingTotals())
    }

    deinit {
        entries.deinitialize()
        entries.deallocate()
        tree.deinitialize()
        tree.deallocate()
    }

    func reset() {
        for i in entries.indices { entries[i] = nil }
        for i in tree.indices { tree[i] = JitterRollingTotals() }
        head = 0
        count = 0
        preceding = nil
        nodeUpdateCount = 0
    }

    /// Binary search makes capacity preflight independent of the number expired.
    func expirationCount(before cutoff: Double) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = low + (high - low) / 2
            if entry(mid).period.startSeconds < cutoff { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func expire(_ number: Int) {
        for _ in 0..<number {
            preceding = entries[head]
            entries[head] = nil
            update(physicalIndex: head, value: JitterRollingTotals())
            head = (head + 1) % capacity
            count -= 1
        }
        // The first survivor's left context is still the same original period;
        // its mean membership and every surviving neighborhood remain unchanged.
    }

    func append(_ period: JitterPeriodInput, dependency: SourceInterval, selected: Bool) {
        let observation = JitterRollingEntry(period: period, dependency: dependency)
        if !selected {
            assert(count == 0)
            preceding = observation
            return
        }
        assert(count < capacity)
        entries[(head + count) % capacity] = observation
        count += 1
        // The previous tail now has right-neighbor denominator context. At most
        // four earlier starts gain a complete 2/3/5-period numerator neighborhood.
        for i in max(0, count - 5)..<count {
            update(physicalIndex: (head + i) % capacity, value: contribution(i))
        }
    }

    func result(requested: JitterRequestedVariants, excluded: Bool) -> JitterKernelResult {
        tree[1].result(requested: requested, excluded: excluded)
    }

    func rejectionCounts(excluded: Bool) -> JitterRejectionCounts {
        var result = tree[1].reasons
        if excluded { result.excluded = count }
        return result
    }

    /// Conservative upstream support for the future retained range, including
    /// its immediate left context only when that context can affect the mean.
    func dependencyStart(expiring: Int) -> Int64? {
        guard expiring < count else { return nil }
        let first = entry(expiring)
        let left = expiring > 0 ? entry(expiring - 1) : preceding
        let physicalStart = (head + expiring) % capacity
        let length = count - expiring
        let firstLength = min(length, capacity - physicalStart)
        var start = rangeStart(physicalStart, physicalStart + firstLength)
        if firstLength < length { start = min(start, rangeStart(0, length - firstLength)) }
        if let left, connected(left.period, first.period) {
            start = min(start, left.dependency.startSample)
        }
        return start
    }

    private func entry(_ logicalIndex: Int) -> JitterRollingEntry {
        // Internal invariants follow from validated append/expire operations.
        entries[(head + logicalIndex) % capacity]!
    }

    private func connected(_ a: JitterPeriodInput, _ b: JitterPeriodInput) -> Bool {
        a.rejections.isEmpty && b.rejections.isEmpty && a.runID == b.runID
            && a.endSeconds == b.startSeconds
    }

    private func ratioRejected(_ a: JitterPeriodInput, _ b: JitterPeriodInput) -> Bool {
        max(a.durationSeconds, b.durationSeconds) / min(a.durationSeconds, b.durationSeconds)
            > configuration.maximumAdjacentPeriodFactor
    }

    private func bounded(_ p: JitterPeriodInput) -> Bool {
        p.durationSeconds >= configuration.minimumPeriodSeconds
            && p.durationSeconds <= configuration.maximumPeriodSeconds
    }

    private func contribution(_ index: Int) -> JitterRollingTotals {
        let observation = entry(index)
        let p = observation.period
        let left = index > 0 ? entry(index - 1) : preceding
        let right = index + 1 < count ? entry(index + 1) : nil
        var r = JitterRollingTotals()
        r.dependencyStart = observation.dependency.startSample
        r.raw.selectedPeriodCount = 1
        r.reasons.add(p.rejections)
        r.raw.belowMinimumCount = p.durationSeconds < configuration.minimumPeriodSeconds ? 1 : 0
        r.raw.aboveMaximumCount = p.durationSeconds > configuration.maximumPeriodSeconds ? 1 : 0
        r.raw.unreliablePeriodCount = p.rejections.isEmpty ? 0 : 1
        r.raw.candidatePairCount = count - index >= 2 ? 1 : 0
        r.raw.candidateRAPCount = count - index >= 3 ? 1 : 0
        r.raw.candidatePPQ5Count = count - index >= 5 ? 1 : 0
        if let right {
            r.raw.discontinuousPairCount = connected(p, right.period) ? 0 : 1
            r.raw.rejectedRatioPairCount = ratioRejected(p, right.period) ? 1 : 0
        }
        guard p.rejections.isEmpty && bounded(p) else { return r }
        r.raw.boundedReliablePeriodCount = 1
        r.raw.acceptedPeriodSeconds = p.durationSeconds
        let leftBad = left.map { connected($0.period, p) && ratioRejected($0.period, p) } ?? false
        let rightBad = right.map { connected(p, $0.period) && ratioRejected(p, $0.period) } ?? false
        if leftBad && rightBad {
            r.raw.bothRatioRejectedPeriodCount = 1
        } else {
            r.raw.meanPeriodCount = 1
            r.meanSeconds = p.durationSeconds
        }
        var eligible = 1
        while eligible < min(5, count - index) {
            let a = entry(index + eligible - 1).period
            let b = entry(index + eligible).period
            guard connected(a, b), bounded(b), !ratioRejected(a, b) else { break }
            eligible += 1
        }
        if eligible >= 2 {
            r.raw.pairCount = 1
            if !requested.intersection([.local, .absolute]).isEmpty {
                r.absoluteSeconds = abs(entry(index + 1).period.durationSeconds - p.durationSeconds)
            }
        }
        if eligible >= 3 {
            r.raw.rapCount = 1
            if !requested.intersection([.rap, .ddp]).isEmpty {
                let center = entry(index + 1).period.durationSeconds
                r.rapSeconds =
                    abs(
                        (p.durationSeconds - center)
                            + (entry(index + 2).period.durationSeconds - center)) / 3
            }
        }
        if eligible >= 5 {
            r.raw.ppq5Count = 1
            if requested.contains(.ppq5) {
                let center = entry(index + 2).period.durationSeconds
                var sum = JitterSum()
                sum.add(p.durationSeconds - center)
                sum.add(entry(index + 1).period.durationSeconds - center)
                sum.add(entry(index + 3).period.durationSeconds - center)
                sum.add(entry(index + 4).period.durationSeconds - center)
                r.ppq5Seconds = abs(sum.value) / 5
            }
        }
        return r
    }

    private func update(physicalIndex: Int, value: JitterRollingTotals) {
        var index = leafBase + physicalIndex
        tree[index] = value
        nodeUpdateCount = saturatingAdd(nodeUpdateCount)
        while index > 1 {
            index /= 2
            tree[index] = tree[index * 2] + tree[index * 2 + 1]
            nodeUpdateCount = saturatingAdd(nodeUpdateCount)
        }
    }

    private func rangeStart(_ lower: Int, _ upper: Int) -> Int64 {
        var lower = lower + leafBase
        var upper = upper + leafBase
        var result: Int64 = .max
        while lower < upper {
            if lower % 2 == 1 {
                result = min(result, tree[lower].dependencyStart)
                lower += 1
            }
            if upper % 2 == 1 {
                upper -= 1
                result = min(result, tree[upper].dependencyStart)
            }
            lower /= 2
            upper /= 2
        }
        return result
    }
}
