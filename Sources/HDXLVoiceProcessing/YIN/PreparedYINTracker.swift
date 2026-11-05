import Foundation

/// Single-owner causal candidate preference. Accepts the prepared estimator's
/// borrowed diagnostics without copying arrays. Sequential calls must follow its
/// exact epoch/grid; reset explicitly before a new epoch or a skipped frame.
public final class PreparedYINTracker {
    public let profile: YINProfile
    public let identity: ProfileIdentity
    public let trackerIdentity: ProfileIdentity
    public let estimatorIdentity: ProfileIdentity
    private let weight: Double
    private let diagnostics: WorkerDiagnostics
    private var previousFrequency: Double?
    private var previousDependency: AnalysisTiming?
    private var lastFrame: YINFrameResult?
    private var busy = false

    public convenience init(_ profile: YINProfile) throws {
        try self.init(profile, diagnostics: WorkerDiagnostics())
    }
    package init(_ profile: YINProfile, diagnostics: WorkerDiagnostics) throws {
        guard let tracker = profile.tracker else { throw YINError.invalidConfiguration }
        self.profile = profile
        self.identity = try profile.identity()
        self.trackerIdentity = try tracker.identity()
        self.estimatorIdentity = try profile.estimator.identity()
        self.weight = tracker.continuityWeight
        self.diagnostics = diagnostics
    }

    /// Transactional: invalid profile, sequence or timing leaves history intact.
    public func process(_ input: BorrowedYINOutput) throws -> YINTrackedFrameResult {
        guard !busy else { throw YINError.reentrantCall }
        let raw = input.result
        guard raw.profile == estimatorIdentity,
            raw.requiredSampleCount == profile.estimator.requiredSampleCount,
            raw.timing.source.sampleRate == Double(profile.estimator.sampleRate)
        else { throw YINError.unexpectedContext }
        if let lastFrame {
            let nextIndex = lastFrame.frameIndex.addingReportingOverflow(1)
            let nextStart = lastFrame.timing.source.startSample.addingReportingOverflow(
                Int64(profile.estimator.hopLength))
            guard lastFrame.timing.source.sampleCount == Int64(lastFrame.requiredSampleCount),
                !nextIndex.overflow, !nextStart.overflow,
                raw.frameIndex == nextIndex.partialValue,
                raw.timing.source.epoch == lastFrame.timing.source.epoch,
                raw.timing.source.startSample == nextStart.partialValue
            else { throw YINError.unexpectedContext }
        }
        if let selected = raw.selectedCandidateIndex {
            guard input.candidates.indices.contains(selected),
                input.candidates[selected] == raw.observation
            else { throw YINError.unexpectedContext }
        } else if raw.observation != nil {
            throw YINError.unexpectedContext
        }
        busy = true
        defer { busy = false }
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 3801
        metadata.frameSequence = raw.frameIndex
        metadata.sampleCount = UInt32(raw.timing.source.sampleCount)
        metadata.validity = raw.unavailability == .insufficientData ? .warmup : .available
        let result = try diagnostics.withFrame(metadata) {
            try diagnostics.withInterval(.pitchTracking) { try select(input) }
        }
        // Commit only after every checked timing operation succeeded.
        if raw.status == .voiced {
            previousFrequency = result.observation?.frequencyHz
            previousDependency = result.dependencyTiming
        } else {
            previousFrequency = nil
            previousDependency = nil
        }
        lastFrame = raw
        return result
    }

    private func select(_ input: BorrowedYINOutput) throws -> YINTrackedFrameResult {
        let raw = input.result
        var selected = raw.selectedCandidateIndex
        var timing = raw.timing
        if raw.status == .voiced {
            guard let rawIndex = selected, input.candidates[rawIndex].isThresholdQualified else {
                throw YINError.unexpectedContext
            }
            if let previousFrequency, let previousDependency {
                var bestScore = Double.infinity
                var bestLag = Int.max
                for (index, candidate) in input.candidates.enumerated()
                where candidate.isThresholdQualified {
                    let score =
                        candidate.normalizedError
                        + weight * abs(log2(candidate.frequencyHz / previousFrequency))
                    if score < bestScore || (score == bestScore && candidate.integerLag < bestLag) {
                        selected = index
                        bestScore = score
                        bestLag = candidate.integerLag
                    }
                }
                let source = try SourceInterval(
                    epoch: raw.timing.source.epoch,
                    startSample: previousDependency.source.startSample,
                    sampleCount: raw.timing.source.endSample
                        - previousDependency.source.startSample,
                    sampleRate: raw.timing.source.sampleRate)
                // Changing the dependency midpoint changes its delay coordinate,
                // not the amount of future audio required by the causal tracker.
                let centerOffset =
                    Double(raw.timing.source.startSample - source.startSample)
                    / source.sampleRate / 2
                let previousCenterAdvance =
                    Double(source.endSample - previousDependency.source.endSample)
                    / source.sampleRate / 2
                timing = try AnalysisTiming(
                    source: source, includedSampleCount: source.sampleCount,
                    sourceStartSeconds: previousDependency.sourceStartSeconds,
                    hostStartNanoseconds: previousDependency.hostStartNanoseconds,
                    completedHostNanoseconds: raw.timing.completedHostNanoseconds,
                    effectiveDelaySeconds: max(
                        raw.timing.effectiveDelaySeconds + centerOffset,
                        previousDependency.effectiveDelaySeconds - previousCenterAdvance))
            }
        }
        return YINTrackedFrameResult(
            profile: identity, trackerProfile: trackerIdentity, raw: raw,
            observation: selected.map { input.candidates[$0] }, selectedCandidateIndex: selected,
            changedSelection: selected != raw.selectedCandidateIndex, dependencyTiming: timing)
    }

    /// Discard candidate history and sequence expectations without reallocating.
    /// The next accepted frame starts a new tracking dependency interval.
    public func reset() throws {
        guard !busy else { throw YINError.reentrantCall }
        previousFrequency = nil
        previousDependency = nil
        lastFrame = nil
    }
}
