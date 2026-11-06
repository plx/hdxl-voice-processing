import Dispatch
import Foundation
import HDXLVoiceProcessing
import Synchronization
import Testing

@testable import HDXLVoiceProcessingAudio

// These synthetic callbacks must progress while Swift Testing holds a gate or
// borrow. Global dispatch queues share the cooperative pool and can be starved
// by its blocked test tasks on small runners. Native threads make that progress
// independent of the test executor; no production callback creates a thread.
private func startTransferTestThread(_ body: @escaping @Sendable () -> Void) {
    Thread.detachNewThread(body)
}

private func transferConfiguration(
    encoding: PCMEncoding = .float32, layout: PCMLayout = .interleaved,
    channels: Int = 1, frames: UInt32 = 16, slots: Int = 2,
    epoch: StreamEpoch = .init(streamID: UUID())
) throws -> PCMTransferConfiguration {
    try .init(
        format: .init(
            sampleRate: 48_000, channelCount: channels, encoding: encoding, layout: layout),
        epoch: epoch, maximumFramesPerChunk: frames, slotCount: slots)
}

@discardableResult
private func offer(
    _ queue: PCMTransfer, _ values: [Float], start: Int64,
    frames: UInt32? = nil, epoch: StreamEpoch? = nil
) -> PCMTransferOfferResult {
    values.withUnsafeBytes {
        queue.offerInterleaved(
            $0, frameCount: frames ?? UInt32(values.count), sourceStartSample: start,
            configurationToken: epoch.map { PCMTransferEpochToken(epoch: $0) }
                ?? queue.configuration.captureToken, hostStartNanoseconds: 123_456)
    }
}

@Test func transferConfigurationHasExplicitBoundedBudgets() throws {
    let epoch = StreamEpoch(streamID: UUID())
    let mono = try PCMFormat(sampleRate: 48_000, channelCount: 1)
    for frames: UInt32 in [0, 65_537] {
        #expect(throws: PCMTransferConfiguration.ValidationError.unsupportedCapacity) {
            try PCMTransferConfiguration(format: mono, epoch: epoch, maximumFramesPerChunk: frames)
        }
    }
    for slots in [0, 1, 3, 4097, Int.max] {
        #expect(throws: PCMTransferConfiguration.ValidationError.unsupportedCapacity) {
            try PCMTransferConfiguration(format: mono, epoch: epoch, slotCount: slots)
        }
    }
    #expect(throws: PCMTransferConfiguration.ValidationError.storageBudgetExceeded) {
        try transferConfiguration(channels: 32, frames: 65_536, slots: 4096)
    }
    #expect(throws: PCMTransferConfiguration.ValidationError.unsupportedCapacity) {
        try transferConfiguration(channels: 33)
    }
    let stereo = try PCMFormat(sampleRate: 48_000, channelCount: 2)
    for map in [[0], [0, 0], [-1, 1]] {
        #expect(throws: PCMTransferConfiguration.ValidationError.invalidChannelMap) {
            try PCMTransferConfiguration(format: stereo, epoch: epoch, channelMap: map)
        }
    }
    let config = try PCMTransferConfiguration(format: stereo, epoch: epoch, channelMap: [7, 2])
    #expect(config.channelMap == [7, 2])
    #expect(config.pcmStorageBytes == 2048 * 2 * 4 * 16)
}

@Test func transferCopiesBorrowedInterleavedInputAndTiming() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration(channels: 2))
    var input: [Float] = [1, -1, 2, -2, 3, -3]
    #expect(offer(queue, input, start: 100, frames: 3) == .accepted(sequence: 0))
    input = Array(repeating: 42, count: 6)
    let read = queue.withNext { event in
        guard case .block(let block) = event else {
            Issue.record("Unexpected gap")
            return
        }
        #expect(Array(block.bytes.bindMemory(to: Float.self)) == [1, -1, 2, -2, 3, -3])
        #expect(block.sourceStartSample == 100)
        #expect(block.frameCount == 3)
        #expect(block.hostStartNanoseconds == 123_456)
        #expect(block.configurationEpoch == queue.configuration.epoch)
        #expect(block.sequence == 0)
    }
    #expect(read == .delivered)
    #expect(queue.withNext { _ in Issue.record("Unexpected event") } == .empty)
    #expect(input[0] == 42)
}

