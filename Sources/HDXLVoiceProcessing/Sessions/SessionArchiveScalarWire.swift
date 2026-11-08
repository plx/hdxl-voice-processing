import Foundation

enum SessionArchiveScalarWire {
    // Version-1 tag assignments are explicit and immutable. Do not derive these
    // from CaseIterable order or insert a new case into an existing wire table.
    static let reasons: [UnavailabilityReason] = [
        .insufficientData, .silence, .clipping, .unsupportedRange, .inapplicableTask,
        .lowConfidence, .invalidInput, .discontinuity, .analysisFailure, .cancelled,
        .missingAcquisition, .excluded, .stale,
    ]
    static let warnings: [MeasurementWarning] = [
        .clipping, .lowConfidence, .partialCoverage, .exploratoryApplicability,
    ]
    static let tags: [MaskTag] = [
        .missingAcquisition, .silence, .suspectedExternalNoise, .clipping,
        .speechDetected, .nonSpeechDetected, .lowPeriodicityConfidence, .algorithmInsufficiency,
        .energyEligible, .energyIneligible,
    ]
    static let units: [MeasurementUnit] = [
        .hertz, .seconds, .samples, .normalizedAmplitude, .normalizedSquaredAmplitude,
        .normalizedAmplitudeSeconds, .normalizedSquaredAmplitudeSecondsSquared,
        .inverseSeconds, .inverseSecondsSquared, .decibelsRatio, .decibelsFullScale,
        .decibelsSPL, .decibelsPerOctave, .decibelsPerHertz, .fraction, .percent, .dimensionless,
    ]

    static func encode(
        _ value: SessionArchiveMeasurement, seriesIndex: UInt32, catalog: SessionArchiveCatalog
    ) throws -> Data {
        try catalog.validate(value, seriesIndex: seriesIndex)
        var encoder = SessionArchiveBinaryEncoder(limit: catalog.limits.maximumRecordBytes)
        try encoder.integer(seriesIndex)
        if let sample = value.timestamp.sourceSample {
            try encoder.integer(UInt64(sample))
        } else {
            try encoder.real(value.timestamp.secondsFromOrigin!)
        }
        try encode(value.result.timing, to: &encoder)
        switch value.result.outcome {
        case .available(let estimate):
            try encoder.integer(UInt8(0))
            try encoder.real(estimate.value)
            try encoder.integer(UInt8(estimate.confidence == nil ? 0 : 1))
            if let confidence = estimate.confidence { try encoder.real(confidence) }
            var bits: UInt8 = 0
            for warning in estimate.warnings {
                guard let bit = warnings.firstIndex(of: warning) else {
                    throw SessionArchiveError.unsupportedRecord
                }
                bits |= 1 << bit
            }
            try encoder.integer(bits)
        case .unavailable(let reason):
            guard let code = reasons.firstIndex(of: reason) else {
                throw SessionArchiveError.unsupportedRecord
            }
            try encoder.integer(UInt8(1))
            try encoder.integer(UInt8(code))
        }
        if let scheduled = value.scheduled {
            try encode(scheduled.dependencyTiming, to: &encoder)
            let coverage = scheduled.dependencyCoverage
            try encoder.integer(UInt64(coverage.source))
            try encoder.integer(UInt64(coverage.eligible))
            try encoder.integer(UInt64(coverage.selected))
            for tag in tags { try encoder.integer(UInt64(coverage.samples(tag: tag))) }
            // The timestamp already stores this frame's exact original center.
            try encoder.real(scheduled.workerBatchingUpperBoundSeconds)
        }
        try encoder.integer(UInt32(value.result.intermediatePolicy.maximumScalarCount))
        try encoder.integer(UInt32(value.result.intermediates.count))
        for snapshot in value.result.intermediates {
            try encoder.text(snapshot.stage.name)
            try encoder.integer(snapshot.stage.version)
            try encoder.integer(UInt64(snapshot.source.startSample))
            try encoder.integer(UInt64(snapshot.source.sampleCount))
            guard let x = units.firstIndex(of: snapshot.xUnit),
                let y = units.firstIndex(of: snapshot.yUnit)
            else {
                throw SessionArchiveError.unsupportedRecord
            }
            try encoder.integer(UInt8(x))
            try encoder.integer(UInt8(y))
            try encoder.real(snapshot.xOrigin)
            try encoder.real(snapshot.xStep)
            try encoder.integer(UInt32(snapshot.values.count))
            for scalar in snapshot.values { try encoder.real(scalar) }
        }
        return encoder.data
    }

