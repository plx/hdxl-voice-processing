import Foundation

/// Bounded centered smoothing over one continuous cepstral grid. This single-owner
/// worker consumes frames in order, retains at most 2*lookahead+1, and emits delayed
/// results synchronously. It never concatenates grids across gaps. Finish/reset at
/// every independently conditioned or selected region boundary.
public final class PreparedCPPS {
    public let profile: CPPSProfile
    public let identity: ProfileIdentity
    public let sourceIdentity: ProfileIdentity
    public let layout: CPPSLayout
    public private(set) var origin: SourceInterval
    public private(set) var receivedFrameCount = 0
    public private(set) var emittedFrameCount = 0
    public var scalarWorkspaceBytes: Int {
        (rawPower.count + preparedPower.count + temporal.count + smoothed.count)
            * MemoryLayout<Double>.stride + rawKernel.scalarWorkspaceBytes
            + finalKernel.scalarWorkspaceBytes
    }
    /// Stored records are bounded by the ring capacity, separate from scalar arrays.
    public var recordWorkspaceBytes: Int {
        records.count * MemoryLayout<CPPFrameResult?>.stride
            + reasons.count * MemoryLayout<UnavailabilityReason?>.stride
            + rawPowerIsAvailable.count * MemoryLayout<Bool>.stride
    }
    private let rawIdentity: ProfileIdentity
    private let rawKernel: PreparedCPP
    private let finalKernel: PreparedCPP
    private let rawPower: UnsafeMutableBufferPointer<Double>
    private let preparedPower: UnsafeMutableBufferPointer<Double>
    private let temporal: UnsafeMutableBufferPointer<Double>
    private let smoothed: UnsafeMutableBufferPointer<Double>
    private var records: [CPPFrameResult?]
    private var reasons: [UnavailabilityReason?]
    private var rawPowerIsAvailable: [Bool]
    private var firstCenter: Double?
    private var observedEnd: Int64
    private var completion: CPPSCompletion?
    private var busy = false
    private var failed = false
    private var validCount = 0
    private var sum = 0.0
    private var correction = 0.0
    private var firstFailure: UnavailabilityReason?
    // A partial PCM tail is not a sample on the complete-frame smoothing grid.
    // Flush that grid at its true edge, then report the tail separately.
    private var terminalFrame: CPPFrameResult?
    private let diagnostics: WorkerDiagnostics

    public convenience init(profile: CPPSProfile, origin: SourceInterval) throws {
        try self.init(profile: profile, origin: origin, diagnostics: WorkerDiagnostics())
    }
    package init(profile: CPPSProfile, origin: SourceInterval, diagnostics: WorkerDiagnostics)
        throws
    {
        guard origin.sampleCount == 0,
            origin.sampleRate == Double(profile.cepstrogram.conditioning.sourceSampleRate)
        else { throw CPPSError.invalidConfiguration }
        self.profile = profile
        self.layout = try CPPSLayout(profile: profile)
        self.origin = origin
        observedEnd = origin.startSample
        self.identity = try profile.identity()
        self.sourceIdentity = try profile.cepstrogram.identity()
        self.rawIdentity = try CPPProfile(
            cepstrogram: profile.cepstrogram,
            settings: profile.settings.prominence
        ).identity()
        let kernelProfile = CPPProfile(
            frame: profile.cepstrogram.frame, settings: profile.settings.prominence)
        self.rawKernel = try PreparedCPP(kernelProfile, diagnostics: diagnostics)
        self.finalKernel = try PreparedCPP(
            kernelProfile, diagnostics: diagnostics,
            diagnosticStage: .cppsFitting, diagnosticProfileToken: 37)
        self.diagnostics = diagnostics
        func allocate(_ count: Int) -> UnsafeMutableBufferPointer<Double> {
            let buffer = UnsafeMutableBufferPointer<Double>.allocate(capacity: count)
            buffer.initialize(repeating: 0)
            return buffer
        }
        let bins = profile.cepstrogram.frame.binCount
        rawPower = allocate(layout.ringFrameCapacity * bins)
        preparedPower = allocate(layout.ringFrameCapacity * bins)
        temporal = allocate(bins)
        smoothed = allocate(bins)
        records = Array(repeating: nil, count: layout.ringFrameCapacity)
        reasons = Array(repeating: nil, count: layout.ringFrameCapacity)
        rawPowerIsAvailable = Array(repeating: false, count: layout.ringFrameCapacity)
    }
    deinit {
        for buffer in [rawPower, preparedPower, temporal, smoothed] {
            buffer.deinitialize()
            buffer.deallocate()
        }
    }

