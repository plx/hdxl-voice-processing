#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Foundation
    import HDXLVoiceProcessing

    struct CaptureLifecycleBatch: Sendable {
        let events: [PCMTransferScheduleEvent]
        let idle: Bool
        let ended: Bool
    }

    protocol CaptureLifecycleWorking: Actor {
        func prepare(
            input: CaptureLifecycleInput, analysis: CaptureLifecycleAnalysis,
            limits: CaptureLifecycleWorkerLimits
        ) async throws -> CaptureLifecycleConfiguration
        func next() async throws -> CaptureLifecycleBatch
        func close() async
    }

    /// This actor is the sole owner of mutable, non-Sendable DSP and scratch storage.
    actor CaptureAnalysisWorker: CaptureLifecycleWorking {
        private enum Schedule {
            case float(PreparedPCMTransferSchedule<Float>)
            case double(PreparedPCMTransferSchedule<Double>)
            func cancel() {
                switch self {
                case .float(let p): p.cancel()
                case .double(let p): p.cancel()
                }
            }
            func drain(_ emit: (PCMTransferScheduleEvent) -> Void) throws
                -> PCMTransferScheduleDrain
            {
                switch self {
                case .float(let p): try p.drain(maximumEvents: 1, emit: emit)
                case .double(let p): try p.drain(maximumEvents: 1, emit: emit)
                }
            }
        }
        private var schedule: Schedule?
        private var maximumResults = 0
        private var closed = false

        func prepare(
            input: CaptureLifecycleInput, analysis: CaptureLifecycleAnalysis,
            limits: CaptureLifecycleWorkerLimits
        ) throws -> CaptureLifecycleConfiguration {
            try Task.checkCancellation()
            guard schedule == nil, !closed else { throw AnalysisScheduleError.invalidState }
            let observation = input.observation
            let profile = try analysis(observation.effectiveFormat, observation.channelSelection)
            guard profile.inputFormat == observation.effectiveFormat,
                profile.channels == observation.channelSelection,
                input.transfer.configuration.format == observation.effectiveFormat,
                input.transfer.configuration.epoch == observation.epoch
            else { throw AnalysisScheduleError.invalidConfiguration }
            try profile.validate(mode: .continuous)
            let identity = try profile.identity()
            let initialAnalysisEpoch = StreamEpoch(streamID: UUID())
            let origin = try AnalysisScheduleOrigin(
                source: SourceInterval(
                    epoch: observation.epoch, startSample: 0, sampleCount: 0,
                    sampleRate: observation.effectiveFormat.sampleRate),
                continuityEpoch: initialAnalysisEpoch)
            if observation.effectiveFormat.encoding == .float32 {
                schedule = .float(
                    try PreparedPCMTransferSchedule(
                        transfer: input.transfer, profile: profile, origin: origin,
                        sourceTileCapacity: limits.sourceTileCapacity))
            } else {
                schedule = .double(
                    try PreparedPCMTransferSchedule(
                        transfer: input.transfer, profile: profile, origin: origin,
                        sourceTileCapacity: limits.sourceTileCapacity))
            }
            maximumResults = limits.maximumResultEvents
            try Task.checkCancellation()
            return CaptureLifecycleConfiguration(
                capture: observation, audioSession: input.audioSession, analysis: profile,
                analysisIdentity: identity, initialAnalysisContinuityEpoch: initialAnalysisEpoch)
        }

        func next() throws -> CaptureLifecycleBatch {
            try Task.checkCancellation()
            guard let schedule, !closed else { throw AnalysisScheduleError.invalidState }
            var events: [PCMTransferScheduleEvent] = []
            events.reserveCapacity(maximumResults)
            var overflow = false
            let report = try schedule.drain { event in
                if Task.isCancelled {
                    schedule.cancel()
                    return
                }
                guard events.count < maximumResults else {
                    overflow = true
                    schedule.cancel()
                    return
                }
                events.append(event)
            }
            try Task.checkCancellation()
            guard !overflow else {
                throw CaptureLifecycleFailure(
                    stage: .analysis, reason: .resultCapacityExceeded,
                    recovery: .correctConfiguration)
            }
            return CaptureLifecycleBatch(
                events: events, idle: report.deliveredEvents == 0 && !report.reachedEnd,
                ended: report.reachedEnd)
        }

        func close() {
            closed = true
            schedule?.cancel()
            schedule = nil
        }
    }

#endif
