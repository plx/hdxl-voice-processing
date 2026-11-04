import Foundation

final class LevelSampleRing {
    let capacity: Int
    let values: UnsafeMutablePointer<Double>
    private(set) var cursor = 0
    private(set) var count = 0
    init(capacity: Int) {
        self.capacity = capacity
        values = .allocate(capacity: capacity)
        values.initialize(repeating: 0, count: capacity)
    }
    deinit {
        values.deinitialize(count: capacity)
        values.deallocate()
    }
    func append(_ value: Double) {
        values[cursor] = value
        cursor = (cursor + 1) % capacity
        count = min(capacity, count + 1)
    }
    func suffixValue(_ index: Int, count requestedCount: Int) -> Double {
        values[(cursor - requestedCount + index + capacity) % capacity]
    }
    func reset() {
        cursor = 0
        count = 0
    }
}

/// A compensated sliding sum with a deterministic rebase every window-length updates.
/// A monotonic queue tracks the exact sample peak. Extreme squares use the scaled fallback.
final class LevelWindowAccumulator {
    private struct PeakEntry {
        var position: Int64 = 0
        var magnitude = 0.0
    }
    let ring: LevelSampleRing
    private let peaks: UnsafeMutablePointer<PeakEntry>
    private var peakHead = 0
    private var peakCount = 0
    private var sequence: Int64 = 0
    private var updatesSinceRebase = 0
    private var sum = LevelCompensatedSum()
    private var unsafeSquares = 0
    private var nonzeroSamples = 0
    private var atFullScale = 0
    private var overFullScale = 0
    private var subnormal = 0
    private let subnormalThreshold: Double
    private let method: LevelAccumulation
    private(set) var fallbackWindows: UInt64 = 0
    private(set) var rebaseCount: UInt64 = 0

    var bufferBytes: Int {
        ring.capacity * (MemoryLayout<Double>.stride + MemoryLayout<PeakEntry>.stride)
    }

    init(capacity: Int, subnormalThreshold: Double, method: LevelAccumulation) {
        ring = LevelSampleRing(capacity: capacity)
        peaks = .allocate(capacity: capacity)
        peaks.initialize(repeating: PeakEntry(), count: capacity)
        self.subnormalThreshold = subnormalThreshold
        self.method = method
    }
    deinit {
        peaks.deinitialize(count: ring.capacity)
        peaks.deallocate()
    }

