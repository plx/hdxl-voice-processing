import Foundation

/// Prepared single-owner CPP consumer. Serialize calls on a worker, never on the
/// audio capture callback. Every frame is independent; no history or F0 gate is used.
public final class PreparedCPP {
    public let profile: CPPProfile
    public let identity: ProfileIdentity
    public let sourceIdentity: ProfileIdentity
    public let layout: CPPLayout
    public var scalarWorkspaceBytes: Int {
        (db.count + background.count + residual.count + x.count + scratch.count + medians.count)
            * MemoryLayout<Double>.stride
    }
    private let db: UnsafeMutableBufferPointer<Double>
    private let background: UnsafeMutableBufferPointer<Double>
    private let residual: UnsafeMutableBufferPointer<Double>
    private let x: UnsafeMutableBufferPointer<Double>
    private let scratch: UnsafeMutableBufferPointer<Double>
    private let medians: UnsafeMutableBufferPointer<Double>
    private let diagnostics: WorkerDiagnostics
    private let diagnosticStage: DiagnosticStage
    private let diagnosticProfileToken: UInt64
    private var busy = false

    public convenience init(_ profile: CPPProfile) throws {
        try self.init(profile, diagnostics: WorkerDiagnostics())
    }
    package init(
        _ profile: CPPProfile, diagnostics: WorkerDiagnostics,
        diagnosticStage: DiagnosticStage = .cpp, diagnosticProfileToken: UInt64 = 35
    ) throws {
        let layout = try CPPLayout(profile: profile)
        self.profile = profile
        self.identity = try profile.identity()
        self.sourceIdentity = try profile.sourceIdentity()
        self.layout = layout
        self.diagnostics = diagnostics
        self.diagnosticStage = diagnosticStage
        self.diagnosticProfileToken = diagnosticProfileToken
        func allocate(_ count: Int) -> UnsafeMutableBufferPointer<Double> {
            let result = UnsafeMutableBufferPointer<Double>.allocate(capacity: count)
            result.initialize(repeating: 0)
            return result
        }
        db = allocate(layout.binCount)
        background = allocate(layout.binCount)
        residual = allocate(layout.binCount)
        x = allocate(layout.fitPointCount)
        let scratchCount =
            profile.settings.fitMethod == .completeTheilSen
            ? max(layout.fitPointCount, layout.slopeEvaluationCount) : layout.fitPointCount
        scratch = allocate(scratchCount)
        medians = allocate(
            profile.settings.fitMethod == .siegelRepeatedMedian
                || profile.settings.fitMethod == .praat7002Robust ? layout.fitPointCount : 0)
        for i in x.indices { x[i] = Double(i + layout.firstFitBin) * layout.quefrencyStepSeconds }
    }
    deinit {
        for buffer in [db, background, residual, x, scratch, medians] {
            buffer.deinitialize()
            buffer.deallocate()
        }
    }

    /// Consume a borrowed upstream frame without a copy. Its complete numerical
    /// recipe and identity must match the prepared profile, including conditioning.
    public func analyze(_ input: BorrowedPowerCepstrum<Double>, emit: (BorrowedCPPOutput) -> Void)
        throws
    {
        guard !busy else { throw CPPError.reentrantCall }
        guard input.configuration == profile.frame, input.profile == sourceIdentity else {
            throw CPPError.profileMismatch
        }
        let power = input.stage(.powerCepstrum)
        if let reason = input.unavailability ?? power.unavailability {
            busy = true
            defer { busy = false }
            emitOutput(nil, reason: reason, context: input.context, emit: emit)
        } else {
            try consume(power.values, context: input.context, emit: emit)
        }
    }

    /// Isolated power-bin entrypoint for already-conditioned frame profiles only.
    /// The caller supplies linear power in inverse-seconds-squared on the prepared
    /// q[k]=k/fs grid, and the corresponding observed source context. The array is
    /// read-only. Use the borrowed upstream overload for complete PCM pipelines.
    public func analyzePowerCepstrum(
        _ power: UnsafeBufferPointer<Double>,
        context: CepstralFrameContext, emit: (BorrowedCPPOutput) -> Void
    ) throws {
        guard !busy else { throw CPPError.reentrantCall }
        guard profile.cepstrogram == nil else { throw CPPError.profileMismatch }
        try consume(power, context: context, emit: emit)
    }

