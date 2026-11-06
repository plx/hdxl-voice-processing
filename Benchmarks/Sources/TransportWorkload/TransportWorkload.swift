import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

public struct TransportCase: Codable, Sendable {
    public let encoding: PCMEncoding
    public let layout: PCMLayout
    public let channels: Int
    public let frames: UInt32
    public let slots: Int
    public var name: String {
        "\(encoding.rawValue)-\(layout.rawValue)-c\(channels)-n\(frames)-s\(slots)"
    }

    public static let matrix: [Self] = [
        .init(encoding: .float32, layout: .interleaved, channels: 1, frames: 1, slots: 8),
        .init(encoding: .float32, layout: .interleaved, channels: 1, frames: 128, slots: 8),
        .init(encoding: .float32, layout: .interleaved, channels: 1, frames: 2048, slots: 16),
        .init(encoding: .float32, layout: .interleaved, channels: 32, frames: 2048, slots: 8),
        .init(encoding: .float32, layout: .planar, channels: 2, frames: 128, slots: 8),
        .init(encoding: .float32, layout: .planar, channels: 32, frames: 65_536, slots: 2),
        .init(encoding: .float64, layout: .interleaved, channels: 2, frames: 128, slots: 8),
        .init(encoding: .float64, layout: .interleaved, channels: 32, frames: 65_536, slots: 2),
        .init(encoding: .float64, layout: .planar, channels: 1, frames: 2048, slots: 16),
        .init(encoding: .float64, layout: .planar, channels: 32, frames: 128, slots: 8),
    ]
}

public enum TransportOperation: String, CaseIterable, Codable, Sendable {
    case firstOffer = "FirstOffer"
    case acceptedBurst = "AcceptedBurst"
    case overflow = "Overflow"
    case oversized = "Oversized"
    case invalid = "Invalid"
    case closed = "Closed"
    case gapRecovery = "GapRecovery"
}

/// Inputs, descriptors and tokens are prepared outside the measured callback batch.
/// This is a synchronous capture-path microbenchmark; concurrency lives in the tests.
public final class TransportBatch {
    public let item: TransportCase
    public let operation: TransportOperation
    public let operationsPerIteration: Int
    private let config: PCMTransferConfiguration
    private let token: PCMTransferEpochToken
    private let input: UnsafeMutableRawPointer
    private let bytes: UnsafeRawBufferPointer
    private let descriptors: UnsafeMutablePointer<UnsafeRawBufferPointer>
    private let planes: UnsafeBufferPointer<UnsafeRawBufferPointer>
    private let isInterleaved: Bool
    private let offeredFrames: UInt32
    private var queue: PCMTransfer
    private var position: Int64 = 0

    public init(item: TransportCase, operation: TransportOperation) throws {
        self.item = item
        self.operation = operation
        operationsPerIteration =
            switch operation {
            case .firstOffer, .gapRecovery: 1
            case .acceptedBurst: item.slots
            default: 1000
            }
        config = try .init(
            format: .init(
                sampleRate: 48_000, channelCount: item.channels,
                encoding: item.encoding, layout: item.layout),
            epoch: .init(streamID: UUID()), maximumFramesPerChunk: item.frames,
            slotCount: item.slots)
        token = config.captureToken
        queue = PCMTransfer(configuration: config)
        input = .allocate(byteCount: config.bytesPerSlot, alignment: 64)
        // The payload is finite native floating point, with unequal channel values.
        if item.encoding == .float32 {
            let p = input.bindMemory(to: Float.self, capacity: config.bytesPerSlot / 4)
            for index in 0..<(config.bytesPerSlot / 4) { p[index] = Float(index % 127) / 128 }
        } else {
            let p = input.bindMemory(to: Double.self, capacity: config.bytesPerSlot / 8)
            for index in 0..<(config.bytesPerSlot / 8) { p[index] = Double(index % 127) / 128 }
        }
        bytes = UnsafeRawBufferPointer(start: input, count: config.bytesPerSlot)
        let planeBytes = Int(item.frames) * config.bytesPerSample
        descriptors = .allocate(capacity: item.channels)
        for channel in 0..<item.channels {
            descriptors.advanced(by: channel).initialize(
                to: UnsafeRawBufferPointer(
                    start: input.advanced(by: channel * planeBytes), count: planeBytes))
        }
        planes = UnsafeBufferPointer(start: descriptors, count: item.channels)
        isInterleaved = item.layout == .interleaved
        offeredFrames = operation == .oversized ? item.frames + 1 : item.frames
    }

