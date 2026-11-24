#if os(macOS)
    import AVFAudio
    import Darwin
    import Foundation
    import HDXLVoiceProcessing
    import HDXLVoiceProcessingAudio

    struct CallbackRecord: Codable {
        let sourceStart: Int
        let frames: Int
        let sourceHostNS: UInt64
        let enteredNS: UInt64
        let returnedNS: UInt64
        let admitted: Bool
    }

    struct IngressReport: Codable {
        var offered = 0
        var offeredFrames = 0
        var admittedFrames = 0
        var explicitGapFrames = 0
        var retainedCallbacks: [CallbackRecord] = []
        var admittedRegionCount = 0
        var lastAdmittedRegion: Range<Int>?
        var admittedRegions: [Range<Int>] = []
        var firstOfferNS: UInt64?
        var lastReturnNS: UInt64?
    }

    /// A sole synthetic device producer owns the SDK buffer. Preparation, timestamps
    /// and measurement bookkeeping surround the call to the production tap.
    actor ReplayIngress {
        let tap: PreparedCaptureTap
        private let options: ReplayOptions
        private let signal: [Float]
        private let format: AVAudioFormat
        private let timebase: mach_timebase_info_data_t
        private var anchor: UInt64?
        private var source = 0
        private var report = IngressReport()

        init(options: ReplayOptions, tap: PreparedCaptureTap) throws {
            self.tap = tap
            self.options = options
            signal = replaySignal(rate: options.rate, seed: options.seed)
            guard
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Double(options.rate),
                    channels: 1, interleaved: true)
            else { throw ReplayFailure("unable to prepare replay buffer") }
            self.format = format
            var info = mach_timebase_info_data_t()
            guard mach_timebase_info(&info) == KERN_SUCCESS else {
                throw ReplayFailure("invalid host clock")
            }
            timebase = info
        }

        private func offset(_ index: Int) -> UInt64 {
            UInt64((Double(index) * 1e9 / Double(options.rate)).rounded(.toNearestOrEven))
        }

        private func offer(frames: Int) throws {
            let start = source
            let buffer = try AVReadOnlyAudioPCMBuffer(format: format, frameCapacity: frames) {
                list in
                let memory = list.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
                for index in 0..<frames { memory[index] = signal[(start + index) % signal.count] }
                list.pointee.mBuffers.mDataByteSize = UInt32(frames * MemoryLayout<Float>.stride)
            }
            let nominal = anchor! + offset(start)
            let ticks = UInt64(timebase.numer).dividingFullWidth(
                nominal.multipliedFullWidth(by: UInt64(timebase.denom))
            ).quotient
            let host = UInt64(timebase.denom).dividingFullWidth(
                ticks.multipliedFullWidth(by: UInt64(timebase.numer))
            ).quotient
            let time = AVAudioTime(
                hostTime: ticks, sampleTime: Int64(start), atRate: Double(options.rate))
            let previous = tap.transfer.snapshot().acceptedChunks
            let entered = replayClock()
            tap.accept(buffer, at: time)
            let returned = replayClock()
            guard tap.failure == nil else {
                throw ReplayFailure("tap rejected native buffer format or clock")
            }
            let admitted = tap.transfer.snapshot().acceptedChunks > previous
            if report.firstOfferNS == nil { report.firstOfferNS = entered }
            report.lastReturnNS = returned
            report.offered += 1
            report.offeredFrames += frames
            if admitted {
                report.admittedFrames += frames
                let adjacent = report.lastAdmittedRegion?.upperBound == start
                let regionStart = adjacent ? report.lastAdmittedRegion!.lowerBound : start
                let region = regionStart..<(start + frames)
                if !adjacent { report.admittedRegionCount += 1 }
                report.lastAdmittedRegion = region
                if options.operation != .soak {
                    if adjacent {
                        report.admittedRegions[report.admittedRegions.count - 1] = region
                    } else {
                        report.admittedRegions.append(region)
                    }
                }
            }
            if options.operation != .soak {
                report.retainedCallbacks.append(
                    CallbackRecord(
                        sourceStart: start, frames: frames, sourceHostNS: host,
                        enteredNS: entered, returnedNS: returned, admitted: admitted))
            }
            source += frames
        }

        /// Fill and overrun the real queue before the lifecycle can prepare its worker.
        /// The rest of this run is backpressured and recovers through the normal pump.
        func startupBurst(forCancellation: Bool) throws {
            if forCancellation {
                anchor = replayClock()
                for _ in 0..<tap.transfer.configuration.slotCount { try offer(frames: 1024) }
                return
            }
            guard options.load == .burst else { return }
            anchor = replayClock()
            for _ in 0..<(tap.transfer.configuration.slotCount + 4) {
                try offer(frames: options.pattern[report.offered % options.pattern.count])
            }
        }

        func produce() async throws -> IngressReport {
            if anchor == nil { anchor = replayClock() }
            let target = options.seconds * options.rate
            while report.offeredFrames < target {
                try Task.checkCancellation()
                if report.explicitGapFrames == 0, report.offeredFrames >= target / 2 {
                    report.explicitGapFrames = options.rate / 50
                    source += report.explicitGapFrames
                }
                let size = min(
                    options.pattern[report.offered % options.pattern.count],
                    target - report.offeredFrames)
                if options.load == .paced {
                    let due = anchor! + offset(source + size)
                    let now = replayClock()
                    if now < due { try await Task.sleep(nanoseconds: due - now) }
                } else {
                    // Producer-side flow control applies only to the throughput/recovery phase.
                    let timeout = replayClock() + 30_000_000_000
                    while (tap.transfer.snapshot().depth ?? tap.transfer.configuration.slotCount)
                        >= tap.transfer.configuration.slotCount
                    {
                        guard replayClock() < timeout, !tap.transfer.snapshot().isClosed else {
                            throw ReplayFailure("worker stopped making queue space")
                        }
                        try await Task.sleep(for: .microseconds(100))
                    }
                }
                try offer(frames: size)
            }
            return report
        }
    }

    @MainActor final class ReplayDriver: CaptureLifecycleDriver {
        let options: ReplayOptions
        var primeForCancellation = false
        private(set) var producer: ReplayIngress?
        private(set) var transfer: PCMTransfer?

        init(_ options: ReplayOptions) { self.options = options }

        func start(
            request: CaptureRequest, buffering: CaptureBuffering, epoch: StreamEpoch,
            lease: IOSCaptureHostLease?
        ) async throws -> CaptureLifecycleInput {
            let format = try options.profile.schedule(rate: options.rate).inputFormat
            let transfer = try PCMTransfer(
                configuration: PCMTransferConfiguration(
                    format: format, epoch: epoch,
                    maximumFramesPerChunk: buffering.maximumFramesPerChunk,
                    slotCount: buffering.slotCount))
            let ingress = try ReplayIngress(
                options: options, tap: PreparedCaptureTap(transfer: transfer))
            self.transfer = transfer
            producer = ingress
            try await ingress.startupBurst(forCancellation: primeForCancellation)
            return try CaptureLifecycleInput(
                observation: CaptureConfigurationObservation(
                    epoch: epoch, request: request, effectiveFormat: format,
                    input: CaptureInputIdentity(),
                    processing: CaptureProcessingObservation()), audioSession: nil,
                transfer: transfer)
        }
        func stop() { transfer?.close() }
        func finish() async throws {}
    }
#endif