    public func append(_ input: BorrowedPowerCepstrum<Double>, emit: (BorrowedCPPSOutput) -> Void)
        throws
    {
        guard input.configuration == profile.cepstrogram.frame, input.profile == sourceIdentity
        else {
            throw CPPSError.profileMismatch
        }
        let stage = input.stage(.powerCepstrum)
        try consume(
            stage.values, reason: input.unavailability ?? stage.unavailability,
            context: input.context, emit: emit)
    }

    /// Isolated-stage entry point. The caller declares the full upstream recipe;
    /// values must already be its linear power cepstrum, not PCM or dB.
    public func appendPowerCepstrum(
        _ power: UnsafeBufferPointer<Double>,
        context: CepstralFrameContext, sourceProfile: ProfileIdentity,
        emit: (BorrowedCPPSOutput) -> Void
    ) throws {
        guard sourceProfile == sourceIdentity else { throw CPPSError.profileMismatch }
        try consume(power, reason: nil, context: context, emit: emit)
    }

    private func consume(
        _ power: UnsafeBufferPointer<Double>, reason: UnavailabilityReason?,
        context: CepstralFrameContext, emit: (BorrowedCPPSOutput) -> Void
    ) throws {
        guard !busy else { throw CPPSError.reentrantCall }
        guard completion == nil, !failed, terminalFrame == nil else { throw CPPSError.invalidState }
        guard receivedFrameCount - emittedFrameCount <= layout.lookaheadFrames else {
            throw CPPSError.unexpectedFrame
        }
        guard receivedFrameCount < 1_000_000_000, context.origin == origin,
            context.frameIndex == UInt64(receivedFrameCount)
        else { throw CPPSError.unexpectedFrame }
        if let reason, context.suppliedAnalysisSampleCount < profile.cepstrogram.frame.frameLength {
            terminalFrame = CPPFrameResult(
                profile: rawIdentity, sourceProfile: sourceIdentity,
                context: context, layout: layout.prominence, observation: nil,
                unavailability: reason)
            observedEnd = max(observedEnd, context.timing.source.endSample)
            return
        }
        let first = firstCenter ?? context.centerSecondsFromOrigin
        let expected = first + Double(receivedFrameCount) * profile.cepstrogram.hopSeconds
        guard abs(context.centerSecondsFromOrigin - expected) <= max(1e-12, 64 * expected.ulp)
        else {
            throw CPPSError.unexpectedFrame
        }
        if reason == nil {
            guard power.count == temporal.count,
                context.suppliedAnalysisSampleCount == profile.cepstrogram.frame.frameLength,
                context.timing.includedSampleCount > 0,
                context.timing.includedSampleCount == context.timing.source.sampleCount
            else { throw CPPSError.unexpectedFrame }
            for value in power where !value.isFinite || value < 0 { throw CPPSError.invalidInput }
        }
        busy = true
        defer { busy = false }
        let slot = receivedFrameCount % layout.ringFrameCapacity
        rawPowerIsAvailable[slot] = reason == nil
        if let reason {
            records[slot] = CPPFrameResult(
                profile: rawIdentity, sourceProfile: sourceIdentity,
                context: context, layout: layout.prominence, observation: nil,
                unavailability: reason)
            reasons[slot] = reason
        } else {
            try rawKernel.analyzePowerCepstrum(power, context: context) { output in
                records[slot] = CPPFrameResult(
                    profile: rawIdentity, sourceProfile: sourceIdentity,
                    context: context, layout: layout.prominence,
                    observation: output.result.observation,
                    unavailability: output.result.unavailability)
                reasons[slot] = output.result.unavailability
                let residual = output.values(.residualDB)
                for bin in power.indices {
                    let index = slot * temporal.count + bin
                    rawPower[index] = power[bin]
                    let value =
                        profile.settings.subtractTrendBeforeSmoothing && !residual.isEmpty
                        ? exp(max(0, residual[bin]) * (log(10.0) / 10)) : power[bin]
                    preparedPower[index] = value
                    if !value.isFinite { reasons[slot] = .analysisFailure }
                }
            }
        }
        firstCenter = first
        observedEnd = max(observedEnd, context.timing.source.endSample)
        receivedFrameCount += 1
        do {
            while emittedFrameCount + layout.lookaheadFrames < receivedFrameCount {
                // Do not assume a source domain beyond observed input. Finishing
                // supplies the final domain for any remaining boundary frames.
                let right =
                    first
                    + (Double(emittedFrameCount)
                        + (layout.temporalSmoothingIsActive
                            ? profile.settings.timeWindowSeconds
                                / (2 * profile.cepstrogram.hopSeconds) : 0))
                    * profile.cepstrogram.hopSeconds
                if right > Double(observedEnd - origin.startSample) / origin.sampleRate { break }
                try produce(finalSource: nil, emit: emit)
            }
            // Each input must leave enough room for the next frame. Unusual frames
            // outside their source domain cannot silently overwrite pending work.
            guard receivedFrameCount - emittedFrameCount <= layout.lookaheadFrames + 1 else {
                throw CPPSError.unexpectedFrame
            }
        } catch {
            failed = true
            throw error
        }
    }