    static func decode(_ payload: Data, catalog: SessionArchiveCatalog) throws -> (
        UInt32, SessionArchiveMeasurement
    ) {
        do { return try decodeValidated(payload, catalog: catalog) } catch let error
            as SessionArchiveError
        { throw error } catch { throw SessionArchiveError.malformedRecord }
    }

    private static func decodeValidated(
        _ payload: Data, catalog: SessionArchiveCatalog
    ) throws -> (UInt32, SessionArchiveMeasurement) {
        guard payload.count <= catalog.limits.maximumRecordBytes else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        var decoder = SessionArchiveBinaryDecoder(data: payload)
        let index = try decoder.unsigned(UInt32.self)
        let (series, profile, source) = try catalog.context(for: index)
        let timestamp: SessionArchiveTimestamp
        switch series.clock {
        case .sourceSamples:
            timestamp = try SessionArchiveTimestamp(sourceSample: decoder.nonnegativeInteger())
        case .secondsFromOrigin:
            timestamp = try SessionArchiveTimestamp(secondsFromOrigin: decoder.real())
        }
        let timing = try decodeTiming(from: &decoder, source: source)
        let outcome: MeasurementOutcome
        switch try decoder.unsigned(UInt8.self) {
        case 0:
            let value = try decoder.real()
            let confidence: Double?
            switch try decoder.unsigned(UInt8.self) {
            case 0: confidence = nil
            case 1: confidence = try decoder.real()
            default: throw SessionArchiveError.malformedRecord
            }
            let bits = try decoder.unsigned(UInt8.self)
            guard bits & 0xf0 == 0 else { throw SessionArchiveError.malformedRecord }
            outcome = .available(
                try ScalarEstimate(
                    value: value, confidence: confidence,
                    warnings: warnings.enumerated().compactMap {
                        bits & (1 << $0.offset) != 0 ? $0.element : nil
                    }))
        case 1:
            let code = Int(try decoder.unsigned(UInt8.self))
            guard code < reasons.count else { throw SessionArchiveError.malformedRecord }
            outcome = .unavailable(reasons[code])
        default: throw SessionArchiveError.malformedRecord
        }
        let scheduled: SessionArchiveScheduledMetadata?
        if series.isScheduled {
            let dependency = try decodeTiming(from: &decoder, source: source)
            let count = try decoder.nonnegativeInteger()
            let eligible = try decoder.nonnegativeInteger()
            let selected = try decoder.nonnegativeInteger()
            var counts: [MaskTag: Int64] = [:]
            for tag in tags { counts[tag] = try decoder.nonnegativeInteger() }
            scheduled = try SessionArchiveScheduledMetadata(
                dependencyTiming: dependency,
                dependencyCoverage: SessionArchiveCoverage(
                    source: count, eligible: eligible, selected: selected, tags: counts),
                frameCenterSecondsFromOrigin: timestamp.secondsFromOrigin!,
                workerBatchingUpperBoundSeconds: decoder.real())
        } else {
            scheduled = nil
        }
        let budget = Int(try decoder.unsigned(UInt32.self))
        guard budget <= catalog.limits.maximumIntermediateScalars else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        let count = Int(try decoder.unsigned(UInt32.self))
        guard count <= budget else { throw SessionArchiveError.sizeLimitExceeded }
        var remaining = budget
        var snapshots: [IntermediateSnapshot] = []
        // Do not reserve a declared count: a short malicious record must not
        // allocate a large array before its per-snapshot fields are validated.
        for _ in 0..<count {
            let stage = try VersionedIdentifier(
                name: decoder.text(), version: decoder.unsigned(UInt32.self))
            let interval = try decodeInterval(from: &decoder, source: source)
            let x = Int(try decoder.unsigned(UInt8.self))
            let y = Int(try decoder.unsigned(UInt8.self))
            guard x < units.count, y < units.count else {
                throw SessionArchiveError.incompatibleUnit
            }
            let xOrigin = try decoder.real()
            let xStep = try decoder.real()
            let n = Int(try decoder.unsigned(UInt32.self))
            guard n > 0, n <= remaining else { throw SessionArchiveError.sizeLimitExceeded }
            guard n <= decoder.remaining / 8 else { throw SessionArchiveError.malformedRecord }
            remaining -= n
            var values: [Double] = []
            values.reserveCapacity(n)
            for _ in 0..<n { values.append(try decoder.real()) }
            snapshots.append(
                try IntermediateSnapshot(
                    stage: stage, source: interval, xUnit: units[x], yUnit: units[y],
                    xOrigin: xOrigin, xStep: xStep, values: values))
        }
        try decoder.finish()
        let result = try MeasurementResult(
            measurement: series.measurement, profile: profile.identity, timing: timing,
            outcome: outcome,
            intermediatePolicy: IntermediateOutputPolicy(maximumScalarCount: budget),
            intermediates: snapshots)
        let value = try SessionArchiveMeasurement(
            timestamp: timestamp, result: result, scheduled: scheduled)
        try catalog.validate(value, seriesIndex: index)
        return (index, value)
    }

