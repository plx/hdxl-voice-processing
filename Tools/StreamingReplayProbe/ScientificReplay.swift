#if os(macOS)
    import CryptoKit
    import Foundation
    import HDXLVoiceProcessing
    import HDXLVoiceProcessingAudio

    struct FrameRecord: Codable {
        let lane: String
        let continuity: UInt64
        let regionStart: Int64
        let windowEnd: Int64
        let acousticEndNS: UInt64
        let dependencyEndNS: UInt64
        let effectiveDelaySeconds: Double
        let publication: UInt64
        let publishedNS: UInt64
        let observedNS: UInt64
        let outcomes: [String: String]
    }

    struct RequirementRecord: Codable {
        let lane: String
        let supportSeconds: Double
        let hopSeconds: Double
        let filterWarmupFrames: Int
        let filterLookaheadSeconds: Double
        let smoothingLookaheadSeconds: Double
        let batchUpperBoundSeconds: Double

        init(_ requirement: AnalysisScheduleRequirements, rate: Int) {
            lane = requirement.algorithm.rawValue
            supportSeconds = requirement.frameSupportSeconds
            hopSeconds = requirement.outputIntervalSeconds
            filterWarmupFrames = requirement.filterWarmupSourceSamples
            filterLookaheadSeconds = requirement.filterLookaheadSeconds
            smoothingLookaheadSeconds = requirement.centeredSmoothingLookaheadSeconds
            batchUpperBoundSeconds = 256 / Double(rate)
        }
    }

    /// Normalize only run-local identities and absolute host time for cross-mode comparison.
    /// The same-run independent reference also checks the full native frame, including clocks.
    private struct ScientificRow: Encodable {
        let lane: ScheduledAlgorithm
        let schedule: String
        let continuity: UInt64
        let regionStart: Int64
        let supportStart: Int64
        let supportCount: Int64
        let windowEnd: Int64
        let source: Int64
        let selected: Int64
        let eligible: Int64
        let delay: Double
        let outcomes: [String: MeasurementOutcome]
    }

    private struct WindowPosition: Hashable {
        let lane: ScheduledAlgorithm
        let start: Int64
        let end: Int64
        init(_ frame: ScheduledFrame) throws {
            lane = frame.algorithm
            let window = try frame.export(metrics(for: lane)[0]).observationWindow
            start = window.startSample
            end = window.endSample
        }
    }

    struct WindowDenominator: Codable {
        var noCapacityLossFrames = 0
        var omittedWindowPositions = 0
        var addedWindowPositionsAfterReset = 0
        var withheldAtExplicitStop = 0
    }

    struct ScientificReport: Codable {
        let windows: [String: WindowDenominator]
        let equivalentNativeFrames: Int
        let sha256: String
        let records: [FrameRecord]
    }

    func metrics(for lane: ScheduledAlgorithm) -> [ScheduledMetric] {
        switch lane {
        case .levels:
            [
                .rms, .meanSquare, .peakAmplitude, .crestFactor, .levelDBFS, .clippingFraction,
                .kWeightedEnergy,
            ]
        case .yin: [.fundamentalFrequency, .trackedFundamentalFrequency]
        case .cpps: [.cpps, .cpp]
        case .hnr: [.harmonicToNoiseRatio]
        case .swipePrime: [.fundamentalFrequency]
        }
    }

    func verifyScientificReplay(
        configuration: CaptureLifecycleConfiguration, ingress: IngressReport,
        frames: [ReceivedFrame],
        rate: Int, seed: UInt32
    ) throws -> ScientificReport {
        let signal = replaySignal(rate: rate, seed: seed)
        let anchors = Dictionary(
            uniqueKeysWithValues: ingress.retainedCallbacks.map {
                ($0.sourceStart, $0.sourceHostNS)
            })
        var index = 0
        var mismatch: String?
        func compare(_ expected: ScheduledFrame) {
            defer { index += 1 }
            guard mismatch == nil else { return }
            guard index < frames.count, frames[index].frame == expected else {
                mismatch =
                    "independent schedule differs at frame \(index), \(expected.algorithm) source \(expected.timing.source.startSample)"
                return
            }
        }
        func replay(
            _ regions: [Range<Int>], emit: (ScheduledFrame) -> Void,
            finalTail: (ScheduledFrame) -> Void
        ) throws {
            var continuity = configuration.initialAnalysisContinuityEpoch
            for (regionIndex, region) in regions.enumerated() {
                guard let anchor = anchors[region.lowerBound] else {
                    throw ReplayFailure("missing accepted region anchor")
                }
                let source = try SourceInterval(
                    epoch: configuration.capture.epoch, startSample: Int64(region.lowerBound),
                    sampleCount: 0, sampleRate: Double(rate))
                let origin = try AnalysisScheduleOrigin(
                    source: source, continuityEpoch: continuity, hostStartNanoseconds: anchor)
                let direct = try PreparedAnalysisSchedule<Float>(
                    profile: configuration.analysis, origin: origin, mode: .continuous)
                var cursor = region.lowerBound
                while cursor < region.upperBound {
                    let phase = cursor % rate
                    let count = min(173, region.upperBound - cursor, rate - phase)
                    let interval = try SourceInterval(
                        epoch: source.epoch, startSample: Int64(cursor), sampleCount: Int64(count),
                        sampleRate: Double(rate))
                    try signal.withUnsafeBufferPointer { samples in
                        _ = try direct.processInterleaved(
                            UnsafeBufferPointer(rebasing: samples[phase..<(phase + count)]),
                            interval: interval, emit: emit)
                    }
                    cursor += count
                }
                if regionIndex < regions.count - 1 {
                    _ = try direct.finish(emit: emit)
                    continuity = try continuity.successor()
                } else {
                    _ = try direct.finish(emit: finalTail)
                }
            }
        }
        var windows: [String: WindowDenominator] = [:]
        try replay(ingress.admittedRegions, emit: compare) { frame in
            windows[frame.algorithm.rawValue, default: WindowDenominator()]
                .withheldAtExplicitStop += 1
        }
        if let mismatch { throw ReplayFailure(mismatch) }
        guard index == frames.count else {
            throw ReplayFailure("independent schedule emitted \(index) of \(frames.count) frames")
        }
        // Frame opportunities use exact estimator window positions. A reset can both
        // remove windows and introduce different ones on its new local grid.
        let actualWindows = try frames.map { try WindowPosition($0.frame) }
        var positions = Dictionary(actualWindows.map { ($0, 1) }, uniquingKeysWith: +)
        if ingress.offeredFrames == ingress.admittedFrames {
            for position in actualWindows {
                windows[position.lane.rawValue, default: WindowDenominator()]
                    .noCapacityLossFrames += 1
            }
        } else {
            var offeredRegions: [Range<Int>] = []
            for call in ingress.retainedCallbacks {
                let end = call.sourceStart + call.frames
                if offeredRegions.last?.upperBound == call.sourceStart {
                    let start = offeredRegions.removeLast().lowerBound
                    offeredRegions.append(start..<end)
                } else {
                    offeredRegions.append(call.sourceStart..<end)
                }
            }
            var projectionFailure: (any Error)?
            try replay(
                offeredRegions,
                emit: { frame in
                    do {
                        let key = try WindowPosition(frame)
                        let lane = key.lane.rawValue
                        windows[lane, default: WindowDenominator()].noCapacityLossFrames += 1
                        if positions[key, default: 0] > 0 {
                            positions[key, default: 0] -= 1
                        } else {
                            windows[lane, default: WindowDenominator()].omittedWindowPositions += 1
                        }
                    } catch { projectionFailure = error }
                }, finalTail: { _ in })
            if let projectionFailure { throw projectionFailure }
            for (position, count) in positions {
                windows[position.lane.rawValue, default: WindowDenominator()]
                    .addedWindowPositionsAfterReset += count
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var digest = SHA256()
        var records: [FrameRecord] = []
        for item in frames {
            let frame = item.frame
            let metrics = metrics(for: frame.algorithm)
            let projection = try frame.export(metrics[0])
            let end = projection.observationWindow.endSample
            let origin = frame.origin
            guard
                let acoustic = try origin.hostNanoseconds(
                    atAnalysisSample: end - origin.source.startSample),
                let dependency = try origin.hostNanoseconds(
                    atAnalysisSample: frame.timing.source.endSample - origin.source.startSample)
            else { throw ReplayFailure("missing frame clock") }
            var outcomes: [String: MeasurementOutcome] = [:]
            var statuses: [String: String] = [:]
            for metric in metrics {
                let outcome = try frame.measurementResult(metric).outcome
                outcomes[metric.rawValue] = outcome
                switch outcome {
                case .available: statuses[metric.rawValue] = "available"
                case .unavailable(let reason): statuses[metric.rawValue] = reason.rawValue
                }
            }
            let scientific = ScientificRow(
                lane: frame.algorithm, schedule: frame.schedule.sha256,
                continuity: origin.continuityEpoch.sequence,
                regionStart: origin.source.startSample,
                supportStart: frame.timing.source.startSample,
                supportCount: frame.timing.source.sampleCount, windowEnd: end,
                source: frame.coverage.source,
                selected: frame.coverage.selected, eligible: frame.coverage.eligible,
                delay: frame.timing.effectiveDelaySeconds, outcomes: outcomes)
            digest.update(data: try encoder.encode(scientific))
            records.append(
                FrameRecord(
                    lane: frame.algorithm.rawValue, continuity: origin.continuityEpoch.sequence,
                    regionStart: origin.source.startSample,
                    windowEnd: end, acousticEndNS: acoustic, dependencyEndNS: dependency,
                    effectiveDelaySeconds: frame.timing.effectiveDelaySeconds,
                    publication: item.publication,
                    publishedNS: item.publishedNS, observedNS: item.observedNS, outcomes: statuses))
        }
        return ScientificReport(
            windows: windows, equivalentNativeFrames: index,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            records: records)
    }
#endif