    /// Supply the upstream's total emitted count, including a terminal short-frame
    /// report. Isolated power objects supply their explicit grid count. This detects
    /// omitted suffixes without guessing a PCM frame grid for constructed objects.
    @discardableResult public func finish(
        source: SourceInterval, expectedFrameCount: Int,
        emit: (BorrowedCPPSOutput) -> Void
    ) throws -> CPPSCompletion {
        guard !busy else { throw CPPSError.reentrantCall }
        guard !failed else { throw CPPSError.invalidState }
        if let completion {
            guard completion.source == source, completion.frameCount == expectedFrameCount else {
                throw CPPSError.unexpectedFrame
            }
            return completion
        }
        guard source.epoch == origin.epoch, source.sampleRate == origin.sampleRate,
            source.startSample == origin.startSample, source.endSample >= observedEnd
        else { throw CPPSError.unexpectedFrame }
        guard expectedFrameCount >= 0,
            receivedFrameCount + (terminalFrame == nil ? 0 : 1) == expectedFrameCount
        else { throw CPPSError.incompleteInput }
        busy = true
        defer { busy = false }
        do {
            while emittedFrameCount < receivedFrameCount {
                try produce(finalSource: source, emit: emit)
            }
        } catch {
            failed = true
            throw error
        }
        if let tail = terminalFrame {
            let empty = UnsafeBufferPointer<Double>(start: nil, count: 0)
            emit(
                BorrowedCPPSOutput(
                    result: CPPSFrameResult(
                        profile: identity, sourceProfile: sourceIdentity,
                        rawCPP: tail, context: tail.context, observation: nil,
                        unavailability: tail.unavailability,
                        temporalSupportFrameCount: 0, usesSmoothingEdge: true,
                        lookaheadSeconds: layout.lookaheadSeconds),
                    quefrencyStepSeconds: profile.cepstrogram.frame.quefrencyStepSeconds,
                    powerIsTrendNormalized: profile.settings.subtractTrendBeforeSmoothing,
                    raw: empty, prepared: empty, temporal: empty, smoothed: empty, fit: nil))
            emittedFrameCount += 1
            firstFailure = firstFailure ?? tail.unavailability
        }
        let reason = firstFailure ?? (validCount == 0 ? .insufficientData : nil)
        let result = CPPSCompletion(
            profile: identity, source: source,
            frameCount: receivedFrameCount + (terminalFrame == nil ? 0 : 1),
            availableFrameCount: validCount,
            meanDB: reason == nil ? sum / Double(validCount) : nil, unavailability: reason)
        completion = result
        return result
    }

