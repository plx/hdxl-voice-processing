#if os(macOS)
    import Darwin
    import Foundation
    import HDXLVoiceProcessing
    import HDXLVoiceProcessingAudio

    struct DrainRecord: Codable {
        let sourceHostNS: UInt64?
        let dequeuedNS: UInt64?
        let startedNS: UInt64
        let finishedNS: UInt64
        let afterPublicationNS: UInt64
        let frames: Int64
        let emittedEvents: Int
        let depthAfter: Int?
    }

    struct MemorySample: Codable {
        let consumedFrames: Int64
        let residentBytes: UInt64
    }

    struct SubscriberReport: Codable {
        let capacity: Int
        let highWater: Int
        let accepted: UInt64
        let delivered: UInt64
        let coalesced: UInt64
        let rejected: UInt64

        init(_ stats: ResultDeliveryStatistics) {
            capacity = stats.capacity
            highWater = stats.highWater
            accepted = stats.accepted
            delivered = stats.delivered
            coalesced = stats.coalesced
            rejected = stats.rejected
        }
    }

    struct ReceivedFrame {
        let frame: ScheduledFrame
        let publication: UInt64
        let publishedNS: UInt64
        let observedNS: UInt64
    }

    struct RegionRecord: Codable {
        let sourceStart: Int64
        let frames: Int64
        let emittedFrames: UInt64
        let cppsFrames: Int?
        let cppsAvailable: Int?
    }

    @MainActor final class ReplayObserver {
        let options: ReplayOptions
        private(set) var records: [DrainRecord] = []
        private(set) var received: [ReceivedFrame] = []
        private(set) var regions: [RegionRecord] = []
        private(set) var resident: [MemorySample] = []
        private(set) var soakOutcomes: [String: [String: [String: Int]]] = [:]
        private(set) var frameCount = 0
        private(set) var fastLastPublication: UInt64?
        private(set) var lastDeliveryNS: UInt64?
        private(set) var consumed: Int64 = 0
        private(set) var blocks = 0
        private(set) var nativeTimedDrains: UInt64 = 0
        private(set) var drainProcessingNS: UInt64 = 0
        private(set) var preparedBytes = 0
        private(set) var resetCount = 0
        private(set) var gapCount = 0
        private(set) var missingFrames: Int64 = 0
        private(set) var unknownGaps = 0
        private(set) var completion: CaptureLifecycleCompletion?
        private(set) var lastDrainNS: UInt64?
        private var nextMemorySample: Int64 = 0

        init(options: ReplayOptions) { self.options = options }

        func drain(_ observation: CaptureWorkerObservation) {
            let now = replayClock()
            blocks += observation.dequeuedBlocks
            consumed += observation.consumedSourceFrames
            preparedBytes = observation.preparedBufferBytes
            lastDrainNS = now
            if options.operation != .overhead, let start = observation.workerStartedHostNanoseconds,
                let end = observation.workerFinishedHostNanoseconds
            {
                drainProcessingNS += end - start
                if options.operation != .soak {
                    records.append(
                        DrainRecord(
                            sourceHostNS: observation.firstBlockHostStartNanoseconds,
                            dequeuedNS: observation.firstBlockDequeuedHostNanoseconds,
                            startedNS: start, finishedNS: end, afterPublicationNS: now,
                            frames: observation.consumedSourceFrames,
                            emittedEvents: observation.emittedResults,
                            depthAfter: observation.capture.depth))
                }
            }
            if consumed >= nextMemorySample {
                var info = mach_task_basic_info()
                var count = mach_msg_type_number_t(
                    MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
                let status = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                    }
                }
                if status == KERN_SUCCESS {
                    resident.append(
                        MemorySample(consumedFrames: consumed, residentBytes: info.resident_size))
                }
                nextMemorySample = consumed + Int64(max(1024, options.rate * options.seconds / 12))
            }
        }

        func receive(_ delivery: ResultDelivery<CaptureResultSnapshot>) throws {
            if let previous = fastLastPublication, delivery.publication != previous + 1 {
                throw ReplayFailure("strict fast consumer skipped a publication")
            }
            fastLastPublication = delivery.publication
            lastDeliveryNS = delivery.observedAtHostNanoseconds
            let snapshot = delivery.value
            switch snapshot.event {
            case .analysis(.frame(let result)):
                frameCount += 1
                if options.operation == .soak {
                    let frame = result.frame
                    for metric in metrics(for: frame.algorithm) {
                        let outcome = try frame.measurementResult(metric).outcome
                        let status: String
                        switch outcome {
                        case .available: status = "available"
                        case .unavailable(let reason): status = reason.rawValue
                        }
                        soakOutcomes[frame.algorithm.rawValue, default: [:]][
                            metric.rawValue, default: [:]][status, default: 0] += 1
                    }
                } else {
                    received.append(
                        ReceivedFrame(
                            frame: result.frame, publication: delivery.publication,
                            publishedNS: delivery.publishedAtHostNanoseconds,
                            observedNS: delivery.observedAtHostNanoseconds))
                }
            case .analysis(.gap(let gap)):
                gapCount += 1
                if let extent = gap.missingSource {
                    missingFrames += extent.frameCount
                } else {
                    unknownGaps += 1
                }
                try requireCleared(snapshot)
            case .analysis(.reset):
                resetCount += 1
                try requireCleared(snapshot)
            case .analysis(.regionCompleted(let end)):
                if options.operation != .soak {
                    regions.append(
                        RegionRecord(
                            sourceStart: end.observedSource.startSample,
                            frames: end.observedSource.sampleCount,
                            emittedFrames: end.emittedFrames, cppsFrames: end.cpps?.frameCount,
                            cppsAvailable: end.cpps?.availableFrameCount))
                }
            case .configured, .discontinuity:
                try requireCleared(snapshot)
            case .completed(let value):
                completion = value
                nativeTimedDrains = snapshot.runtime.processing.samples
                try requireCleared(snapshot)
            default: break
            }
        }

        private func requireCleared(_ snapshot: CaptureResultSnapshot) throws {
            let frames = snapshot.frames
            guard frames.levels == nil, frames.pitch == nil, frames.cpps == nil, frames.hnr == nil,
                frames.swipePrime == nil
            else { throw ReplayFailure("old result survived a boundary") }
        }
    }
#endif
