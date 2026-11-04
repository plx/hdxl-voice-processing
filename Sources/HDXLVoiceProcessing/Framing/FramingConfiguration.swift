import CryptoKit
import Foundation

/// A left-anchored integer grid: epochStart + firstFrameOffsetSamples + ordinal * hopLength.
/// This is not Praat's whole-segment-centered, floating-point time grid.
public struct FramingConfiguration: Sendable, Hashable, Codable {
    public let window: WindowSpecification
    public let hopLength: Int
    public let firstFrameOffsetSamples: Int
    public let partialWindowPolicy: PartialWindowPolicy

    public init(
        window: WindowSpecification, hopLength: Int, firstFrameOffsetSamples: Int = 0,
        partialWindowPolicy: PartialWindowPolicy = .discard
    ) throws {
        guard (1...Int(Int32.max)).contains(hopLength),
            (0...Int(Int32.max)).contains(firstFrameOffsetSamples),
            (Double(hopLength) / window.sampleRate).isFinite
        else { throw ContractError.invalidConfiguration }
        self.window = window
        self.hopLength = hopLength
        self.firstFrameOffsetSamples = firstFrameOffsetSamples
        self.partialWindowPolicy = partialWindowPolicy
    }

    /// Projects framing fields only. The algorithm factory must validate the rest of the profile.
    public init(framingFieldsOf profile: AnalysisProfile, firstFrameOffsetSamples: Int = 0) throws {
        try self.init(
            window: WindowSpecification(windowFieldsOf: profile), hopLength: profile.hopLength,
            firstFrameOffsetSamples: firstFrameOffsetSamples,
            partialWindowPolicy: profile.partialWindowPolicy)
    }

    public func identity() throws -> ProfileIdentity {
        let bytes = try canonicalContractJSON(self)
        return try ProfileIdentity(
            identifier: VersionedIdentifier(name: "sample-grid-framing", version: 1),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    /// Pure integer eligibility calculation; does not allocate or require PCM for long timelines.
    public func completeFrameCount(observedSampleCount: Int64) throws -> UInt64 {
        guard observedSampleCount >= 0 else { throw ContractError.invalidInterval }
        let required = Int64(firstFrameOffsetSamples) + Int64(window.sampleCount)
        guard observedSampleCount >= required else { return 0 }
        return UInt64((observedSampleCount - required) / Int64(hopLength)) + 1
    }

    public func frameStartSample(ordinal: UInt64, epochStart: Int64 = 0) throws -> Int64 {
        guard epochStart >= 0 else { throw ContractError.invalidInterval }
        let displacement = ordinal.multipliedReportingOverflow(by: UInt64(hopLength))
        let anchor = UInt64(epochStart) + UInt64(firstFrameOffsetSamples)
        let result = anchor.addingReportingOverflow(displacement.partialValue)
        guard !displacement.overflow, !result.overflow,
            let value = Int64(exactly: result.partialValue)
        else { throw ContractError.arithmeticOverflow }
        return value
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case window, hopLength, firstFrameOffsetSamples, partialWindowPolicy
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            window: c.decode(WindowSpecification.self, forKey: .window),
            hopLength: c.decode(Int.self, forKey: .hopLength),
            firstFrameOffsetSamples: c.decode(Int.self, forKey: .firstFrameOffsetSamples),
            partialWindowPolicy: c.decode(PartialWindowPolicy.self, forKey: .partialWindowPolicy))
    }
}

/// Frame eligibility is geometry, not evidence of speech, voicing, or a valid scalar measurement.
public struct PCMFrameSupport: Sendable, Hashable {
    public let framingIdentity: ProfileIdentity
    public let frameIndex: UInt64
    public let source: SourceInterval
    public let nominalSampleCount: Int
    public var missingSampleCount: Int { nominalSampleCount - Int(source.sampleCount) }
    public var unavailability: UnavailabilityReason? {
        missingSampleCount == 0 ? nil : .insufficientData
    }
    /// Center of actual observed support. Integer source indices remain authoritative.
    public var observedCenterSeconds: Double {
        Double(source.startSample) / source.sampleRate + source.durationSeconds / 2
    }
}

public struct FramingProcessReport: Sendable, Hashable {
    public let consumedSampleCount: Int
    public let emittedFrameCount: Int
    public let isCancelled: Bool
}

public enum FramingEndDisposition: String, Sendable, Hashable {
    case empty, noEligibleFrame, complete, discardedPartial, unavailablePartial
}

/// Observed input counts unique input samples, including samples between nonoverlapping frames.
/// Tail support may overlap previously emitted frames; never sum it to compute unique coverage.
public struct FramingCompletion: Sendable, Hashable {
    public let observedSource: SourceInterval
    public let completeFrameCount: UInt64
    public let tailSource: SourceInterval?
    public let disposition: FramingEndDisposition
}