    /// Reuses prepared storage without carrying samples or scores across epochs/regions.
    public func reset(origin: SourceInterval) throws {
        guard !busy else { throw CPPSError.reentrantCall }
        guard origin.sampleCount == 0, origin.sampleRate == self.origin.sampleRate else {
            throw CPPSError.invalidConfiguration
        }
        self.origin = origin
        observedEnd = origin.startSample
        receivedFrameCount = 0
        emittedFrameCount = 0
        firstCenter = nil
        completion = nil
        failed = false
        validCount = 0
        sum = 0
        correction = 0
        firstFailure = nil
        terminalFrame = nil
        for i in records.indices {
            records[i] = nil
            reasons[i] = nil
            rawPowerIsAvailable[i] = false
        }
        diagnostics.reset()
    }

    private func produce(finalSource: SourceInterval?, emit: (BorrowedCPPSOutput) -> Void) throws {
        let center = emittedFrameCount
        let slot = center % layout.ringFrameCapacity
        guard let raw = records[slot], let firstCenter else { throw CPPSError.invalidState }
        let radius = layout.lookaheadFrames
        let first = max(0, center - radius)
        let last = min(receivedFrameCount - 1, center + radius)
        let hop = profile.cepstrogram.hopSeconds
        let half = profile.settings.timeWindowSeconds / (2 * hop)
        let localCenter = Double(center - first)
        let lowerDomain = -firstCenter / hop - Double(first)
        let upperDomain =
            finalSource.map { ($0.durationSeconds - firstCenter) / hop - Double(first) }
            ?? Double(last - first) + 0.5
        var reason: UnavailabilityReason?
        var supportStart = raw.context.timing.source.startSample
        var supportEnd = raw.context.timing.source.endSample
        var delay = raw.context.timing.effectiveDelaySeconds
        var extensionUsed = raw.context.usesBoundaryExtension
        for index in first...last {
            let position = index % layout.ringFrameCapacity
            guard let record = records[position] else { throw CPPSError.invalidState }
            reason = reason ?? reasons[position]
            supportStart = min(supportStart, record.context.timing.source.startSample)
            supportEnd = max(supportEnd, record.context.timing.source.endSample)
            // Preview delays are relative to each dependency's frame center.
            // Translate them to the output center before taking their maximum.
            // Integer grid offsets avoid subtracting large floating-point times.
            // Whole-interval timing instead refers to the common source midpoint.
            let centerOffset =
                profile.cepstrogram.previewHopLength == nil
                ? 0 : Double(index - center) * hop
            delay = max(delay, record.context.timing.effectiveDelaySeconds + centerOffset)
            extensionUsed = extensionUsed || record.context.usesBoundaryExtension
        }
        if profile.cepstrogram.previewHopLength != nil, let finalSource {
            // A truncated right smoothing edge is only known when the caller
            // finishes the source, even if its final complete frame arrived earlier.
            delay = max(delay, finalSource.durationSeconds - raw.context.centerSecondsFromOrigin)
        }
        let support = try SourceInterval(
            epoch: origin.epoch, startSample: supportStart,
            sampleCount: supportEnd - supportStart, sampleRate: origin.sampleRate)
        let timing = try AnalysisTiming(
            source: support,
            includedSampleCount: reason == nil ? support.sampleCount : 0,
            effectiveDelaySeconds: delay)
        let context = try CepstralFrameContext(
            origin: origin, timing: timing,
            frameIndex: raw.context.frameIndex,
            firstAnalysisSampleIndex: raw.context.firstAnalysisSampleIndex,
            suppliedAnalysisSampleCount: raw.context.suppliedAnalysisSampleCount,
            centerSecondsFromOrigin: raw.context.centerSecondsFromOrigin,
            usesBoundaryExtension: extensionUsed)
        let edge =
            layout.temporalSmoothingIsActive
            && (center < radius || center + radius >= receivedFrameCount)
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 37
        metadata.frameSequence = UInt64(center)
        metadata.sampleCount = UInt32(temporal.count)
        if reason == nil {
            diagnostics.withFrame(metadata) {
                diagnostics.withInterval(.cppsSmoothing) {
                    for bin in temporal.indices {
                        if layout.temporalSmoothingIsActive {
                            temporal[bin] =
                                sampledLinearMean(
                                    count: last - first + 1,
                                    lower: localCenter - half, upper: localCenter + half,
                                    domainLower: lowerDomain, domainUpper: upperDomain
                                ) { offset in
                                    preparedPower[
                                        ((first + offset) % layout.ringFrameCapacity)
                                            * temporal.count + bin]
                                } ?? .nan
                        } else {
                            temporal[bin] = preparedPower[slot * temporal.count + bin]
                        }
                    }
                    let qhalf =
                        profile.settings.quefrencyWindowSeconds
                        / (2 * profile.cepstrogram.frame.quefrencyStepSeconds)
                    for bin in smoothed.indices {
                        smoothed[bin] =
                            layout.quefrencySmoothingIsActive
                            ? sampledLinearMean(
                                count: temporal.count,
                                lower: Double(bin) - qhalf, upper: Double(bin) + qhalf,
                                domainLower: 0, domainUpper: Double(temporal.count - 1),
                                value: { temporal[$0] }) ?? .nan : temporal[bin]
                        if !smoothed[bin].isFinite || smoothed[bin] < 0 {
                            reason = .analysisFailure
                        }
                    }
                }
            }
        }
        if reason == nil {
            try finalKernel.analyzePowerCepstrum(
                UnsafeBufferPointer(smoothed), context: context
            ) { output in
                deliver(
                    raw: raw, context: context, observation: output.result.observation,
                    reason: output.result.unavailability, count: last - first + 1,
                    edge: edge, fit: output, emit: emit)
            }
        } else {
            deliver(
                raw: raw, context: context, observation: nil, reason: reason,
                count: last - first + 1, edge: edge, fit: nil, emit: emit)
        }
        emittedFrameCount += 1
    }