    private func square(_ value: Double) -> (value: Double, unsafe: Int) {
        let squared = value * value
        let unsafe = value != 0 && !squared.isNormal
        return (unsafe ? 0 : squared, unsafe ? 1 : 0)
    }
    private func count(_ value: Double, change: Int) {
        let magnitude = abs(value)
        if magnitude > 0 { nonzeroSamples += change }
        if magnitude == 1 { atFullScale += change }
        if magnitude > 1 { overFullScale += change }
        if magnitude > 0 && magnitude < subnormalThreshold { subnormal += change }
    }
    func append(_ value: Double) {
        if ring.count == ring.capacity {
            let old = ring.values[ring.cursor]
            if method == .compensatedSliding {
                let removed = square(old)
                sum.add(-removed.value)
                unsafeSquares -= removed.unsafe
            }
            count(old, change: -1)
        }
        ring.append(value)
        if method == .compensatedSliding {
            let added = square(value)
            sum.add(added.value)
            unsafeSquares += added.unsafe
        }
        count(value, change: 1)
        let expired = sequence - Int64(ring.capacity)
        while peakCount > 0 && peaks[peakHead].position <= expired {
            peakHead = (peakHead + 1) % ring.capacity
            peakCount -= 1
        }
        let magnitude = abs(value)
        while peakCount > 0
            && peaks[(peakHead + peakCount - 1) % ring.capacity].magnitude <= magnitude
        {
            peakCount -= 1
        }
        peaks[(peakHead + peakCount) % ring.capacity] = PeakEntry(
            position: sequence, magnitude: magnitude)
        peakCount += 1
        sequence += 1
        updatesSinceRebase += 1
        if updatesSinceRebase == ring.capacity {
            updatesSinceRebase = 0
            if method == .compensatedSliding { rebase() }
        }
    }
    private func rebase() {
        sum = LevelCompensatedSum()
        for i in 0..<ring.count { sum.add(square(ring.suffixValue(i, count: ring.count)).value) }
        updatesSinceRebase = 0
        rebaseCount = saturatingAdd(rebaseCount)
    }
    private func directEnergy(count: Int) throws -> LevelEnergy {
        var scaled = LevelScaledSum()
        for i in 0..<count { scaled.append(ring.suffixValue(i, count: count)) }
        return try scaled.energy(sampleCount: count)
    }
    func energy() throws -> LevelEnergy {
        guard ring.count > 0 else { throw LevelError.invalidState }
        if nonzeroSamples == 0 { return .zero }
        if method == .direct { return try directEnergy(count: ring.count) }
        if unsafeSquares == 0 && sum.needsRebase { rebase() }
        let peak = peaks[peakHead].magnitude
        let normalized = ((sum.value / peak) / peak) / Double(ring.count)
        let lowerBound = 1 / Double(ring.count)
        guard unsafeSquares == 0, sum.reliable, normalized.isFinite,
            normalized >= lowerBound * (1 - 64 * Double.ulpOfOne),
            normalized <= 1 + 64 * Double.ulpOfOne
        else {
            fallbackWindows = saturatingAdd(fallbackWindows)
            return try directEnergy(count: ring.count)
        }
        return try LevelEnergy(scale: peak, normalizedMeanSquare: min(1, normalized))
    }
    func diagnostics(count requestedCount: Int) throws -> LevelInputDiagnostics {
        guard requestedCount > 0, requestedCount <= ring.count else {
            throw LevelError.invalidState
        }
        if requestedCount == ring.count {
            return try LevelInputDiagnostics(
                sampleCount: requestedCount, atFullScale: atFullScale, overFullScale: overFullScale,
                subnormal: subnormal, finitePeakMagnitude: peaks[peakHead].magnitude)
        }
        var at = 0
        var over = 0
        var small = 0
        var peak = 0.0
        for i in 0..<requestedCount {
            let magnitude = abs(ring.suffixValue(i, count: requestedCount))
            peak = max(peak, magnitude)
            if magnitude == 1 { at += 1 }
            if magnitude > 1 { over += 1 }
            if magnitude > 0 && magnitude < subnormalThreshold { small += 1 }
        }
        return try LevelInputDiagnostics(
            sampleCount: requestedCount, atFullScale: at, overFullScale: over,
            subnormal: small, finitePeakMagnitude: peak)
    }
    func reset() {
        ring.reset()
        peakHead = 0
        peakCount = 0
        sequence = 0
        updatesSinceRebase = 0
        sum = LevelCompensatedSum()
        unsafeSquares = 0
        nonzeroSamples = 0
        atFullScale = 0
        overFullScale = 0
        subnormal = 0
        fallbackWindows = 0
        rebaseCount = 0
    }
}

final class LevelAnalyzerStorage {
    let pending: LevelSampleRing
    let unweighted: LevelWindowAccumulator
    let weighted: LevelWindowAccumulator?
    var filter: LevelKFilter?
    var pendingCount = 0
    var bufferBytes: Int {
        pending.capacity * MemoryLayout<Double>.stride + unweighted.bufferBytes
            + (weighted?.bufferBytes ?? 0)
    }
    init(_ configuration: LevelConfiguration) {
        let capacity = configuration.windowLength
        pending = LevelSampleRing(capacity: capacity)
        unweighted = LevelWindowAccumulator(
            capacity: capacity,
            subnormalThreshold: configuration.inputPrecision == .float32
                ? Double(Float.leastNormalMagnitude) : Double.leastNormalMagnitude,
            method: configuration.accumulation)
        weighted = configuration.kWeighting.map { _ in
            LevelWindowAccumulator(
                capacity: capacity, subnormalThreshold: Double.leastNormalMagnitude,
                method: configuration.accumulation)
        }
        filter = configuration.kWeighting.map(LevelKFilter.init)
    }
    func reset() {
        pending.reset()
        unweighted.reset()
        weighted?.reset()
        filter?.reset()
        pendingCount = 0
    }
}