@Test func transferPreservesFloat64PlanesAndUnevenChunks() throws {
    let queue = PCMTransfer(
        configuration: try transferConfiguration(
            encoding: .float64, layout: .planar, channels: 2, frames: 8))
    for (sequence, frames) in [3, 1, 8, 2, 5].enumerated() {
        let left = (0..<frames).map { Double($0) + 0.25 }
        let right = left.map { -$0 }
        left.withUnsafeBytes { l in
            right.withUnsafeBytes { r in
                [l, r].withUnsafeBufferPointer { planes in
                    #expect(
                        queue.offerPlanar(
                            planes, frameCount: UInt32(frames),
                            sourceStartSample: Int64(sequence * 100),
                            configurationToken: queue.configuration.captureToken)
                            == .accepted(sequence: UInt64(sequence)))
                }
            }
        }
        if sequence > 0 {
            let gapRead = queue.withNext { event in
                guard case .gap(let gap) = event else {
                    Issue.record("Missing clock gap")
                    return
                }
                #expect(gap.reasons == .sourceDiscontinuity)
            }
            #expect(gapRead == .delivered)
        }
        let blockRead = queue.withNext { event in
            guard case .block(let block) = event else {
                Issue.record("Missing block")
                return
            }
            #expect(Array(block.bytes.bindMemory(to: Double.self)) == left + right)
            #expect(block.frameCount == UInt32(frames))
            #expect(block.hostStartNanoseconds == nil)
        }
        #expect(blockRead == .delivered)
    }
}

@Test func transferDropNewestReportsExactGapBeforeNextBlock() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration())
    #expect(offer(queue, [1, 2], start: 0) == .accepted(sequence: 0))
    #expect(offer(queue, [3], start: 2) == .accepted(sequence: 1))
    #expect(offer(queue, [4, 5, 6], start: 3) == .droppedCapacity)
    #expect(offer(queue, [7, 8], start: 6) == .droppedCapacity)
    var snapshot = queue.snapshot()
    #expect(snapshot.depth == 2 && snapshot.highWaterSlots == 2)
    #expect(snapshot.overflowChunks == 2 && snapshot.droppedFrames == 5)
    var copied: [Float] = []
    for _ in 0..<2 {
        queue.withNext {
            if case .block(let block) = $0 { copied += block.bytes.bindMemory(to: Float.self) }
        }
    }
    #expect(copied == [1, 2, 3])
    #expect(offer(queue, [9], start: 8) == .accepted(sequence: 4))
    queue.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Missing overflow gap")
            return
        }
        #expect(gap.reasons == .capacity)
        #expect(gap.missingSource?.startSample == 3)
        #expect(gap.missingSource?.endSample == 8)
    }
    // Delivering a gap does not reclaim its associated PCM slot.
    #expect(queue.snapshot().depth == 1)
    queue.withNext { event in
        guard case .block(let block) = event else {
            Issue.record("Missing post-gap PCM")
            return
        }
        #expect(block.sourceStartSample == 8 && block.sequence == 4)
        #expect(block.bytes.load(as: Float.self) == 9)
    }
    snapshot = queue.snapshot()
    #expect(snapshot.depth == 0 && snapshot.acceptedChunks == 3)
    #expect(snapshot.admittedCallbacks == 5)
}

@Test func transferOversizedAndMalformedInputNeverReadInvalidBytes() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration(frames: 4))
    let empty = UnsafeRawBufferPointer(start: nil, count: 0)
    #expect(
        queue.offerInterleaved(
            empty, frameCount: UInt32.max, sourceStartSample: 0,
            configurationToken: queue.configuration.captureToken) == .droppedOversized)
    #expect(
        queue.offerInterleaved(
            empty, frameCount: 2, sourceStartSample: Int64(UInt32.max),
            configurationToken: queue.configuration.captureToken) == .invalidInput)
    queue.close()
    queue.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Missing terminal loss")
            return
        }
        #expect(gap.reasons == [.oversized, .invalidInput])
        #expect(gap.missingSource?.frameCount == Int64(UInt32.max) + 2)
    }
    #expect(queue.withNext { _ in Issue.record("Extra terminal gap") } == .finished)
    let snapshot = queue.snapshot()
    #expect(snapshot.oversizedChunks == 1 && snapshot.invalidChunks == 1)
    #expect(snapshot.droppedFrames == UInt64(UInt32.max) + 2)
}

