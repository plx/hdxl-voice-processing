/// Bounded offline worker storage. No PCM or frame history is retained. This is
/// intentionally outside the capture/prepared-scheduler no-allocation contract.
package struct CalibrationSummaryAccumulator {
    private struct Bucket {
        let metric: ScheduledMetric
        var values: [Double] = []
        var unavailable: [String: Int] = [:]
        var warnings: [String: Int] = [:]
        var count = 0
    }

    private let profile: ProfileIdentity
    private let limit: Int
    private var buckets: [Bucket]
    private var failed = false
    package private(set) var retainedValueCount = 0
    package var retainedValueBytes: Int { retainedValueCount * MemoryLayout<Double>.stride }
    package var reservedValueBytes: Int {
        buckets.count * limit * MemoryLayout<Double>.stride
    }

    package init(profile: AnalysisScheduleProfile, maximumObservationsPerMetric: Int) throws {
        guard
            (1...CalibrationMetricSummary.maximumObservationCount).contains(
                maximumObservationsPerMetric)
        else { throw CalibrationError.capacityExceeded }
        self.profile = try profile.identity()
        limit = maximumObservationsPerMetric
        buckets = calibrationMetrics(for: profile).map { metric in
            var bucket = Bucket(metric: metric)
            bucket.values.reserveCapacity(maximumObservationsPerMetric)
            return bucket
        }
    }

    package mutating func append(_ frame: ScheduledFrame) throws {
        guard !failed else { throw CalibrationError.invalidState }
        do {
            guard frame.schedule == profile else { throw CalibrationError.incompatibleDataset }
            for index in buckets.indices {
                let metric = buckets[index].metric
                let algorithm: ScheduledAlgorithm
                switch metric {
                case .rms, .levelDBFS: algorithm = .levels
                case .fundamentalFrequency, .trackedFundamentalFrequency: algorithm = .yin
                default: algorithm = .cpps
                }
                guard frame.algorithm == algorithm else { continue }
                guard buckets[index].count < limit else { throw CalibrationError.capacityExceeded }
                switch try frame.measurementResult(metric).outcome {
                case .available(let estimate):
                    buckets[index].values.append(estimate.value)
                    retainedValueCount += 1
                    for warning in estimate.warnings {
                        buckets[index].warnings[warning.rawValue, default: 0] += 1
                    }
                case .unavailable(let reason):
                    buckets[index].unavailable[reason.rawValue, default: 0] += 1
                }
                buckets[index].count += 1
            }
        } catch {
            failed = true
            throw error
        }
    }

    package func finish(key: CalibrationAnalysisKey, coverage: CalibrationCoverage) throws
        -> CalibrationAnalysisRecord
    {
        guard !failed, key.profile == profile else { throw CalibrationError.invalidState }
        return try CalibrationAnalysisRecord(
            key: key, coverage: coverage,
            summaries: buckets.map {
                try CalibrationMetricSummary(
                    metric: $0.metric, values: $0.values,
                    unavailable: $0.unavailable, warnings: $0.warnings)
            })
    }
}