    private func consume(
        _ power: UnsafeBufferPointer<Double>, context: CepstralFrameContext,
        emit: (BorrowedCPPOutput) -> Void
    ) throws {
        guard power.count == layout.binCount else { throw CPPError.invalidBufferSize }
        guard context.suppliedAnalysisSampleCount == profile.frame.frameLength,
            context.timing.includedSampleCount > 0
        else { throw CPPError.unexpectedContext }
        for value in power where !value.isFinite || value < 0 { throw CPPError.invalidInput }
        busy = true
        defer { busy = false }
        var metadata = DiagnosticMetadata()
        metadata.profileToken = diagnosticProfileToken
        metadata.frameSequence = context.frameIndex
        metadata.sampleCount = UInt32(power.count)
        metadata.validity = layout.unavailability == nil ? .available : .failed
        let observation = diagnostics.withFrame(metadata) {
            diagnostics.withInterval(diagnosticStage) { compute(power) }
        }
        emitOutput(
            observation,
            reason: layout.unavailability ?? (observation == nil ? .analysisFailure : nil),
            context: context, emit: emit)
    }

    private func emitOutput(
        _ observation: CPPObservation?, reason: UnavailabilityReason?,
        context: CepstralFrameContext, emit: (BorrowedCPPOutput) -> Void
    ) {
        let count = observation == nil ? 0 : layout.binCount
        let result = CPPFrameResult(
            profile: identity, sourceProfile: sourceIdentity,
            context: context, layout: layout, observation: observation, unavailability: reason)
        emit(
            BorrowedCPPOutput(
                result: result,
                decibels: UnsafeBufferPointer(start: db.baseAddress, count: count),
                background: UnsafeBufferPointer(start: background.baseAddress, count: count),
                residual: UnsafeBufferPointer(start: residual.baseAddress, count: count)))
    }

    private func compute(_ power: UnsafeBufferPointer<Double>) -> CPPObservation? {
        guard layout.unavailability == nil else { return nil }
        for i in power.indices {
            db[i] = 10 * log10(power[i] + CPPConfiguration.additivePowerFloor)
        }
        let coefficients = fit()
        let peak = findPeak()
        let baseline = coefficients.slope * peak.q + coefficients.intercept
        let prominence = peak.db - baseline
        guard coefficients.slope.isFinite, coefficients.intercept.isFinite,
            peak.q.isFinite, peak.db.isFinite, baseline.isFinite, prominence.isFinite
        else { return nil }
        for i in db.indices {
            background[i] =
                coefficients.slope * (Double(i) * layout.quefrencyStepSeconds)
                + coefficients.intercept
            residual[i] = db[i] - background[i]
        }
        var sum = 0.0
        var sumCorrection = 0.0
        var squares = 0.0
        var squareCorrection = 0.0
        var maximum = 0.0
        for i in 0..<layout.fitPointCount {
            let value = residual[layout.firstFitBin + i]
            scratch[i] = value
            compensatedAdd(value, sum: &sum, correction: &sumCorrection)
            compensatedAdd(value * value, sum: &squares, correction: &squareCorrection)
            maximum = max(maximum, abs(value))
        }
        return CPPObservation(
            prominenceDB: prominence, peakQuefrencySeconds: peak.q,
            peakDB: peak.db, backgroundDB: baseline, slopeDBPerSecond: coefficients.slope,
            interceptDB: coefficients.intercept,
            residualMeanDB: (sum + sumCorrection) / Double(layout.fitPointCount),
            residualRMSDB: sqrt((squares + squareCorrection) / Double(layout.fitPointCount)),
            residualMedianDB: CPPSelection.median(scratch, count: layout.fitPointCount),
            residualMaximumAbsoluteDB: maximum,
            peakIsAtSearchBoundary: peak.q == layout.searchStartSeconds
                || peak.q == layout.searchEndSeconds,
            usedBidirectionalTieRule: peak.tie)
    }

    private func fit() -> (slope: Double, intercept: Double) {
        let count = layout.fitPointCount
        let offset = layout.firstFitBin
        let slope: Double
        switch profile.settings.fitMethod {
        case .leastSquares:
            var sx = 0.0
            var cx = 0.0
            var sy = 0.0
            var cy = 0.0
            for i in 0..<count {
                compensatedAdd(x[i], sum: &sx, correction: &cx)
                compensatedAdd(db[offset + i], sum: &sy, correction: &cy)
            }
            let mean = (sx + cx) / Double(count)
            var covariance = 0.0
            var cc = 0.0
            var variance = 0.0
            var cv = 0.0
            for i in 0..<count {
                let delta = x[i] - mean
                compensatedAdd(delta * db[offset + i], sum: &covariance, correction: &cc)
                compensatedAdd(delta * delta, sum: &variance, correction: &cv)
            }
            slope = (covariance + cc) / (variance + cv)
            return (slope, ((sy + cy) - (sx + cx) * slope) / Double(count))
        case .completeTheilSen:
            var cursor = 0
            for i in 0..<(count - 1) {
                for j in (i + 1)..<count {
                    scratch[cursor] = (db[offset + j] - db[offset + i]) / (x[j] - x[i])
                    cursor += 1
                }
            }
            slope = CPPSelection.median(scratch, count: cursor)
        case .siegelRepeatedMedian, .praat7002Robust:
            let medianCount = profile.settings.fitMethod == .praat7002Robust ? count - 1 : count
            for i in 0..<medianCount {
                var cursor = 0
                for j in 0..<count where j != i {
                    scratch[cursor] = (db[offset + j] - db[offset + i]) / (x[j] - x[i])
                    cursor += 1
                }
                medians[i] = CPPSelection.median(scratch, count: cursor)
            }
            slope = CPPSelection.median(medians, count: medianCount)
        }
        for i in 0..<count { scratch[i] = db[offset + i] - slope * x[i] }
        return (slope, CPPSelection.median(scratch, count: count))
    }

