#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Dispatch
    import Foundation
    import HDXLVoiceProcessing

    struct CaptureLifecycleBatch: Sendable {
        let events: [PCMTransferScheduleEvent]
        let idle: Bool
        let ended: Bool
        var observation: CaptureWorkerObservation? = nil
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
        private var transfer: PCMTransfer?
        private let mode: RuntimeDiagnosticMode
        private let diagnostics: WorkerDiagnostics
        private let clock: @Sendable () -> UInt64
        private var turns: UInt64 = 0

        init(
            diagnostics mode: RuntimeDiagnosticMode = .disabled,
            sink: (any DiagnosticSink)? = nil,
            clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
        ) {
            self.mode = mode
            self.diagnostics = WorkerDiagnostics(mode: mode.facadeMode, sink: sink)
            self.clock = clock
        }

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
                        sourceTileCapacity: limits.sourceTileCapacity,
                        measureBlockTimes: mode != .disabled, clock: clock))
            } else {
                schedule = .double(
                    try PreparedPCMTransferSchedule(
                        transfer: input.transfer, profile: profile, origin: origin,
                        sourceTileCapacity: limits.sourceTileCapacity,
                        measureBlockTimes: mode != .disabled, clock: clock))
            }
            transfer = input.transfer
            maximumResults = limits.maximumResultEvents
            try Task.checkCancellation()
            return CaptureLifecycleConfiguration(
                capture: observation, audioSession: input.audioSession, analysis: profile,
                analysisIdentity: identity, initialAnalysisContinuityEpoch: initialAnalysisEpoch)
        }

        func next() throws -> CaptureLifecycleBatch {
            try Task.checkCancellation()
            guard let schedule, let transfer, !closed else {
                throw AnalysisScheduleError.invalidState
            }
            var events: [PCMTransferScheduleEvent] = []
            events.reserveCapacity(maximumResults)
            var overflow = false
            let start = mode == .disabled ? nil : clock()
            var metadata = DiagnosticMetadata()
            metadata.profileToken = 54
            metadata.frameSequence = turns
            metadata.queueDepth = UInt32(transfer.snapshot().depth ?? 0)
            let report = try diagnostics.withFrame(metadata) {
                do {
                    let report = try schedule.drain { event in
                        if Task.isCancelled {
                            schedule.cancel()
                            diagnostics.event(.cancelled, validity: .cancelled)
                            return
                        }
                        guard events.count < maximumResults else {
                            overflow = true
                            schedule.cancel()
                            diagnostics.event(.drop, validity: .failed)
                            return
                        }
                        switch event {
                        case .gap:
                            diagnostics.event(.overrun, validity: .discontinuity)
                        case .reset: diagnostics.reset()
                        default: break
                        }
                        events.append(event)
                    }
                    if report.dequeuedBlocks > 0 {
                        diagnostics.event(.captureHandoff)
                        diagnostics.event(.dequeue)
                    }
                    return report
                } catch {
                    diagnostics.event(.error, validity: .failed)
                    throw error
                }
            }
            let end = mode == .disabled ? nil : clock()
            turns = captureDeliveryAdd(turns)
            try Task.checkCancellation()
            guard !overflow else {
                throw CaptureLifecycleFailure(
                    stage: .analysis, reason: .resultCapacityExceeded,
                    recovery: .correctConfiguration)
            }
            return CaptureLifecycleBatch(
                events: events, idle: report.deliveredEvents == 0 && !report.reachedEnd,
                ended: report.reachedEnd,
                observation: CaptureWorkerObservation(
                    capture: transfer.snapshot(), deliveredPCMEvents: report.deliveredEvents,
                    dequeuedBlocks: report.dequeuedBlocks,
                    consumedSourceFrames: report.consumedSourceSamples,
                    emittedResults: events.count,
                    workerStartedHostNanoseconds: start, workerFinishedHostNanoseconds: end,
                    firstBlockHostStartNanoseconds: report.firstBlockHostStartNanoseconds,
                    firstBlockDequeuedHostNanoseconds: report.firstBlockDequeuedHostNanoseconds))
        }

        func close() {
            closed = true
            schedule?.cancel()
            schedule = nil
            transfer = nil
        }
    }

#endif
