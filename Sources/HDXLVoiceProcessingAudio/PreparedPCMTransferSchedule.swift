import Dispatch
import HDXLVoiceProcessing

public struct PCMTransferScheduledFrame: Sendable, Hashable {
    public let frame: ScheduledFrame
    /// Source channel identifiers in native storage order; selection indices in
    /// the schedule profile refer to positions in this map.
    public let channelMap: [Int]
}

public enum PCMTransferScheduleEvent: Sendable {
    case frame(PCMTransferScheduledFrame)
    case regionCompleted(AnalysisScheduleCompletion)
    case gap(PCMTransferGap)
    case reset(AnalysisScheduleReset)
}

public struct PCMTransferScheduleDrain: Sendable, Equatable {
    public let deliveredEvents: Int
    public let consumedSourceSamples: Int64
    public let emittedFrames: Int
    public let reachedEnd: Bool
    public let isCancelled: Bool
    public let dequeuedBlocks: Int
    /// Present only when worker diagnostic timing was enabled. The supplied source
    /// anchor and actual dequeue observation are separate; neither is an enqueue time.
    public let firstBlockHostStartNanoseconds: UInt64?
    public let firstBlockDequeuedHostNanoseconds: UInt64?
}

/// Single-owner worker adapter. Drain work is bounded by an explicit event limit
/// and the transport's maximum chunk size. Copies/conversion/analysis happen here,
/// never in capture. The transport remains responsible for producer shutdown.
/// The first block's host anchor (or supplied origin when absent) is projected
/// at nominal sample rate until a gap;
/// subsequent per-block timestamps are not silently treated as drift correction.
public final class PreparedPCMTransferSchedule<Sample: BinaryFloatingPoint & Sendable> {
    public let transfer: PCMTransfer
    public let profile: AnalysisScheduleProfile
    public let initialOrigin: AnalysisScheduleOrigin
    public var isCancelled: Bool { state == .cancelled }
    public var preparedBufferBytes: Int {
        schedule.preparedBufferBytes + scratch.count * MemoryLayout<Sample>.stride
            + planes.count * MemoryLayout<UnsafeBufferPointer<Sample>>.stride
    }

    private enum State { case prepared, finished, cancelled, failed }
    private var state = State.prepared
    private var busy = false
    private let schedule: PreparedAnalysisSchedule<Sample>
    private var scratch: UnsafeMutableBufferPointer<Sample>
    private var planes: UnsafeMutableBufferPointer<UnsafeBufferPointer<Sample>>
    private var anchored = false
    private var regionFinished = false
    private var pendingGap: PCMTransferGap?
    private var callbackError: (any Error)?
    private var consumedInDrain: Int64 = 0
    private var emittedInDrain = 0
    private let measureBlockTimes: Bool
    private let clock: @Sendable () -> UInt64
    private var blocksInDrain = 0
    private var firstBlockHostStart: UInt64?
    private var firstBlockDequeued: UInt64?

    public convenience init(
        transfer: PCMTransfer, profile: AnalysisScheduleProfile,
        origin: AnalysisScheduleOrigin, sourceTileCapacity: Int = 256
    ) throws {
        try self.init(
            transfer: transfer, profile: profile, origin: origin,
            sourceTileCapacity: sourceTileCapacity, measureBlockTimes: false)
    }