    private func findPeak() -> (q: Double, db: Double, tie: Bool) {
        let step = layout.quefrencyStepSeconds
        let first = Int(ceil(layout.searchStartSeconds / step))
        let last = min(db.count - 1, Int(floor(layout.searchEndSeconds / step)))
        if first > last {
            let left = interpolatedValue(at: layout.searchStartSeconds)
            let right = interpolatedValue(at: layout.searchEndSeconds)
            let q =
                left == right
                ? (layout.searchStartSeconds + layout.searchEndSeconds) * 0.5
                : left > right ? layout.searchStartSeconds : layout.searchEndSeconds
            return (q, max(left, right), false)
        }
        let forward = peakFromSide(first: first, last: last, reverse: false)
        let backward = peakFromSide(first: first, last: last, reverse: true)
        // The pinned rule converts real one-based indices by truncation, including
        // fractional parabolic positions. Preserve this separately from interpolation.
        let leftIndex = Int(forward.q / step + 1)
        let rightIndex = Int(backward.q / step + 1)
        if leftIndex != rightIndex && rightIndex - leftIndex <= 5 {
            let center = (Double(leftIndex + rightIndex) * 0.5 - 1) * step
            return (center, db[leftIndex - 1], true)
        }
        return (forward.q, forward.db, false)
    }

    private func peakFromSide(first: Int, last: Int, reverse: Bool) -> (q: Double, db: Double) {
        var best = db[first]
        var position = Double(first + 1)
        if db[last] > best {
            best = db[last]
            position = Double(last + 1)
        }
        let begin = max(1, first)
        let end = min(last, db.count - 2)
        if begin <= end {
            for k in stride(
                from: reverse ? end : begin, through: reverse ? begin : end, by: reverse ? -1 : 1)
            {
                let previous = db[k + (reverse ? 1 : -1)]
                let next = db[k + (reverse ? -1 : 1)]
                guard relativeDifference(db[k], previous) > 1e-12,
                    relativeDifference(db[k], next) > -1e-12
                else { continue }
                var candidate = db[k]
                var coordinate = Double(k + 1)
                if profile.settings.interpolation == .parabolic {
                    let gradient = (db[k + 1] - db[k - 1]) * 0.5
                    let curvature = 2 * db[k] - db[k - 1] - db[k + 1]
                    // Undefined flat interpolants cannot improve a finite endpoint.
                    if curvature == 0 { continue }
                    coordinate += gradient / curvature
                    candidate += 0.5 * gradient * gradient / curvature
                }
                if candidate > best && candidate.isFinite && coordinate.isFinite {
                    best = candidate
                    position = coordinate
                }
            }
        }
        let q = min(
            layout.searchEndSeconds,
            max(layout.searchStartSeconds, (position - 1) * layout.quefrencyStepSeconds))
        return (q, best)
    }

    private func interpolatedValue(at q: Double) -> Double {
        let index = q / layout.quefrencyStepSeconds
        if profile.settings.interpolation == .none {
            return db[min(db.count - 1, max(0, Int(index.rounded(.toNearestOrAwayFromZero))))]
        }
        let lower = min(db.count - 1, max(0, Int(floor(index))))
        let upper = min(db.count - 1, lower + 1)
        let fraction = index - Double(lower)
        return (1 - fraction) * db[lower] + fraction * db[upper]
    }
}

private func relativeDifference(_ lhs: Double, _ rhs: Double) -> Double {
    lhs == 0 || rhs == 0 ? lhs - rhs : (lhs - rhs) / abs(lhs)
}

private func compensatedAdd(_ value: Double, sum: inout Double, correction: inout Double) {
    let next = sum + value
    correction += abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
    sum = next
}