@Test func transferRejectsWrongLayoutsAndPlaneCapacities() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration(layout: .planar, channels: 2))
    #expect(offer(queue, [1, 2], start: 0, frames: 1) == .invalidInput)
    let values: [Float] = [1, 2]
    values.withUnsafeBytes { valid in
        let invalid = UnsafeRawBufferPointer(start: nil, count: 0)
        for descriptors in [[valid], [valid, invalid], [valid, valid, valid]] {
            descriptors.withUnsafeBufferPointer {
                #expect(
                    queue.offerPlanar(
                        $0, frameCount: 2, sourceStartSample: 1,
                        configurationToken: queue.configuration.captureToken) == .invalidInput)
            }
        }
    }
    #expect(queue.snapshot().acceptedChunks == 0)
    #expect(queue.snapshot().invalidChunks == 4)
}

@Test func transferClockDiscontinuitiesNeverClaimContinuity() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration())
    offer(queue, [1, 2], start: 10)
    queue.withNext { _ in }
    offer(queue, [3], start: 15)
    queue.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Missing forward gap")
            return
        }
        #expect(gap.missingSource?.startSample == 12 && gap.missingSource?.endSample == 15)
    }
    queue.withNext { _ in }
    offer(queue, [4], start: 0)
    queue.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Missing backwards boundary")
            return
        }
        #expect(gap.reasons == .sourceDiscontinuity && gap.missingSource == nil)
    }
    queue.withNext { _ in }
    #expect(offer(queue, [5], start: Int64.max) == .invalidInput)
    #expect(offer(queue, [6], start: -1) == .invalidInput)
    queue.close()
    queue.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Missing invalid-clock gap")
            return
        }
        #expect(gap.missingSource == nil)
    }
    #expect(queue.withNext { _ in } == .finished)
}

@Test func transferEpochChangesRequireReplacementAndKeepOldLoss() throws {
    let config = try transferConfiguration()
    let next = try config.epoch.successor()
    let old = PCMTransfer(configuration: config)
    #expect(offer(old, [1], start: 0, epoch: next) == .configurationMismatch)
    old.close()
    old.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Missing epoch rejection")
            return
        }
        #expect(gap.configurationEpoch == config.epoch)
        #expect(gap.reasons == .configurationMismatch && gap.missingSource == nil)
    }
    let replacement = PCMTransfer(configuration: try transferConfiguration(epoch: next))
    #expect(offer(replacement, [2], start: 0) == .accepted(sequence: 0))
    replacement.withNext { event in
        guard case .block(let block) = event else {
            Issue.record("Missing new-epoch block")
            return
        }
        #expect(block.configurationEpoch == next && block.sourceStartSample == 0)
    }
}

@Test func transferWraparoundAndSequenceExhaustionAreExplicit() throws {
    let config = try transferConfiguration()
    let queue = PCMTransfer(
        configuration: config, initialCursor: UInt64.max - 1, initialSequence: 0)
    for i in 0..<20 {
        #expect(offer(queue, [Float(i)], start: Int64(i)) == .accepted(sequence: UInt64(i)))
        queue.withNext { event in
            guard case .block(let block) = event else {
                Issue.record("Unexpected boundary")
                return
            }
            #expect(block.bytes.load(as: Float.self) == Float(i))
        }
    }
    #expect(queue.snapshot().depth == 0)
    let exhausted = PCMTransfer(configuration: config, initialCursor: 0, initialSequence: .max - 1)
    #expect(offer(exhausted, [1], start: 0) == .accepted(sequence: .max - 1))
    #expect(offer(exhausted, [2], start: 1) == .sequenceExhausted)
    exhausted.withNext { if case .gap = $0 { Issue.record("Gap preceded earlier accepted PCM") } }
    exhausted.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Missing exhaustion gap")
            return
        }
        #expect(gap.reasons == .sequenceExhausted && gap.missingSource == nil)
    }
    #expect(exhausted.withNext { _ in } == .finished)
    #expect(exhausted.snapshot().droppedFrames == 1)
}