    package init(
        transfer: PCMTransfer, profile: AnalysisScheduleProfile,
        origin: AnalysisScheduleOrigin, sourceTileCapacity: Int,
        measureBlockTimes: Bool,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws {
        guard profile.inputFormat == transfer.configuration.format,
            origin.source.epoch == transfer.configuration.epoch
        else { throw AnalysisScheduleError.invalidConfiguration }
        self.transfer = transfer
        self.profile = profile
        self.initialOrigin = origin
        self.measureBlockTimes = measureBlockTimes
        self.clock = clock
        schedule = try PreparedAnalysisSchedule(
            profile: profile, origin: origin,
            mode: .continuous, sourceTileCapacity: sourceTileCapacity)
        scratch = .allocate(
            capacity: Int(transfer.configuration.maximumFramesPerChunk)
                * profile.inputFormat.channelCount)
        scratch.initialize(repeating: 0)
        planes = .allocate(capacity: profile.inputFormat.channelCount)
        planes.initialize(repeating: UnsafeBufferPointer(start: nil, count: 0))
    }

    deinit {
        scratch.deinitialize()
        scratch.deallocate()
        planes.deinitialize()
        planes.deallocate()
    }

    /// Empty queues return immediately. A completed producer is finalized once;
    /// a terminal gap is emitted even when no later PCM arrives.
    @discardableResult public func drain(
        maximumEvents: Int = 16, emit: (PCMTransferScheduleEvent) -> Void
    ) throws -> PCMTransferScheduleDrain {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        guard (1...4096).contains(maximumEvents) else {
            throw AnalysisScheduleError.invalidConfiguration
        }
        guard state == .prepared || state == .finished || state == .cancelled else {
            throw AnalysisScheduleError.invalidState
        }
        if state != .prepared {
            return PCMTransferScheduleDrain(
                deliveredEvents: 0, consumedSourceSamples: 0,
                emittedFrames: 0, reachedEnd: state == .finished, isCancelled: isCancelled,
                dequeuedBlocks: 0, firstBlockHostStartNanoseconds: nil,
                firstBlockDequeuedHostNanoseconds: nil)
        }
        busy = true
        consumedInDrain = 0
        emittedInDrain = 0
        blocksInDrain = 0
        firstBlockHostStart = nil
        firstBlockDequeued = nil
        callbackError = nil
        defer {
            busy = false
            callbackError = nil
            for index in planes.indices {
                planes[index] = UnsafeBufferPointer(start: nil, count: 0)
            }
        }
        var events = 0
        do {
            while events < maximumEvents, state == .prepared {
                let read = transfer.withNext { event in
                    do {
                        switch event {
                        case .gap(let gap): try accept(gap: gap, emit: emit)
                        case .block(let block): try accept(block: block, emit: emit)
                        }
                    } catch { callbackError = error }
                }
                if let callbackError { throw callbackError }
                switch read {
                case .delivered: events += 1
                case .empty:
                    return report(events: events)
                case .finished:
                    try finishRegion(emit: emit)
                    if state == .prepared { state = .finished }
                case .concurrentConsumer: throw AnalysisScheduleError.reentrantCall
                }
            }
            return report(events: events)
        } catch {
            if state != .cancelled { state = .failed }
            throw error
        }
    }

    private func report(events: Int) -> PCMTransferScheduleDrain {
        PCMTransferScheduleDrain(
            deliveredEvents: events, consumedSourceSamples: consumedInDrain,
            emittedFrames: emittedInDrain, reachedEnd: state == .finished, isCancelled: isCancelled,
            dequeuedBlocks: blocksInDrain, firstBlockHostStartNanoseconds: firstBlockHostStart,
            firstBlockDequeuedHostNanoseconds: firstBlockDequeued)
    }

    private func deliver(_ frame: ScheduledFrame, emit: (PCMTransferScheduleEvent) -> Void) {
        guard state == .prepared else { return }
        emittedInDrain += 1
        emit(
            .frame(
                PCMTransferScheduledFrame(
                    frame: frame, channelMap: transfer.configuration.channelMap)))
    }

    private func finishRegion(emit: (PCMTransferScheduleEvent) -> Void) throws {
        guard !regionFinished, state == .prepared else { return }
        // An empty closed source still has typed native insufficient-data reports.
        let result = try schedule.finish { deliver($0, emit: emit) }
        regionFinished = true
        if state == .prepared { emit(.regionCompleted(result)) }
    }

    private func accept(gap: PCMTransferGap, emit: (PCMTransferScheduleEvent) -> Void) throws {
        if anchored { try finishRegion(emit: emit) }
        guard state == .prepared else { return }
        pendingGap = gap
        emit(.gap(gap))
    }

    private func accept(block: PCMTransferBlock, emit: (PCMTransferScheduleEvent) -> Void) throws {
        guard state == .prepared else { return }
        if blocksInDrain == 0, measureBlockTimes {
            firstBlockHostStart = block.hostStartNanoseconds
            firstBlockDequeued = clock()
        }
        blocksInDrain += 1
        let count = Int(block.frameCount)
        let channels = profile.inputFormat.channelCount
        guard block.configurationEpoch == transfer.configuration.epoch,
            count <= Int(transfer.configuration.maximumFramesPerChunk),
            block.bytes.count == count * channels * MemoryLayout<Sample>.stride
        else { throw AnalysisScheduleError.unexpectedInput }
        if !anchored {
            try schedule.setOriginBeforeInput(
                blockOrigin(block, epoch: initialOrigin.continuityEpoch))
            anchored = true
        } else if regionFinished {
            let next = try blockOrigin(block, epoch: schedule.origin.continuityEpoch.successor())
            var missing: SourceInterval?
            if let interval = pendingGap?.missingSource,
                interval.startSample == schedule.origin.source.startSample
                    + schedule.receivedSampleCount,
                interval.endSample == block.sourceStartSample, interval.frameCount > 0
            {
                missing = try SourceInterval(
                    epoch: block.configurationEpoch,
                    startSample: interval.startSample, sampleCount: interval.frameCount,
                    sampleRate: profile.inputFormat.sampleRate)
            }
            let reset = try schedule.reset(
                origin: next, reason: .droppedAudio, missingSource: missing)
            regionFinished = false
            emit(.reset(reset))
            guard state == .prepared else { return }
        }
        pendingGap = nil
        // Raw transfer storage need not have a Swift typed-memory binding. Explicit
        // unaligned loads preserve native Float/Double values without aliasing assumptions.
        for index in 0..<(count * channels) {
            scratch[index] = block.bytes.loadUnaligned(
                fromByteOffset: index * MemoryLayout<Sample>.stride, as: Sample.self)
        }
        let interval = try SourceInterval(
            epoch: block.configurationEpoch,
            startSample: block.sourceStartSample, sampleCount: Int64(count),
            sampleRate: profile.inputFormat.sampleRate)
        let report: AnalysisScheduleProcessReport
        if profile.inputFormat.layout == .interleaved {
            report = try schedule.processInterleaved(
                UnsafeBufferPointer(rebasing: scratch[0..<(count * channels)]), interval: interval
            ) { deliver($0, emit: emit) }
        } else {
            for channel in 0..<channels {
                planes[channel] = UnsafeBufferPointer(
                    rebasing: scratch[(channel * count)..<((channel + 1) * count)])
            }
            report = try schedule.processPlanar(UnsafeBufferPointer(planes), interval: interval) {
                deliver($0, emit: emit)
            }
        }
        consumedInDrain += Int64(report.consumedSourceSamples)
    }

    private func blockOrigin(_ block: PCMTransferBlock, epoch: StreamEpoch) throws
        -> AnalysisScheduleOrigin
    {
        let offset = block.sourceStartSample - initialOrigin.source.startSample
        return try AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: block.configurationEpoch,
                startSample: block.sourceStartSample, sampleCount: 0,
                sampleRate: profile.inputFormat.sampleRate), continuityEpoch: epoch,
            sourceStartSeconds: offset >= 0
                ? initialOrigin.sourceSeconds(atAnalysisSample: offset) : nil,
            hostStartNanoseconds: block.hostStartNanoseconds
                ?? (offset >= 0
                    ? initialOrigin.hostNanoseconds(atAnalysisSample: offset) : nil),
            wallClockStartUnixSeconds: offset >= 0
                ? initialOrigin.wallClockUnixSeconds(atAnalysisSample: offset) : nil)
    }

    /// Supported synchronously from emit. It does not mutate producer lifecycle.
    public func cancel() {
        state = .cancelled
        schedule.cancel()
    }
}