    deinit {
        descriptors.deinitialize(count: item.channels)
        descriptors.deallocate()
        input.deallocate()
    }

    public func prepareIteration() {
        queue = PCMTransfer(configuration: config)
        position = 0
        if operation == .closed { queue.close() }
        if operation == .overflow || operation == .gapRecovery {
            for i in 0..<item.slots {
                precondition(
                    submit(frames: item.frames, invalid: false) == .accepted(sequence: UInt64(i)))
            }
            if operation == .gapRecovery {
                precondition(submit(frames: item.frames, invalid: false) == .droppedCapacity)
                for _ in 0..<item.slots {
                    precondition(
                        queue.withNext { event in
                            guard case .block = event else {
                                preconditionFailure("Unexpected setup gap")
                            }
                        } == .delivered)
                }
            }
        }
    }

    @inline(never)
    public func run() -> UInt64 {
        var checksum: UInt64 = 0
        for _ in 0..<operationsPerIteration {
            let result = submit(frames: offeredFrames, invalid: operation == .invalid)
            switch result {
            case .accepted(let sequence): checksum &+= sequence &+ 1
            case .droppedCapacity: checksum &+= 3
            case .droppedOversized: checksum &+= 5
            case .invalidInput: checksum &+= 7
            case .closed: checksum &+= 11
            default: preconditionFailure("Unexpected transport result")
            }
        }
        return checksum
    }

    @inline(__always)
    private func submit(frames: UInt32, invalid: Bool) -> PCMTransferOfferResult {
        let result: PCMTransferOfferResult
        if isInterleaved {
            result = queue.offerInterleaved(
                invalid ? UnsafeRawBufferPointer(start: nil, count: 0) : bytes,
                frameCount: frames, sourceStartSample: position, configurationToken: token,
                hostStartNanoseconds: 123_456_789)
        } else {
            result = queue.offerPlanar(
                invalid ? UnsafeBufferPointer(start: nil, count: 0) : planes,
                frameCount: frames, sourceStartSample: position, configurationToken: token,
                hostStartNanoseconds: 123_456_789)
        }
        position += Int64(frames)
        return result
    }

    /// Off the measured path: verify every copied byte, event count and loss counter.
    public func verify(checksum: UInt64) -> [String: UInt64] {
        let count = UInt64(operationsPerIteration)
        let expectedChecksum: UInt64 =
            switch operation {
            case .firstOffer: 1
            case .acceptedBurst: count * (count + 1) / 2
            case .overflow: count * 3
            case .oversized: count * 5
            case .invalid: count * 7
            case .closed: count * 11
            case .gapRecovery: UInt64(item.slots) + 2
            }
        precondition(checksum == expectedChecksum)
        queue.close()
        var blocks: UInt64 = 0
        var gaps: UInt64 = 0
        var lost: UInt64 = 0
        while queue.withNext({ event in
            switch event {
            case .block(let block):
                precondition(
                    block.frameCount == item.frames && block.hostStartNanoseconds == 123_456_789)
                precondition(block.configurationEpoch == config.epoch)
                precondition(block.bytes.elementsEqual(bytes))
                blocks += 1
            case .gap(let gap):
                precondition(gap.missingSource != nil)
                lost += UInt64(gap.missingSource!.frameCount)
                gaps += 1
            }
        }) == .delivered {}
        let expectedBlocks: UInt64 =
            switch operation {
            case .firstOffer, .gapRecovery: 1
            case .acceptedBurst, .overflow: UInt64(item.slots)
            default: 0
            }
        let expectedLoss: UInt64 =
            switch operation {
            case .overflow, .oversized, .invalid: count * UInt64(offeredFrames)
            case .gapRecovery: UInt64(item.frames)
            default: 0
            }
        precondition(blocks == expectedBlocks && lost == expectedLoss)
        precondition(gaps == (expectedLoss == 0 ? 0 : 1))
        let snapshot = queue.snapshot()
        precondition(snapshot.depth == 0 && snapshot.droppedFrames == expectedLoss)
        precondition(!snapshot.producerContractViolated)
        return [
            "checksum": checksum, "blocks": blocks, "gaps": gaps, "lostFrames": lost,
            "operationsPerIteration": count,
        ]
    }
}
