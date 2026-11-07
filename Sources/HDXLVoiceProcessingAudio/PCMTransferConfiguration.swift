import HDXLVoiceProcessing

/// An immutable capture format and a fixed storage budget, prepared off the callback.
/// Channel identifiers describe the source channels in storage order; no mixing occurs.
public struct PCMTransferConfiguration: Sendable, Equatable {
    public let format: PCMFormat
    public let epoch: StreamEpoch
    public let captureToken: PCMTransferEpochToken
    public let channelMap: [Int]
    public let maximumFramesPerChunk: UInt32
    public let slotCount: Int
    public let bytesPerSample: Int
    public let bytesPerSlot: Int
    public var pcmStorageBytes: Int { bytesPerSlot * slotCount }

    public enum ValidationError: Error, Sendable, Equatable {
        case unsupportedCapacity, invalidChannelMap, storageBudgetExceeded
    }

    /// Limits: 1...65,536 frames, 1...32 channels, 2...4,096 power-of-two slots,
    /// and at most 64 MiB of PCM. Capacity counts whole chunks, including short ones.
    public init(
        format: PCMFormat, epoch: StreamEpoch, channelMap: [Int]? = nil,
        maximumFramesPerChunk: UInt32 = 2048, slotCount: Int = 16
    ) throws {
        guard (1...65_536).contains(maximumFramesPerChunk),
            (1...32).contains(format.channelCount), (2...4096).contains(slotCount),
            slotCount.nonzeroBitCount == 1
        else { throw ValidationError.unsupportedCapacity }
        let map = channelMap ?? Array(0..<format.channelCount)
        guard map.count == format.channelCount, map.allSatisfy({ $0 >= 0 }),
            Set(map).count == map.count
        else { throw ValidationError.invalidChannelMap }
        let width = format.encoding == .float32 ? 4 : 8
        let slotBytes = Int(maximumFramesPerChunk) * format.channelCount * width
        guard slotBytes * slotCount <= 64 * 1024 * 1024 else {
            throw ValidationError.storageBudgetExceeded
        }
        self.format = format
        self.epoch = epoch
        self.captureToken = PCMTransferEpochToken(epoch: epoch)
        self.channelMap = map
        self.maximumFramesPerChunk = maximumFramesPerChunk
        self.slotCount = slotCount
        self.bytesPerSample = width
        self.bytesPerSlot = slotBytes
    }
}

/// A fixed-layout epoch identity prepared before capture. Cache this value in the
/// native adapter; constructing it from the public epoch is control-thread work.
public struct PCMTransferEpochToken: Sendable, Equatable {
    let streamLow: UInt64
    let streamHigh: UInt64
    let sequence: UInt64

    public init(epoch: StreamEpoch) {
        let uuid = epoch.streamID.uuid
        (streamLow, streamHigh) = withUnsafeBytes(of: uuid) {
            (
                $0.loadUnaligned(as: UInt64.self),
                $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            )
        }
        sequence = epoch.sequence
    }
}

/// A source-clock interval within the transport's immutable configuration epoch.
/// These are sample frames, not scalar elements or analysis-clock positions.
public struct PCMTransferLostInterval: Sendable, Equatable {
    public let startSample: Int64
    public let endSample: Int64
    public var frameCount: Int64 { endSample - startSample }
}

/// Reset downstream overlap/history before accepting the next block. A nil interval
/// means the loss cannot be represented as one known contiguous source interval.
public struct PCMTransferGap: Sendable, Equatable {
    public struct Reasons: OptionSet, Sendable, Equatable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let capacity = Self(rawValue: 1 << 0)
        public static let oversized = Self(rawValue: 1 << 1)
        public static let invalidInput = Self(rawValue: 1 << 2)
        public static let sourceDiscontinuity = Self(rawValue: 1 << 3)
        public static let configurationMismatch = Self(rawValue: 1 << 4)
        public static let producerViolation = Self(rawValue: 1 << 5)
        public static let sequenceExhausted = Self(rawValue: 1 << 6)
    }
    public let configurationEpoch: StreamEpoch
    public let reasons: Reasons
    public let missingSource: PCMTransferLostInterval?

}

public enum PCMTransferOfferResult: Sendable, Equatable {
    case accepted(sequence: UInt64)
    case empty
    case droppedCapacity, droppedOversized, invalidInput, configurationMismatch
    case closed, concurrentProducer, sequenceExhausted
}

public enum PCMTransferReadResult: Sendable, Equatable {
    case delivered, empty, finished, concurrentConsumer
}

/// A borrowed view valid only during `withNext`'s closure. Do not retain its pointer.
/// Native-endian Float32/Float64 bytes keep the configured layout. Planar data packs
/// each channel's `frameCount` samples consecutively, without maximum-size padding.
public struct PCMTransferBlock {
    public let sequence: UInt64
    public let sourceStartSample: Int64
    public let frameCount: UInt32
    public let hostStartNanoseconds: UInt64?
    /// The device's signed sample timestamp when actually supplied by a capture
    /// API. Nil means unknown; `sourceStartSample` remains an epoch-local index.
    public let deviceSampleTime: Int64?
    public let configurationEpoch: StreamEpoch
    public let bytes: UnsafeRawBufferPointer
}

public enum PCMTransferEvent {
    case gap(PCMTransferGap)
    case block(PCMTransferBlock)
}

/// Independently sampled counters, not a transactional snapshot. Saturated counters
/// remain at UInt64.max. `depth` is nil if a stable bounded observation was unavailable.
public struct PCMTransferSnapshot: Sendable, Equatable {
    public let admittedCallbacks: UInt64
    public let acceptedChunks: UInt64
    public let overflowChunks: UInt64
    public let oversizedChunks: UInt64
    public let invalidChunks: UInt64
    public let droppedFrames: UInt64
    public let depth: Int?
    public let highWaterSlots: Int
    public let isClosed: Bool
    public let producerContractViolated: Bool
}
