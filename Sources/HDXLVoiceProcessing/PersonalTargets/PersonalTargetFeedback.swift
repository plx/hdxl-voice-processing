import Dispatch
import Foundation

/// Single-owner worker/control policy, independent of UI, capture and device
/// output. Feed every complete observation before coalescing display delivery.
/// It retains one evidence interval and bounded scalar state, never a history.
public final class PersonalTargetFeedback {
    public let configuration: PersonalTargetFeedbackConfiguration
    public private(set) var target: ActivatedPersonalTarget
    public var latest: PersonalTargetFeedbackSnapshot { snapshot! }

    private var targetIdentity: CalibrationDigest
    private let configurationIdentity: CalibrationDigest
    private let clock: @Sendable () -> UInt64
    private let publisher: BoundedResultPublisher<PersonalTargetFeedbackSnapshot>
    private let diagnostics: WorkerDiagnostics
    private var snapshot: PersonalTargetFeedbackSnapshot?
    private var state: PersonalTargetFeedbackState = .unavailable
    private var reasons: [PersonalTargetFeedbackReason] = [.awaitingEvidence]
    private var modelReasons: [PersonalTargetReason] = []
    private var feature: PersonalTargetFeedbackFeature?
    private var proximity: PersonalTargetFeedbackProximity?
    private var values: PersonalTargetValues?
    private var evidence: PersonalTargetFeedbackInterval?
    private var cursor: PersonalTargetFeedbackInterval?
    private var coverage = PersonalTargetFeedbackCoverage()
    private var statistics = PersonalTargetFeedbackStatistics()
    private var lastNow: UInt64?
    private var stableMatch: Bool?
    private var transitionSourceEnd: UInt64?
    private var qualifiedSamples: UInt64 = 0
    private var entrySamples: UInt64 = 0
    private var exitSamples: UInt64 = 0
    private var entryObservations: UInt64 = 0
    private var exitObservations: UInt64 = 0
    private var paused = false
    private var terminated = false

