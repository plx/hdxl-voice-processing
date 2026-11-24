#if os(macOS)
    import Foundation
    import HDXLVoiceProcessing
    import HDXLVoiceProcessingAudio

    struct ReplayTrial: Codable {
        let profile: ReplayProfile
        let profileSHA256: String
        let sampleRate: Int
        let pattern: [Int]
        let load: ReplayLoad
        let mode: String
        let operation: ReplayOperation
        let seconds: Int
        let seed: UInt32
        let captureEpoch: StreamEpoch
        let analysisEpoch: StreamEpoch
        let ingress: IngressReport
        let consumedFrames: Int64
        let drainedBlocks: Int
        let emittedFrames: Int
        let soakOutcomes: [String: [String: [String: Int]]]
        let gapCount: Int
        let resetCount: Int
        let knownMissingFrames: Int64
        let unknownGaps: Int
        let overflowChunks: UInt64
        let droppedFrames: UInt64
        let queueHighWater: Int
        let queueSlots: Int
        let pcmBytes: Int
        let schedulerBytes: Int
        let resident: [MemorySample]
        let processingNS: UInt64
        let finalDrainNS: UInt64
        let finalDeliveryNS: UInt64
        let drains: [DrainRecord]
        let fast: SubscriberReport
        let slow: SubscriberReport
        let paused: SubscriberReport
        let stopReason: String
        let finalizedRegions: [RegionRecord]
        let requirements: [RequirementRecord]
        let science: ScientificReport?
    }

    @MainActor private struct CompletedReplay {
        let profile: ReplayProfile
        let configuration: CaptureLifecycleConfiguration
        let ingress: IngressReport
        let transfer: PCMTransfer
        let observer: ReplayObserver
        let fast: SubscriberReport
        let slow: SubscriberReport
        let paused: SubscriberReport

        func report() throws -> ReplayTrial {
            let options = observer.options
            let snapshot = transfer.snapshot()
            guard let lastDrain = observer.lastDrainNS, let lastDelivery = observer.lastDeliveryNS,
                let completion = observer.completion, completion.failures.isEmpty,
                snapshot.isClosed, !snapshot.producerContractViolated,
                snapshot.invalidChunks == 0, snapshot.oversizedChunks == 0,
                snapshot.admittedCallbacks == UInt64(ingress.offered),
                snapshot.acceptedChunks + snapshot.overflowChunks == UInt64(ingress.offered),
                UInt64(observer.blocks) == snapshot.acceptedChunks,
                observer.consumed == ingress.admittedFrames,
                UInt64(ingress.offeredFrames - ingress.admittedFrames) == snapshot.droppedFrames,
                snapshot.highWaterSlots <= transfer.configuration.slotCount,
                fast.coalesced == 0, fast.rejected == 0, fast.accepted == fast.delivered,
                slow.coalesced > 0, slow.accepted == slow.delivered + slow.coalesced,
                paused.rejected == 1, paused.delivered == UInt64(paused.capacity),
                observer.frameCount > 0, !observer.resident.isEmpty
            else {
                throw ReplayFailure("inconsistent acquisition, delivery, or completion counters")
            }
            if options.load == .burst, snapshot.overflowChunks != 4 {
                throw ReplayFailure("controlled burst must reject exactly four callbacks")
            }
            let science =
                options.operation == .soak
                ? nil
                : try verifyScientificReplay(
                    configuration: configuration, ingress: ingress, frames: observer.received,
                    rate: options.rate, seed: options.seed)
            return try ReplayTrial(
                profile: profile, profileSHA256: configuration.analysisIdentity.sha256,
                sampleRate: options.rate, pattern: options.pattern, load: options.load,
                mode: options.mode.rawValue,
                operation: options.operation, seconds: options.seconds, seed: options.seed,
                captureEpoch: configuration.capture.epoch,
                analysisEpoch: configuration.initialAnalysisContinuityEpoch,
                ingress: ingress, consumedFrames: observer.consumed, drainedBlocks: observer.blocks,
                emittedFrames: observer.frameCount, soakOutcomes: observer.soakOutcomes,
                gapCount: observer.gapCount, resetCount: observer.resetCount,
                knownMissingFrames: observer.missingFrames,
                unknownGaps: observer.unknownGaps, overflowChunks: snapshot.overflowChunks,
                droppedFrames: snapshot.droppedFrames,
                queueHighWater: snapshot.highWaterSlots,
                queueSlots: transfer.configuration.slotCount,
                pcmBytes: transfer.configuration.pcmStorageBytes,
                schedulerBytes: observer.preparedBytes, resident: observer.resident,
                processingNS: observer.drainProcessingNS, finalDrainNS: lastDrain,
                finalDeliveryNS: lastDelivery,
                drains: observer.records, fast: fast, slow: slow, paused: paused,
                stopReason: String(describing: completion.change),
                finalizedRegions: observer.regions,
                requirements: configuration.analysis.requirements().map {
                    RequirementRecord($0, rate: options.rate)
                },
                science: science)
        }
    }

    private struct CancellationRecord: Codable {
        let captureEpoch: StreamEpoch
        let primedChunks: UInt64
        let pendingChunksAtCancel: Int
        let publicationsAtCancel: Int
        let framesAfterCancel: Int
        let clearedOnCompletion: Bool
    }

    @MainActor private final class ReplaySession {
        let options: ReplayOptions
        let driver: ReplayDriver
        private var observer: ReplayObserver?
        private var cancellationDepth: Int?
        private var analyzedDuringCancellation = 0
        private var nextIntent: CaptureLifecycleStartIntent?
        private lazy var lifecycle = CaptureLifecycle(
            driverFactory: { [driver] _ in driver }, diagnostics: options.mode,
            observeDrain: { [weak self] in self?.observer?.drain($0) },
            onEvent: { [weak self] in self?.event($0) })

        init(options: ReplayOptions) {
            self.options = options
            driver = ReplayDriver(options)
        }

        private func event(_ value: CaptureLifecycleEvent) {
            guard driver.primeForCancellation, case .analysis(.frame) = value else { return }
            analyzedDuringCancellation += 1
            if cancellationDepth == nil {
                cancellationDepth = driver.transfer?.snapshot().depth
                lifecycle.cancel()
            }
        }

        func cancelWhileBacklogged() async throws -> CancellationRecord {
            driver.primeForCancellation = true
            defer { driver.primeForCancellation = false }
            observer = nil
            let schedule = try ReplayProfile.cpps.schedule(rate: options.rate)
            let intent = try lifecycle.prepareStart()
            let configuration = try await lifecycle.start(
                intent: intent,
                request: CaptureRequest(
                    channelSelection: .arithmeticMean, processing: .measurement),
                buffering: CaptureBuffering(
                    requestedTapFrames: 1024, maximumFramesPerChunk: 1024, slotCount: 32),
                workerLimits: CaptureLifecycleWorkerLimits(), analysis: { _, _ in schedule })
            let deadline = replayClock() + 30_000_000_000
            while cancellationDepth == nil && lifecycle.state == .running {
                guard replayClock() < deadline else {
                    _ = await lifecycle.finish()
                    throw ReplayFailure("timed out waiting for first frame to cancel")
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            let completion = await lifecycle.finish()
            let final = lifecycle.latestResultSnapshot
            guard let pending = cancellationDepth, pending > 0, analyzedDuringCancellation == 1,
                completion.failures.isEmpty, final.frames.cpps == nil, final.state == .stopped,
                let capture = final.runtime.capture, capture.isClosed, capture.acceptedChunks == 32
            else {
                throw ReplayFailure(
                    "in-flight cancellation leaked frames, lost evidence, or failed to retire the worker"
                )
            }
            return CancellationRecord(
                captureEpoch: configuration.capture.epoch, primedChunks: capture.acceptedChunks,
                pendingChunksAtCancel: pending, publicationsAtCancel: 1, framesAfterCancel: 0,
                clearedOnCompletion: final.frames.cpps == nil)
        }

        func run(profile: ReplayProfile, reconfigure: Bool = false, cancel: Bool = false)
            async throws -> CompletedReplay
        {
            let observer = ReplayObserver(options: options)
            self.observer = observer
            let intent = try nextIntent ?? lifecycle.prepareStart()
            nextIntent = nil
            let fast = try lifecycle.subscribeResults(.failOnOverflow(capacity: 256))
            let slow = try lifecycle.subscribeResults(.newest(capacity: 2))
            let paused = try lifecycle.subscribeResults(.failOnOverflow(capacity: 4))
            let reader = Task { @MainActor in
                for try await item in fast { try observer.receive(item) }
            }
            let delayed = Task {
                for try await _ in slow { try await Task.sleep(for: .milliseconds(40)) }
            }
            do {
                let schedule = try profile.schedule(rate: options.rate)
                let configuration = try await lifecycle.start(
                    intent: intent,
                    request: CaptureRequest(
                        channelSelection: .arithmeticMean, processing: .measurement),
                    buffering: CaptureBuffering(
                        requestedTapFrames: 512, maximumFramesPerChunk: 1024,
                        slotCount: options.slots),
                    workerLimits: CaptureLifecycleWorkerLimits(), analysis: { _, _ in schedule })
                guard let producer = driver.producer, let transfer = driver.transfer else {
                    throw ReplayFailure("lifecycle did not install the replay driver")
                }
                let ingress = try await producer.produce()
                let deadline = replayClock() + 30_000_000_000
                while observer.blocks < transfer.snapshot().acceptedChunks {
                    guard replayClock() < deadline, lifecycle.state == .running else {
                        throw ReplayFailure(
                            "capture failed or timed out before draining admitted input")
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
                if reconfigure {
                    nextIntent = try await lifecycle.prepareReconfiguration()
                } else {
                    if cancel { lifecycle.cancel() }
                    _ = await lifecycle.finish()
                }
                try await reader.value
                try await delayed.value
                do {
                    for try await _ in paused {}
                    throw ReplayFailure("paused strict subscriber did not signal overflow")
                } catch ResultDeliveryError.overflow {}
                guard lifecycle.activeResultSubscriberCount == 0 else {
                    throw ReplayFailure("subscription survived stop")
                }
                return CompletedReplay(
                    profile: profile, configuration: configuration, ingress: ingress,
                    transfer: transfer, observer: observer,
                    fast: SubscriberReport(fast.statistics),
                    slow: SubscriberReport(slow.statistics),
                    paused: SubscriberReport(paused.statistics))
            } catch {
                _ = await lifecycle.finish()
                reader.cancel()
                delayed.cancel()
                throw error
            }
        }
    }

    private struct ReplayDocument: Encodable {
        let processID = ProcessInfo.processInfo.processIdentifier
        let schemaVersion = 1
        let trials: [ReplayTrial]
        let cancellation: CancellationRecord?
    }

    @MainActor func runReplay(_ options: ReplayOptions) async throws {
        let session = ReplaySession(options: options)
        let completed: [CompletedReplay]
        var cancellation: CancellationRecord?
        switch options.operation {
        case .concurrent:
            let second = ReplaySession(options: options)
            async let left = session.run(profile: options.profile)
            async let right = second.run(profile: options.profile)
            completed = try await [left, right]
            guard
                completed[0].configuration.capture.epoch.streamID
                    != completed[1].configuration.capture.epoch.streamID,
                let latestStart = completed.compactMap({ $0.ingress.firstOfferNS }).max(),
                let earliestEnd = completed.compactMap({ $0.observer.lastDrainNS }).min(),
                latestStart < earliestEnd
            else { throw ReplayFailure("simultaneous runs must overlap on independent streams") }
        case .restart:
            let first = try await session.run(profile: options.profile, reconfigure: true)
            let second = try await session.run(
                profile: options.profile == .cpps ? .core : .cpps, cancel: true)
            let interrupted = try await session.cancelWhileBacklogged()
            cancellation = interrupted
            let third = try await session.run(profile: options.profile)
            completed = [first, second, third]
            guard
                try first.configuration.capture.epoch.successor()
                    == second.configuration.capture.epoch,
                try second.configuration.capture.epoch.successor() == interrupted.captureEpoch,
                try interrupted.captureEpoch.successor() == third.configuration.capture.epoch,
                Set(completed.map { $0.configuration.initialAnalysisContinuityEpoch.streamID })
                    .count == 3
            else {
                throw ReplayFailure(
                    "restart reused an analysis clock or lost the acquisition sequence")
            }
        case .single, .soak:
            completed = [try await session.run(profile: options.profile)]
        }
        // Independent numerical replay and artifact encoding happen after every timed operation.
        let report = try ReplayDocument(
            trials: completed.map { try $0.report() }, cancellation: cancellation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to: options.output, options: .atomic)
    }
#endif
