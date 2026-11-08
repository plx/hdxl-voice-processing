import Foundation
import HDXLVoiceProcessing
import Synchronization

private final class ReplayClock: Sendable {
    let value = Mutex<UInt64>(0)
    func set(_ next: UInt64) { value.withLock { $0 = next } }
    func now() -> UInt64 { value.withLock { $0 } }
}

/// Software-only public API integration, using the separately checked profile.
/// These summaries and the source clock are fabricated, not streaming DSP output.
func feedbackSnapshots(target: ActivatedPersonalTarget, profile: AnalysisScheduleProfile) throws
    -> [PersonalTargetFeedbackSnapshot]
{
    let clock = ReplayClock()
    let policy = try PersonalTargetFeedback(
        target: target,
        configuration: PersonalTargetFeedbackConfiguration(
            warmupSeconds: 0.2, entryPersistenceSeconds: 0.4, exitPersistenceSeconds: 0.4,
            minimumObservations: 2, cooldownSeconds: 0), clock: clock.now)
    var snapshots = [policy.latest]
    var last: PersonalTargetFeedbackEvidence?
    let rule = target.candidate.rule
    let scope = target.candidate.scope
    for index in 0..<2 {
        let source = try SourceInterval(
            epoch: StreamEpoch(streamID: identifier(57000)), startSample: Int64(index * 3200),
            sampleCount: 3200, sampleRate: 16000)
        let take = try syntheticTake(
            id: 57001 + index, label: .preferred, profile: profile, source: source)
        let analysis = try syntheticAnalysis(
            take: take, cpps: rule.preferredInterval.lower,
            pitch: (scope.observedPitchHz.lower + scope.observedPitchHz.upper) / 2,
            level: (scope.observedLevelDBFS.lower + scope.observedLevelDBFS.upper) / 2)
        let end = UInt64(1_200_000_000 + index * 200_000_000)
        let evidence = try PersonalTargetFeedbackEvidence(
            take: take, analysis: analysis, sourceEndHostNanoseconds: end)
        clock.set(end)
        snapshots.append(try policy.update(evidence))
        last = evidence
    }
    guard let last else { throw ExampleError.verificationFailed }
    try require(snapshots[1].state == .approachingTarget && snapshots[2].state == .onTarget)
    snapshots.append(try policy.update(last))
    try require(snapshots[3].inputDisposition == .duplicate)
    try require(snapshots[3].progress == snapshots[2].progress)
    clock.set(3_400_000_000)
    snapshots.append(policy.poll())
    try require(snapshots[4].state == .unavailable && snapshots[4].reasons == [.stale])
    snapshots.append(policy.finish())
    return snapshots
}