    public convenience init(
        target: ActivatedPersonalTarget,
        configuration: PersonalTargetFeedbackConfiguration? = nil,
        diagnostics: RuntimeDiagnosticMode = .disabled, maximumSubscribers: Int = 16,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws {
        try self.init(
            target: target, configuration: configuration ?? PersonalTargetFeedbackConfiguration(),
            diagnostics: diagnostics, maximumSubscribers: maximumSubscribers,
            clock: clock, diagnosticSink: nil)
    }

    init(
        target: ActivatedPersonalTarget, configuration: PersonalTargetFeedbackConfiguration,
        diagnostics mode: RuntimeDiagnosticMode, maximumSubscribers: Int,
        clock: @escaping @Sendable () -> UInt64, diagnosticSink: (any DiagnosticSink)?
    ) throws {
        self.target = target
        self.configuration = configuration
        targetIdentity = try target.identity()
        configurationIdentity = try calibrationDigest(configuration)
        self.clock = clock
        diagnostics = WorkerDiagnostics(mode: mode.facadeMode, sink: diagnosticSink)
        publisher = try BoundedResultPublisher(
            maximumSubscribers: maximumSubscribers, replayLatest: true, diagnostics: mode,
            diagnosticSink: diagnosticSink, clock: clock)
        let now = clock()
        lastNow = now
        _ = publish(now: now, disposition: .control)
    }

    public func subscribe(
        _ policy: ResultDeliveryPolicy = .newest(capacity: 1)
    ) throws -> ResultSubscription<PersonalTargetFeedbackSnapshot> {
        try publisher.subscribe(policy)
    }

    public var activeSubscriberCount: Int { publisher.activeSubscriberCount }

    @discardableResult public func update(_ input: PersonalTargetFeedbackEvidence) throws
        -> PersonalTargetFeedbackSnapshot
    {
        guard !terminated else { throw PersonalTargetFeedbackError.terminated }
        let now = clock()
        guard acceptClock(now) else { return publish(now: now, disposition: .invalidClock) }
        guard !paused else { return publish(now: now, disposition: .paused) }
        expire(now)
        guard let resets = admit(input.interval, now: now) else { return latest }
        let observation = input.observation
        let prediction = target.prediction(for: observation)
        let findings = feedbackFindings(
            observation, prediction: prediction, policy: target.candidate.policy,
            selectedTags: input.interval.selectedTags)
        guard findings.reasons.isEmpty,
            let point = observation.values(policy: target.candidate.policy)
        else {
            clearTemporal()
            state = findings.uncertain ? .uncertain : .unavailable
            reasons = findings.reasons.isEmpty ? [.unavailableMeasurements] : findings.reasons
            reasons += resets
            modelReasons = prediction.reasons
            feature = findings.feature
            return publish(now: now, disposition: .accepted)
        }
        values = point
        modelReasons = []
        feature = .cpps
        let selected = UInt64(observation.coverage.selected)
        addCoverage(\.qualifiedSummarySamples, selected)
        qualifiedSamples = saturatingAdd(qualifiedSamples, selected)
        let rule = target.candidate.rule
        let inside = rule.preferredInterval.contains(point.cppsDB)
        let low = max(
            rule.observedCPPS.lower, rule.preferredInterval.lower - configuration.exitMarginDB)
        let high = min(
            rule.observedCPPS.upper, rule.preferredInterval.upper + configuration.exitMarginDB)
        let retained = low <= point.cppsDB && point.cppsDB <= high
        proximity = inside ? .insidePreferred : (retained ? .withinExitMargin : .outsideTarget)
        if inside {
            addCoverage(\.matchingSummarySamples, selected)
            entrySamples = saturatingAdd(entrySamples, selected)
            entryObservations = saturatingAdd(entryObservations)
            exitSamples = 0
            exitObservations = 0
        } else {
            entrySamples = 0
            entryObservations = 0
            if stableMatch == true && retained {
                exitSamples = 0
                exitObservations = 0
            } else {
                exitSamples = saturatingAdd(exitSamples, selected)
                exitObservations = saturatingAdd(exitObservations)
            }
        }
        let rate = input.interval.source.sampleRate
        let warm = Double(qualifiedSamples) / rate >= configuration.warmupSeconds
        let entryReady =
            entryObservations >= configuration.minimumObservations
            && Double(entrySamples) / rate >= configuration.entryPersistenceSeconds
        let exitReady =
            exitObservations >= configuration.minimumObservations
            && Double(exitSamples) / rate >= configuration.exitPersistenceSeconds
        let end = input.interval.sourceEndHostNanoseconds
        let cooled =
            transitionSourceEnd.map { end - $0 >= configuration.cooldownNanoseconds } ?? true
        if !warm {
            state = .uncertain
            reasons = [.warmingUp]
        } else if stableMatch == true {
            if retained {
                state = .onTarget
                reasons = inside ? [.targetMatch] : [.hysteresisHeld]
            } else if exitReady && cooled {
                transition(to: false, at: end)
            } else {
                state = .onTarget
                reasons = []
                if !exitReady { reasons.append(.exitPersistence) }
                if !cooled { reasons.append(.cooldown) }
            }
        } else if inside {
            if entryReady && cooled {
                transition(to: true, at: end)
            } else {
                state = .approachingTarget
                reasons = []
                if !entryReady { reasons.append(.entryPersistence) }
                if !cooled { reasons.append(.cooldown) }
            }
        } else if stableMatch == false {
            state = .departedTarget
            reasons = [.targetDrift]
        } else if exitReady {
            transition(to: false, at: end)
        } else {
            state = .uncertain
            reasons = [.exitPersistence]
        }
        reasons += resets
        return publish(now: now, disposition: .accepted)
    }

    /// Known dropped source support, distinct from silence or an unsampled UI.
    @discardableResult public func recordGap(
        _ source: SourceInterval, sourceEndHostNanoseconds: UInt64
    ) throws -> PersonalTargetFeedbackSnapshot {
        guard !terminated else { throw PersonalTargetFeedbackError.terminated }
        try validateFeedbackAnchor(source, end: sourceEndHostNanoseconds)
        let now = clock()
        guard acceptClock(now) else { return publish(now: now, disposition: .invalidClock) }
        let interval = PersonalTargetFeedbackInterval(
            source: source, analysisIdentity: nil,
            profile: nil, statistic: nil, analysisImplementation: nil,
            sourceEndHostNanoseconds: sourceEndHostNanoseconds, coverage: nil, selectedTags: [:])
        guard let resets = admit(interval, now: now) else { return latest }
        clearTemporal()
        state = .unavailable
        reasons = [.droppedAudio] + (paused ? [.paused] : []) + resets
        feature = .capture
        return publish(now: now, disposition: .accepted)
    }

    /// Host timers/replay clocks may expire evidence; polling never advances a
    /// positive persistence counter or completes a pending target transition.
    @discardableResult public func poll() -> PersonalTargetFeedbackSnapshot {
        guard !terminated else { return latest }
        let now = clock()
        guard acceptClock(now) else { return publish(now: now, disposition: .invalidClock) }
        expire(now)
        return publish(now: now, disposition: .control)
    }

    @discardableResult public func pause() throws -> PersonalTargetFeedbackSnapshot {
        guard !terminated else { throw PersonalTargetFeedbackError.terminated }
        paused = true
        return control(.paused)
    }

    @discardableResult public func resume() throws -> PersonalTargetFeedbackSnapshot {
        guard !terminated else { throw PersonalTargetFeedbackError.terminated }
        paused = false
        return control(.resumed)
    }

    /// Temporal state and coverage restart; the source admission watermark is
    /// retained, so replaying the preceding observation cannot restart a match.
    @discardableResult public func reset(
        _ cause: PersonalTargetFeedbackReset = .manual
    ) throws -> PersonalTargetFeedbackSnapshot {
        guard !terminated else { throw PersonalTargetFeedbackError.terminated }
        let reason: PersonalTargetFeedbackReason
        switch cause {
        case .manual: reason = .reset
        case .routeChanged: reason = .routeChanged
        case .profileChanged: reason = .profileChanged
        case .discontinuity: reason = .sourceDiscontinuity
        case .missingData: reason = .missingData
        case .droppedAudio:
            reason = .droppedAudio
            statistics.unknownLossEvents = saturatingAdd(statistics.unknownLossEvents)
        }
        coverage = PersonalTargetFeedbackCoverage()
        return control(reason)
    }

    @discardableResult public func replaceTarget(_ newTarget: ActivatedPersonalTarget) throws
        -> PersonalTargetFeedbackSnapshot
    {
        guard !terminated else { throw PersonalTargetFeedbackError.terminated }
        let identity = try newTarget.identity()
        guard identity != targetIdentity else { return poll() }
        target = newTarget
        targetIdentity = identity
        coverage = PersonalTargetFeedbackCoverage()
        return control(.modelChanged)
    }

    @discardableResult public func finish(cancelled: Bool = false)
        -> PersonalTargetFeedbackSnapshot
    {
        guard !terminated else { return latest }
        let result = control(cancelled ? .cancelled : .finished)
        terminated = true
        publisher.finish(cancelled ? .failed(.cancelled) : .finished)
        return result
    }

    private func control(_ reason: PersonalTargetFeedbackReason) -> PersonalTargetFeedbackSnapshot {
        clearTemporal()
        evidence = nil
        statistics.resets = saturatingAdd(statistics.resets)
        state = .unavailable
        reasons = [reason]
        let now = clock()
        let valid = acceptClock(now)
        if !valid { reasons.append(reason) }
        return publish(now: now, disposition: valid ? .control : .invalidClock)
    }

    private func transition(to match: Bool, at time: UInt64) {
        stableMatch = match
        transitionSourceEnd = time
        state = match ? .onTarget : .departedTarget
        reasons = [match ? .targetMatch : .targetDrift]
    }

    private func clearTemporal() {
        stableMatch = nil
        transitionSourceEnd = nil
        qualifiedSamples = 0
        entrySamples = 0
        exitSamples = 0
        entryObservations = 0
        exitObservations = 0
        values = nil
        proximity = nil
        modelReasons = []
        feature = nil
    }

    private func acceptClock(_ now: UInt64) -> Bool {
        if let lastNow, now < lastNow {
            statistics.invalidClocks = saturatingAdd(statistics.invalidClocks)
            clearTemporal()
            state = .unavailable
            reasons = [.invalidClock]
            feature = .timing
            return false
        }
        lastNow = now
        return true
    }

    private func expire(_ now: UInt64) {
        guard !paused, let evidence, now >= evidence.sourceEndHostNanoseconds,
            now - evidence.sourceEndHostNanoseconds >= configuration.maximumAgeNanoseconds
        else { return }
        clearTemporal()
        state = .unavailable
        reasons = [.stale]
        feature = .timing
    }

    /// Nil means the input has already been rejected and a snapshot published.
    private func admit(_ interval: PersonalTargetFeedbackInterval, now: UInt64)
        -> [PersonalTargetFeedbackReason]?
    {
        let source = interval.source
        if let cursor,
            source == cursor.source && interval.analysisIdentity == cursor.analysisIdentity
        {
            statistics.duplicateInputs = saturatingAdd(statistics.duplicateInputs)
            expire(now)
            _ = publish(now: now, disposition: .duplicate)
            return nil
        }
        guard interval.sourceEndHostNanoseconds <= now else {
            statistics.invalidClocks = saturatingAdd(statistics.invalidClocks)
            clearTemporal()
            state = .unavailable
            reasons = [.invalidClock]
            feature = .timing
            _ = publish(now: now, disposition: .invalidClock)
            return nil
        }
        var resets: [PersonalTargetFeedbackReason] = []
        if let cursor {
            let sameEpoch =
                source.epoch == cursor.source.epoch
                && source.sampleRate == cursor.source.sampleRate
            guard interval.sourceEndHostNanoseconds > cursor.sourceEndHostNanoseconds,
                !sameEpoch || source.startSample >= cursor.source.endSample
            else {
                statistics.outOfOrderInputs = saturatingAdd(statistics.outOfOrderInputs)
                expire(now)
                _ = publish(now: now, disposition: .outOfOrder)
                return nil
            }
            if !sameEpoch {
                clearTemporal()
                coverage = PersonalTargetFeedbackCoverage()
                statistics.resets = saturatingAdd(statistics.resets)
                resets.append(.sourceDiscontinuity)
            } else if source.startSample > cursor.source.endSample {
                let gap = UInt64(source.startSample - cursor.source.endSample)
                addCoverage(\.sourceSamples, gap)
                addCoverage(\.unobservedSamples, gap)
                clearTemporal()
                statistics.resets = saturatingAdd(statistics.resets)
                resets.append(.missingData)
            }
        }
        coverage.epoch = source.epoch
        coverage.sampleRate = source.sampleRate
        cursor = interval
        evidence = interval
        statistics.acceptedIntervals = saturatingAdd(statistics.acceptedIntervals)
        addCoverage(\.sourceSamples, UInt64(source.sampleCount))
        if let c = interval.coverage {
            addCoverage(\.eligibleSamples, UInt64(c.eligible))
            addCoverage(\.selectedSamples, UInt64(c.selected))
            addCoverage(\.missingSamples, UInt64(c.missing))
            addCoverage(\.excludedEligibleSamples, UInt64(c.excludedEligible))
            for (tag, count) in c.tags {
                let sum = coverage.tags[tag, default: 0].addingReportingOverflow(UInt64(count))
                coverage.saturated = coverage.saturated || sum.overflow
                coverage.tags[tag] = sum.overflow ? .max : sum.partialValue
            }
        } else {
            addCoverage(\.missingSamples, UInt64(source.sampleCount))
            let key = MaskTag.missingAcquisition.rawValue
            let sum = coverage.tags[key, default: 0].addingReportingOverflow(
                UInt64(source.sampleCount))
            coverage.saturated = coverage.saturated || sum.overflow
            coverage.tags[key] = sum.overflow ? .max : sum.partialValue
        }
        if !paused && now - interval.sourceEndHostNanoseconds >= configuration.maximumAgeNanoseconds
        {
            expire(now)
            _ = publish(now: now, disposition: .accepted)
            return nil
        }
        return resets
    }

    private func addCoverage(
        _ key: WritableKeyPath<PersonalTargetFeedbackCoverage, UInt64>, _ n: UInt64
    ) {
        let sum = coverage[keyPath: key].addingReportingOverflow(n)
        coverage.saturated = coverage.saturated || sum.overflow
        coverage[keyPath: key] = sum.overflow ? .max : sum.partialValue
    }

    private func publish(now: UInt64, disposition: PersonalTargetFeedbackInputDisposition)
        -> PersonalTargetFeedbackSnapshot
    {
        reasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
        let changed =
            snapshot.map {
                $0.state != state || $0.reasons != reasons || $0.modelReasons != modelReasons
                    || $0.responsibleFeature != feature || $0.targetIdentity != targetIdentity
            } ?? true
        if changed {
            statistics.stateChanges = saturatingAdd(statistics.stateChanges)
            var metadata = DiagnosticMetadata()
            metadata.profileToken = 5701
            metadata.frameSequence = statistics.stateChanges - 1
            metadata.validity =
                state == .unavailable ? .invalidInput : (state == .uncertain ? .warmup : .available)
            diagnostics.withFrame(metadata, stage: .feedbackStateChange) {}
        }
        let rate = evidence?.source.sampleRate ?? coverage.sampleRate ?? 1
        let result = PersonalTargetFeedbackSnapshot(
            targetIdentity: targetIdentity, configurationIdentity: configurationIdentity,
            profile: target.candidate.scope.profile, statistic: target.candidate.scope.statistic,
            state: state, reasons: reasons, modelReasons: modelReasons, responsibleFeature: feature,
            proximity: proximity, evidence: evidence, values: values,
            progress: PersonalTargetFeedbackProgress(
                qualifiedSeconds: Double(qualifiedSamples) / rate,
                entrySeconds: Double(entrySamples) / rate, exitSeconds: Double(exitSamples) / rate,
                entryObservations: entryObservations, exitObservations: exitObservations),
            coverage: coverage, statistics: statistics, inputDisposition: disposition,
            evaluatedAtHostNanoseconds: now,
            evidenceAgeNanoseconds: evidence.flatMap {
                now >= $0.sourceEndHostNanoseconds ? now - $0.sourceEndHostNanoseconds : nil
            })
        snapshot = result
        publisher.publish(result)
        return result
    }
}