@Test func transferConsumerReentrancyCannotReleaseBorrowedStorage() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration())
    offer(queue, [1], start: 0)
    offer(queue, [2], start: 1)
    queue.withNext { event in
        guard case .block(let block) = event else {
            Issue.record("Missing block")
            return
        }
        #expect(
            queue.withNext { _ in Issue.record("Reentrant consumer ran") } == .concurrentConsumer)
        #expect(offer(queue, [3], start: 2) == .droppedCapacity)
        #expect(block.bytes.load(as: Float.self) == 1)
    }
    #expect(queue.snapshot().depth == 1)
}

@Test func transferProducerViolationClosesAndDiscardsUnreadPCM() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration())
    offer(queue, [1, 2], start: 0)
    queue.withHeldProducerAdmissionForTesting {
        #expect(offer(queue, [3], start: 2) == .concurrentProducer)
        #expect(queue.withNext { _ in Issue.record("Read fault before quiescence") } == .empty)
        #expect(offer(queue, [4], start: 3) == .closed)
    }
    queue.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Fault did not invalidate PCM")
            return
        }
        #expect(gap.reasons == .producerViolation && gap.missingSource == nil)
    }
    #expect(queue.withNext { _ in Issue.record("PCM escaped invalidation") } == .finished)
    #expect(queue.snapshot().producerContractViolated)
    #expect(queue.snapshot().droppedFrames == 2 && queue.snapshot().depth == 0)
}

@Test func transferCloseDoesNotMistakeActiveProducerForQuiescence() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration())
    queue.withHeldProducerAdmissionForTesting {
        queue.close()
        queue.close()
        #expect(queue.withNext { _ in Issue.record("Unexpected event") } == .empty)
        #expect(offer(queue, [1], start: 0) == .closed)
    }
    #expect(queue.withNext { _ in } == .finished)
    #expect(!queue.snapshot().producerContractViolated)
}

@Test func transferBorrowKeepsStorageAliveThroughFinalOwnerRelease() throws {
    var owner: PCMTransfer? = PCMTransfer(configuration: try transferConfiguration())
    weak let observed = owner
    offer(owner!, [7], start: 0)
    owner!.withNext { event in
        owner?.close()
        owner = nil
        #expect(observed != nil)
        guard case .block(let block) = event else {
            Issue.record("Missing block")
            return
        }
        #expect(block.bytes.load(as: Float.self) == 7)
    }
    #expect(observed == nil)
}

@Test func transferDelayedCollisionPublishesBeforeTerminalDrain() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration())
    let admitted = DispatchSemaphore(value: 0)
    let releaseAdmission = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    // Even a failed startup prerequisite releases the native holder. It cannot
    // expire on its own and invalidate the rejected-caller precondition below.
    defer { releaseAdmission.signal() }
    startTransferTestThread {
        queue.withHeldProducerAdmissionForTesting {
            admitted.signal()
            releaseAdmission.wait()
        }
        completed.signal()
    }
    try #require(admitted.wait(timeout: .now() + 5) == .success)
    var holderFinished = false
    queue.withSuspendedRejectedProducerForTesting {
        releaseAdmission.signal()
        holderFinished = completed.wait(timeout: .now() + 5) == .success
        if holderFinished {
            // Admission has ended, but this rejected caller still owes its
            // violation. Terminal drain must not overtake that publication.
            queue.close()
            #expect(queue.withNext { _ in Issue.record("Premature event") } == .empty)
        }
    }
    try #require(holderFinished)
    queue.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Missing delayed fault")
            return
        }
        #expect(gap.reasons == .producerViolation && gap.missingSource == nil)
    }
    #expect(queue.withNext { _ in Issue.record("Extra event") } == .finished)
    #expect(offer(queue, [1], start: 0) == .closed)
    #expect(queue.withNext { _ in Issue.record("Event after finished") } == .finished)
}

private struct StressResult: Sendable {
    var accepted = 0
    var acceptedFrames: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var blocks = 0
    var frames: UInt64 = 0
    var gaps = 0
    var errors = 0
    var finished = false
}

