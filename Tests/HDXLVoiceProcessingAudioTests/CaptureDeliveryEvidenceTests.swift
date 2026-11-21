#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import CryptoKit
    import Dispatch
    import Foundation
    import HDXLVoiceProcessing
    import Testing
    @testable import HDXLVoiceProcessingAudio

    private struct DeliveryFingerprint: Codable {
        let algorithm: String
        let profileSHA256: String
        let sourceStart: Int64
        let sourceCount: Int64
        let continuitySequence: UInt64
        let selectedSamples: Int64
        let eligibleSamples: Int64
        let effectiveDelaySeconds: Double
        let outcomes: [MeasurementOutcome]

        init(_ frame: ScheduledFrame) throws {
            algorithm = frame.algorithm.rawValue
            profileSHA256 = frame.schedule.sha256
            sourceStart = frame.timing.source.startSample
            sourceCount = frame.timing.source.sampleCount
            continuitySequence = frame.origin.continuityEpoch.sequence
            selectedSamples = frame.coverage.selected
            eligibleSamples = frame.coverage.eligible
            effectiveDelaySeconds = frame.timing.effectiveDelaySeconds
            let metrics: [ScheduledMetric]
            switch frame.algorithm {
            case .levels:
                metrics = [
                    .meanSquare, .rms, .peakAmplitude, .crestFactor, .levelDBFS, .clippingFraction,
                ]
            case .yin: metrics = [.fundamentalFrequency]
            case .swipePrime: metrics = [.fundamentalFrequency]
            case .cpps: metrics = [.cpp, .cpps]
            case .hnr: metrics = [.harmonicToNoiseRatio]
            }
            outcomes = try metrics.map { try frame.measurementResult($0).outcome }
        }
    }

    private struct DeliveryDrainTrial: Codable {
        let pcmDepthBefore: Int
        let pcmDepthAfter: Int
        let dequeuedBlocks: Int
        let emittedResults: Int
        let consumedSourceFrames: Int64
        let cumulativeDroppedFrames: UInt64
        let slowBufferedResults: Int
        let workerCallNanoseconds: UInt64
        let processingNanoseconds: UInt64?
        let captureBlockStartToWorkerNanoseconds: UInt64?
        let workerToPublicationNanoseconds: UInt64?
        let blockStampToFirstResultNanoseconds: UInt64?
    }

    private struct DeliveryEvidenceTrial: Codable {
        let profile: String
        let mode: String
        let pattern: String
        let trial: Int
        let profileSHA256: String
        let scientificSHA256: String
        let sampleRate: Int
        let chunkFrames: Int
        let slotCount: Int
        let bursts: Int
        let offeredChunks: Int
        let acceptedChunks: UInt64
        let overflowChunks: UInt64
        let droppedPCMFrames: UInt64
        let pcmHighWaterSlots: Int
        let emittedFrames: Int
        let availableCPPSEstimates: Int
        let gapEvents: UInt64
        let knownMissingFrames: UInt64
        let unknownExtentGaps: UInt64
        let resets: UInt64
        let publications: UInt64
        let fastDelivered: UInt64
        let fastCoalesced: UInt64
        let slowDelivered: UInt64
        let slowCoalesced: UInt64
        let slowHighWater: Int
        let strictDelivered: UInt64
        let strictRejected: UInt64
        let strictHighWater: Int
        let strictErrors: Int
        let completions: Int
        let activeSubscribersAfterFinish: Int
        let processingSamples: UInt64
        let captureLatencySamples: UInt64
        let publicationLatencySamples: UInt64
        let workerCallTotalNanoseconds: UInt64
        let publicationTotalNanoseconds: UInt64
        let publicationNanoseconds: [UInt64]
        let fastSubscriberLagNanoseconds: [UInt64]
        let slowSubscriberLagNanoseconds: [UInt64]
        let drains: [DeliveryDrainTrial]
    }

    private func deliveryEvidenceProfile(full: Bool) throws -> AnalysisScheduleProfile {
        try AnalysisScheduleProfile(
            inputFormat: PCMFormat(sampleRate: 44100, channelCount: 1, encoding: .float32),
            channels: .arithmeticMean,
            levels: LevelConfiguration(
                sampleRate: 44100, inputPrecision: .float32, windowLength: 800, hopLength: 441,
                accumulation: .compensatedSliding, weighting: .none),
            pitch: full
                ? YINProfile(
                    estimator: YINConfiguration(
                        sampleRate: 44100, inputPrecision: .float32, pitchFloorHz: 50,
                        pitchCeilingHz: 700, hopLength: 441)) : nil,
            cpps: full
                ? CPPSProfile(
                    cepstrogram: CepstrogramConfiguration(
                        sourceSampleRate: 44100, inputPrecision: .float32, hopSeconds: 0.01,
                        declaredInputBandwidthHz: 22050,
                        conditioningMethod: .streamingPreview(lobes: 8, cutoffFraction: 0.9)),
                    settings: CPPSConfiguration(
                        timeWindowSeconds: 0.02,
                        prominence: CPPConfiguration(fitMethod: .leastSquares))) : nil)
    }

    private func deliveryChecksum(_ values: [DeliveryFingerprint]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(values)).map { String(format: "%02x", $0) }
            .joined()
    }

    @MainActor private func deliveryEvidenceTrial(
        full: Bool, mode: RuntimeDiagnosticMode, overload: Bool, trial: Int
    ) async throws -> DeliveryEvidenceTrial {
        let profile = try deliveryEvidenceProfile(full: full)
        let epoch = StreamEpoch(streamID: UUID())
        let transfer = PCMTransfer(
            configuration: try PCMTransferConfiguration(
                format: profile.inputFormat, epoch: epoch, maximumFramesPerChunk: 2048,
                slotCount: 4))
        let observation = try CaptureConfigurationObservation(
            epoch: epoch,
            request: CaptureRequest(channelSelection: .arithmeticMean, processing: .measurement),
            effectiveFormat: profile.inputFormat, input: CaptureInputIdentity(),
            processing: CaptureProcessingObservation())
        let worker = CaptureAnalysisWorker(diagnostics: mode)
        let configuration = try await worker.prepare(
            input: CaptureLifecycleInput(
                observation: observation, audioSession: nil, transfer: transfer),
            analysis: { _, _ in profile },
            limits: CaptureLifecycleWorkerLimits(sourceTileCapacity: 128))
        let delivery = CaptureResultDelivery(mode: mode)
        var publicationDurations: [UInt64] = []
        var fastLags: [UInt64] = []
        var slowLags: [UInt64] = []
        var expected: [DeliveryFingerprint] = []
        var received: [DeliveryFingerprint] = []
        var availableCPPS = 0
        var completions = 0
        var raw: [DeliveryDrainTrial] = []
        var stamps: [UInt64] = []
        var consumedBlocks = 0
        let initial = DispatchTime.now().uptimeNanoseconds
        delivery.accept(.configured(configuration))
        publicationDurations.append(DispatchTime.now().uptimeNanoseconds - initial)
        let fast = try delivery.subscribe(.failOnOverflow(capacity: 1))
        let slow = try delivery.subscribe(.newest(capacity: 1))
        let strict = try delivery.subscribe(.failOnOverflow(capacity: 8))
        var fastIterator = fast.makeAsyncIterator()
        var slowIterator = slow.makeAsyncIterator()
        try #require(fast.statistics.buffered == 1)
        let replay = try #require(await fastIterator.next())
        fastLags.append(try #require(replay.statistics.lastSubscriberLagNanoseconds))

        func publish(_ event: CaptureLifecycleEvent) async throws -> ResultDelivery<
            CaptureResultSnapshot
        > {
            let start = DispatchTime.now().uptimeNanoseconds
            delivery.accept(event)
            publicationDurations.append(DispatchTime.now().uptimeNanoseconds - start)
            try #require(fast.statistics.buffered == 1)
            let receipt = try #require(await fastIterator.next())
            fastLags.append(try #require(receipt.statistics.lastSubscriberLagNanoseconds))
            switch receipt.value.event {
            case .analysis(.frame(let frame)): received.append(try DeliveryFingerprint(frame.frame))
            case .completed: completions += 1
            default: break
            }
            return receipt
        }

        _ = try await publish(.state(.running, epoch: epoch))

        func drain() async throws -> CaptureLifecycleBatch {
            let depthBefore = try #require(transfer.snapshot().depth)
            let start = DispatchTime.now().uptimeNanoseconds
            let batch = try await worker.next()
            let callDuration = DispatchTime.now().uptimeNanoseconds - start
            let report = try #require(batch.observation)
            let publicationTime = batch.events.isEmpty ? nil : DispatchTime.now().uptimeNanoseconds
            delivery.observe(report, publicationTime: mode == .disabled ? nil : publicationTime)
            let stamp: UInt64?
            if report.dequeuedBlocks == 1 {
                try #require(consumedBlocks < stamps.count)
                stamp = stamps[consumedBlocks]
                consumedBlocks += 1
                if mode != .disabled { #expect(report.firstBlockHostStartNanoseconds == stamp) }
            } else {
                #expect(report.dequeuedBlocks == 0)
                stamp = nil
            }
            var firstResultObserved: UInt64?
            for event in batch.events {
                if case .frame(let frame) = event {
                    expected.append(try DeliveryFingerprint(frame.frame))
                    if case .cpps(let value) = frame.frame.value, value.observation != nil {
                        availableCPPS += 1
                    }
                }
                let receipt = try await publish(.analysis(event))
                if case .frame = event, firstResultObserved == nil {
                    firstResultObserved = receipt.observedAtHostNanoseconds
                }
            }
            if report.deliveredPCMEvents > 0 || !batch.events.isEmpty {
                raw.append(
                    DeliveryDrainTrial(
                        pcmDepthBefore: depthBefore,
                        pcmDepthAfter: try #require(transfer.snapshot().depth),
                        dequeuedBlocks: report.dequeuedBlocks, emittedResults: batch.events.count,
                        consumedSourceFrames: report.consumedSourceFrames,
                        cumulativeDroppedFrames: report.capture.droppedFrames,
                        slowBufferedResults: slow.statistics.buffered,
                        workerCallNanoseconds: callDuration,
                        processingNanoseconds: report.processingNanoseconds,
                        captureBlockStartToWorkerNanoseconds: report
                            .captureBlockStartToWorkerNanoseconds,
                        workerToPublicationNanoseconds: mode == .disabled || batch.events.isEmpty
                            ? nil
                            : CaptureWorkerObservation.difference(
                                publicationTime, report.workerFinishedHostNanoseconds),
                        blockStampToFirstResultNanoseconds: CaptureWorkerObservation.difference(
                            firstResultObserved, stamp)))
            }
            return batch
        }

        let chunksPerBurst = overload ? 8 : 4
        for burst in 0..<16 {
            for chunk in 0..<chunksPerBurst {
                let startSample = (burst * chunksPerBurst + chunk) * 2048
                let samples = (startSample..<(startSample + 2048)).map {
                    Float(0.25 * sin(2 * .pi * 125 * Double($0) / 44100))
                }
                let stamp = DispatchTime.now().uptimeNanoseconds
                let offered = samples.withUnsafeBytes {
                    transfer.offerInterleaved(
                        $0, frameCount: 2048, sourceStartSample: Int64(startSample),
                        configurationToken: transfer.configuration.captureToken,
                        hostStartNanoseconds: stamp)
                }
                switch offered {
                case .accepted: stamps.append(stamp)
                case .droppedCapacity: #expect(overload && chunk >= 4)
                default: Issue.record("Unexpected controlled producer outcome")
                }
            }
            var reachedIdle = false
            for _ in 0..<8 {
                let batch = try await drain()
                if batch.idle {
                    reachedIdle = true
                    break
                }
                #expect(!batch.ended)
            }
            try #require(reachedIdle)
            if burst % 4 == 3 {
                try #require(slow.statistics.buffered == 1)
                let receipt = try #require(await slowIterator.next())
                slowLags.append(try #require(receipt.statistics.lastSubscriberLagNanoseconds))
            }
        }
        transfer.close()
        var reachedEnd = false
        for _ in 0..<3 {
            if (try await drain()).ended {
                reachedEnd = true
                break
            }
        }
        try #require(reachedEnd)
        await worker.close()
        delivery.observeFinalCapture(transfer.snapshot())
        _ = try await publish(.state(.stopped, epoch: epoch))
        _ = try await publish(
            .completed(
                CaptureLifecycleCompletion(
                    epoch: epoch, change: .explicitStop, failures: [], audioSessionDisposition: nil,
                    recoveryIntent: nil)))
        try #require(slow.statistics.buffered == 1)
        try #require(
            slow.termination != nil && fast.termination != nil && strict.termination != nil)
        let slowTerminal = try #require(await slowIterator.next())
        slowLags.append(try #require(slowTerminal.statistics.lastSubscriberLagNanoseconds))
        #expect(slowTerminal.value.completion != nil)
        #expect(slowTerminal.value.hasReportedAcquisitionLoss == overload)
        #expect(try await slowIterator.next() == nil)
        #expect(try await fastIterator.next() == nil)
        var strictIterator = strict.makeAsyncIterator()
        var strictErrors = 0
        do {
            while try await strictIterator.next() != nil {}
            Issue.record("Stalled strict subscriber did not report overflow")
        } catch ResultDeliveryError.overflow(let publication) {
            #expect(publication == 8)
            strictErrors += 1
        }
        #expect(try await strictIterator.next() == nil)
        let checksum = try deliveryChecksum(expected)
        #expect(try deliveryChecksum(received) == checksum)
        #expect(consumedBlocks == 64 && expected.count > 64)
        if full { #expect(availableCPPS > 0) }
        let capture = transfer.snapshot()
        let snapshot = delivery.snapshot
        let fastStats = fast.statistics
        let slowStats = slow.statistics
        let strictStats = strict.statistics
        #expect(capture.acceptedChunks == 64 && capture.highWaterSlots == 4)
        #expect(capture.overflowChunks == (overload ? 64 : 0))
        #expect(snapshot.loss.knownMissingFrames == capture.droppedFrames)
        #expect(snapshot.loss.gapEvents == (overload ? 16 : 0))
        #expect(snapshot.resetCount == (overload ? 15 : 0))
        #expect(
            slowStats.delivered == 5
                && slowStats.coalesced + slowStats.delivered == slowStats.accepted)
        #expect(fastStats.coalesced == 0 && fastStats.rejected == 0)
        #expect(strictStats.delivered == 8 && strictStats.rejected == 1 && strictErrors == 1)
        #expect(delivery.activeSubscriberCount == 0 && completions == 1)
        return DeliveryEvidenceTrial(
            profile: full ? "full" : "levels", mode: mode.rawValue,
            pattern: overload ? "pcm-overload" : "display-coalescing", trial: trial,
            profileSHA256: configuration.analysisIdentity.sha256, scientificSHA256: checksum,
            sampleRate: 44100, chunkFrames: 2048, slotCount: 4, bursts: 16,
            offeredChunks: 16 * chunksPerBurst, acceptedChunks: capture.acceptedChunks,
            overflowChunks: capture.overflowChunks, droppedPCMFrames: capture.droppedFrames,
            pcmHighWaterSlots: capture.highWaterSlots, emittedFrames: expected.count,
            availableCPPSEstimates: availableCPPS, gapEvents: snapshot.loss.gapEvents,
            knownMissingFrames: snapshot.loss.knownMissingFrames,
            unknownExtentGaps: snapshot.loss.unknownExtentGaps, resets: snapshot.resetCount,
            publications: fastStats.accepted, fastDelivered: fastStats.delivered,
            fastCoalesced: fastStats.coalesced, slowDelivered: slowStats.delivered,
            slowCoalesced: slowStats.coalesced, slowHighWater: slowStats.highWater,
            strictDelivered: strictStats.delivered, strictRejected: strictStats.rejected,
            strictHighWater: strictStats.highWater, strictErrors: strictErrors,
            completions: completions, activeSubscribersAfterFinish: delivery.activeSubscriberCount,
            processingSamples: snapshot.runtime.processing.samples,
            captureLatencySamples: snapshot.runtime.captureBlockStartToWorker.samples,
            publicationLatencySamples: snapshot.runtime.workerToPublication.samples,
            workerCallTotalNanoseconds: raw.reduce(0) { $0 + $1.workerCallNanoseconds },
            publicationTotalNanoseconds: publicationDurations.reduce(0, +),
            publicationNanoseconds: publicationDurations,
            fastSubscriberLagNanoseconds: fastLags, slowSubscriberLagNanoseconds: slowLags,
            drains: raw)
    }

    @MainActor @Test func captureDeliveryEvidenceTrials() async throws {
        var trials: [DeliveryEvidenceTrial] = []
        var checksums: [String: String] = [:]
        for trial in 0..<3 {
            for full in [false, true] {
                for overload in [false, true] {
                    let modes = RuntimeDiagnosticMode.allCases
                    for index in modes.indices {
                        let mode = modes[(index + trial) % modes.count]
                        let row = try await deliveryEvidenceTrial(
                            full: full, mode: mode, overload: overload, trial: trial)
                        let key = row.profile + "/" + row.pattern
                        if let prior = checksums[key] { #expect(prior == row.scientificSHA256) }
                        checksums[key] = row.scientificSHA256
                        trials.append(row)
                    }
                }
            }
        }
        #expect(trials.count == 36)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(
            "CAPTURE_DELIVERY_TRIALS " + String(decoding: try encoder.encode(trials), as: UTF8.self)
        )
    }
#endif