    private func deliver(
        raw: CPPFrameResult, context: CepstralFrameContext,
        observation: CPPObservation?, reason: UnavailabilityReason?, count: Int,
        edge: Bool, fit: BorrowedCPPOutput?, emit: (BorrowedCPPSOutput) -> Void
    ) {
        if let observation {
            validCount += 1
            let adjusted = observation.prominenceDB - correction
            let next = sum + adjusted
            correction = (next - sum) - adjusted
            sum = next
        } else {
            firstFailure = firstFailure ?? reason ?? .analysisFailure
        }
        let slot = emittedFrameCount % layout.ringFrameCapacity
        let range = slot * temporal.count..<(slot + 1) * temporal.count
        let empty = UnsafeBufferPointer<Double>(start: nil, count: 0)
        let result = CPPSFrameResult(
            profile: identity, sourceProfile: sourceIdentity, rawCPP: raw,
            context: context, observation: observation, unavailability: reason,
            temporalSupportFrameCount: count, usesSmoothingEdge: edge,
            lookaheadSeconds: layout.lookaheadSeconds)
        emit(
            BorrowedCPPSOutput(
                result: result,
                quefrencyStepSeconds: profile.cepstrogram.frame.quefrencyStepSeconds,
                powerIsTrendNormalized: profile.settings.subtractTrendBeforeSmoothing,
                raw: rawPowerIsAvailable[slot]
                    ? UnsafeBufferPointer(rebasing: rawPower[range]) : empty,
                prepared: reasons[slot] == nil
                    ? UnsafeBufferPointer(rebasing: preparedPower[range]) : empty,
                temporal: fit == nil ? empty : UnsafeBufferPointer(temporal),
                smoothed: fit == nil ? empty : UnsafeBufferPointer(smoothed), fit: fit))
    }
}