@Test(arguments: [PCMEncoding.float32, .float64], [PCMLayout.interleaved, .planar])
func transferAllNativeRepresentationsPreserveChannelBytes(
    encoding: PCMEncoding, layout: PCMLayout
) throws {
    for channels in [1, 2, 32] {
        let config = try transferConfiguration(
            encoding: encoding, layout: layout, channels: channels, frames: 8)
        let queue = PCMTransfer(configuration: config)
        var position: Int64 = 0
        for frames in [8, 1, 7, 2, 8] {
            let planeBytes = frames * config.bytesPerSample
            let input = (0..<(planeBytes * channels)).map { UInt8(($0 * 17 + frames) % 251) }
            let result = input.withUnsafeBytes { bytes in
                if layout == .interleaved {
                    return queue.offerInterleaved(
                        bytes, frameCount: UInt32(frames), sourceStartSample: position,
                        configurationToken: config.captureToken)
                }
                let planes = (0..<channels).map {
                    UnsafeRawBufferPointer(
                        rebasing: bytes[($0 * planeBytes)..<(($0 + 1) * planeBytes)])
                }
                return planes.withUnsafeBufferPointer {
                    queue.offerPlanar(
                        $0, frameCount: UInt32(frames), sourceStartSample: position,
                        configurationToken: config.captureToken)
                }
            }
            guard case .accepted = result else {
                Issue.record("Unexpected rejection")
                return
            }
            queue.withNext { event in
                guard case .block(let block) = event else {
                    Issue.record("Unexpected gap")
                    return
                }
                #expect(Array(block.bytes) == input)
                #expect(block.sourceStartSample == position)
            }
            position += Int64(frames)
        }
    }
}

@Test func transferConcurrentProducerAndConsumerAdmissionAreNonblocking() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration())
    let producerResult = Mutex<PCMTransferOfferResult?>(nil)
    let producerDone = DispatchSemaphore(value: 0)
    var producerCompleted = false
    queue.withHeldProducerAdmissionForTesting {
        startTransferTestThread {
            let result = offer(queue, [1], start: 0)
            producerResult.withLock { $0 = result }
            producerDone.signal()
        }
        producerCompleted = producerDone.wait(timeout: .now() + 5) == .success
    }
    try #require(producerCompleted)
    #expect(producerResult.withLock { $0 } == .concurrentProducer)
    #expect(queue.snapshot().producerContractViolated)

    let other = PCMTransfer(configuration: try transferConfiguration())
    offer(other, [7], start: 0)
    let consumerResult = Mutex<PCMTransferReadResult?>(nil)
    let consumerDone = DispatchSemaphore(value: 0)
    var consumerCompleted = false
    other.withNext { _ in
        startTransferTestThread {
            let result = other.withNext { _ in }
            consumerResult.withLock { $0 = result }
            other.close()
            consumerDone.signal()
        }
        consumerCompleted = consumerDone.wait(timeout: .now() + 5) == .success
    }
    try #require(consumerCompleted)
    #expect(consumerResult.withLock { $0 } == .concurrentConsumer)
    #expect(other.withNext { _ in } == .finished)
}

@Test func transferConcurrentCloseRacesFinalPublicationWithoutLosingAcceptedPCM() throws {
    for trial in 0..<100 {
        let queue = PCMTransfer(configuration: try transferConfiguration(frames: 16, slots: 32))
        defer { queue.close() }
        let result = Mutex(StressResult())
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        startTransferTestThread {
            start.signal()
            var local = StressResult()
            for i in 0..<1000 {
                switch offer(queue, [Float(i)], start: Int64(i)) {
                case .accepted: local.accepted += 1
                case .droppedCapacity: break
                case .closed: break
                default: local.errors += 1
                }
            }
            result.withLock {
                $0.accepted = local.accepted
                $0.errors += local.errors
            }
            group.leave()
        }
        try #require(start.wait(timeout: .now() + 5) == .success)
        if trial % 2 == 0 { Thread.sleep(forTimeInterval: 0.00001) }
        queue.close()
        var blocks = 0
        var finished = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let read = queue.withNext { if case .block = $0 { blocks += 1 } }
            if read == .finished {
                finished = true
                break
            }
        }
        try #require(group.wait(timeout: .now() + 5) == .success)
        let actual = result.withLock { $0 }
        #expect(finished && actual.errors == 0)
        #expect(blocks == actual.accepted)
        #expect(queue.snapshot().depth == 0 && !queue.snapshot().producerContractViolated)
    }
}