    private static func encode(
        _ timing: AnalysisTiming, to encoder: inout SessionArchiveBinaryEncoder
    ) throws {
        try encoder.integer(UInt64(timing.source.startSample))
        try encoder.integer(UInt64(timing.source.sampleCount))
        try encoder.integer(UInt64(timing.includedSampleCount))
        try encoder.real(timing.effectiveDelaySeconds)
        let flags: UInt8 =
            (timing.sourceStartSeconds == nil ? 0 : 1)
            | (timing.hostStartNanoseconds == nil ? 0 : 2)
            | (timing.completedHostNanoseconds == nil ? 0 : 4)
        try encoder.integer(flags)
        if let value = timing.sourceStartSeconds { try encoder.real(value) }
        if let value = timing.hostStartNanoseconds { try encoder.integer(value) }
        if let value = timing.completedHostNanoseconds { try encoder.integer(value) }
    }

    private static func decodeInterval(
        from decoder: inout SessionArchiveBinaryDecoder, source: SessionArchiveSource
    ) throws -> SourceInterval {
        try SourceInterval(
            epoch: source.origin.source.epoch, startSample: decoder.nonnegativeInteger(),
            sampleCount: decoder.nonnegativeInteger(), sampleRate: source.origin.source.sampleRate)
    }

    private static func decodeTiming(
        from decoder: inout SessionArchiveBinaryDecoder, source: SessionArchiveSource
    ) throws -> AnalysisTiming {
        let interval = try decodeInterval(from: &decoder, source: source)
        let included = try decoder.nonnegativeInteger()
        let delay = try decoder.real()
        let flags = try decoder.unsigned(UInt8.self)
        guard flags & 0xf8 == 0 else { throw SessionArchiveError.malformedRecord }
        let seconds = flags & 1 == 0 ? nil : try decoder.real()
        let host = flags & 2 == 0 ? nil : try decoder.unsigned(UInt64.self)
        let completed = flags & 4 == 0 ? nil : try decoder.unsigned(UInt64.self)
        return try AnalysisTiming(
            source: interval, includedSampleCount: included, sourceStartSeconds: seconds,
            hostStartNanoseconds: host, completedHostNanoseconds: completed,
            effectiveDelaySeconds: delay)
    }
}