@Test func transferEmptyAndNoncontiguousLossStayExplicit() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration(frames: 1))
    #expect(offer(queue, [], start: 0) == .empty)
    #expect(queue.snapshot().depth == 0)
    #expect(offer(queue, [1, 2], start: 0) == .droppedOversized)
    #expect(offer(queue, [3, 4], start: 0) == .droppedOversized)
    #expect(offer(queue, [5], start: 2) == .accepted(sequence: 2))
    queue.withNext { event in
        guard case .gap(let gap) = event else {
            Issue.record("Missing combined loss")
            return
        }
        #expect(gap.reasons == [.oversized, .sourceDiscontinuity])
        #expect(gap.missingSource == nil)
    }
    queue.withNext { event in
        guard case .block(let block) = event else {
            Issue.record("Missing PCM")
            return
        }
        #expect(block.sourceStartSample == 2)
    }
}

@Test func transferConcurrentBurstsPreserveBytesAndExplicitCoverage() throws {
    let queue = PCMTransfer(configuration: try transferConfiguration(frames: 17, slots: 8))
    defer { queue.close() }
    let result = Mutex(StressResult())
    let group = DispatchGroup()
    group.enter()
    startTransferTestThread {
        var local = StressResult()
        var position: Int64 = 0
        for i in 0..<10_000 {
            let count = i % 17 + 1
            let values = (0..<count).map { Float(position + Int64($0)) }
            switch offer(queue, values, start: position) {
            case .accepted:
                local.accepted += 1
                local.acceptedFrames += UInt64(count)
            case .droppedCapacity: local.droppedFrames += UInt64(count)
            default: local.errors += 1
            }
            position += Int64(count)
        }
        queue.close()
        result.withLock {
            $0.accepted = local.accepted
            $0.acceptedFrames = local.acceptedFrames
            $0.droppedFrames = local.droppedFrames
            $0.errors += local.errors
        }
        group.leave()
    }
    group.enter()
    startTransferTestThread {
        var local = StressResult()
        var nextPosition: Int64 = 0
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let state = queue.withNext { event in
                switch event {
                case .gap(let gap):
                    local.gaps += 1
                    if gap.reasons != .capacity || gap.missingSource?.startSample != nextPosition {
                        local.errors += 1
                    }
                    nextPosition = gap.missingSource?.endSample ?? -1
                case .block(let block):
                    if block.sourceStartSample != nextPosition { local.errors += 1 }
                    for (index, value) in block.bytes.bindMemory(to: Float.self).enumerated() {
                        if value != Float(block.sourceStartSample + Int64(index)) {
                            local.errors += 1
                        }
                    }
                    local.blocks += 1
                    local.frames += UInt64(block.frameCount)
                    nextPosition = block.sourceStartSample + Int64(block.frameCount)
                    // Deliberately hold the borrow while capture continues.
                    if local.blocks % 8 == 0 { Thread.sleep(forTimeInterval: 0.0001) }
                }
            }
            if state == .finished {
                local.finished = true
                break
            }
            if state == .empty { Thread.sleep(forTimeInterval: 0.00001) }
        }
        result.withLock {
            $0.blocks = local.blocks
            $0.frames = local.frames
            $0.gaps = local.gaps
            $0.errors += local.errors
            $0.finished = local.finished
        }
        group.leave()
    }
    try #require(group.wait(timeout: .now() + 15) == .success)
    let actual = result.withLock { $0 }
    #expect(actual.finished && actual.errors == 0)
    #expect(actual.blocks == actual.accepted && actual.frames == actual.acceptedFrames)
    #expect(actual.droppedFrames == queue.snapshot().droppedFrames)
    #expect(queue.snapshot().acceptedChunks + queue.snapshot().overflowChunks == 10_000)
    #expect(queue.snapshot().depth == 0 && queue.snapshot().highWaterSlots <= 8)
}
