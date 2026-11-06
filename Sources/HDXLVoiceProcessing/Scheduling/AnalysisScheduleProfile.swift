import CryptoKit
import Foundation

public enum AnalysisScheduleError: Error, Sendable, Equatable {
    case invalidConfiguration, unsupportedLiveProfile, precisionMismatch
    case unexpectedInput, invalidInput, invalidClock, invalidGap
    case invalidState, reentrantCall, capacityExceeded
}

/// Delivery mode does not change a numerical recipe. A finite source has an exact
/// declared extent; a continuous source cannot execute whole-interval algorithms.
public enum AnalysisScheduleMode: String, Sendable, Hashable, Codable {
    case finite, continuous
}

public enum ScheduledAlgorithm: String, Sendable, Hashable, Codable {
    case levels, yin, cpps
}

public enum AnalysisScheduleChannelConversion: String, Sendable, Hashable, Codable {
    case nativeSelectionOrScaledFloat64Mean
}

public enum AnalysisSchedulePlacement: String, Sendable, Hashable {
    case leftAlignedIntegerGrid, centeredCompleteInterval
}

public enum AnalysisScheduleHistory: String, Sendable, Hashable {
    case finiteWindow, continuousCausalHistory, completeInterval
}

public enum AnalysisScheduleResetSemantics: String, Sendable, Hashable {
    case discardHistoryAndRestartLocalGrid
}

/// Geometric requirements, independent of host scheduling and display refresh.
/// Components are reported separately: adding them to an already measured native
/// effective delay would count the same dependencies twice.
public struct AnalysisScheduleRequirements: Sendable, Hashable {
    public let algorithm: ScheduledAlgorithm
    public let analysisSampleRate: Double
    public let frameSupportSeconds: Double
    public let outputIntervalSeconds: Double
    public let filterWarmupSourceSamples: Int
    public let filterLookaheadSeconds: Double
    public let centeredSmoothingLookaheadSeconds: Double
    public let requiresCompleteInterval: Bool
    public let partialWindowPolicy: PartialWindowPolicy
    public let placement: AnalysisSchedulePlacement
    public let history: AnalysisScheduleHistory
    public var resetSemantics: AnalysisScheduleResetSemantics { .discardHistoryAndRestartLocalGrid }
    public var supportsContinuousInput: Bool { !requiresCompleteInterval }
}

/// Composition of explicit numerical profiles. Channel conversion is performed
/// once on the worker; no algorithm receives an implicit speech/voicing mask.
/// File, batch and live delivery share this profile when their semantics match.
public struct AnalysisScheduleProfile: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let inputFormat: PCMFormat
    public let channels: PCMChannelSelection
    public let channelConversion: AnalysisScheduleChannelConversion
    public let levels: LevelConfiguration?
    public let pitch: YINProfile?
    public let cpps: CPPSProfile?

    public var inputPrecision: AnalysisPrecision {
        inputFormat.encoding == .float32 ? .float32 : .float64
    }

    public var requiresCompleteInterval: Bool {
        cpps.map { $0.cepstrogram.previewHopLength == nil } ?? false
    }

    public init(
        inputFormat: PCMFormat, channels: PCMChannelSelection,
        levels: LevelConfiguration? = nil, pitch: YINProfile? = nil,
        cpps: CPPSProfile? = nil
    ) throws {
        guard let rate = Int(exactly: inputFormat.sampleRate),
            (4000...192_000).contains(rate), (1...32).contains(inputFormat.channelCount),
            channels.channelIndex.map({ $0 < inputFormat.channelCount }) ?? true,
            levels != nil || pitch != nil || cpps != nil
        else { throw AnalysisScheduleError.invalidConfiguration }
        let precision: AnalysisPrecision =
            inputFormat.encoding == .float32 ? .float32 : .float64
        if let levels {
            guard levels.sampleRate == rate, levels.inputPrecision == precision else {
                throw AnalysisScheduleError.invalidConfiguration
            }
        }
        if let pitch {
            guard pitch.estimator.sampleRate == rate,
                pitch.estimator.inputPrecision == precision
            else { throw AnalysisScheduleError.invalidConfiguration }
        }
        if let cpps {
            guard cpps.cepstrogram.conditioning.sourceSampleRate == rate,
                cpps.cepstrogram.inputPrecision == precision
            else { throw AnalysisScheduleError.invalidConfiguration }
            _ = try CPPSLayout(profile: cpps)
            if cpps.cepstrogram.previewHopLength != nil {
                _ = try PreviewConditioningLayout(configuration: cpps.cepstrogram.conditioning)
            }
        }
        schemaVersion = 1
        self.inputFormat = inputFormat
        self.channels = channels
        self.channelConversion = .nativeSelectionOrScaledFloat64Mean
        self.levels = levels
        self.pitch = pitch
        self.cpps = cpps
    }

    public func validate(mode: AnalysisScheduleMode) throws {
        if mode == .continuous && requiresCompleteInterval {
            throw AnalysisScheduleError.unsupportedLiveProfile
        }
    }

    /// Prepare/cache on a control or worker path, never per frame or in capture.
    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: "shared-pcm-analysis-schedule", version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    /// Allocates a small configuration report; not a processing operation.
    public func requirements() throws -> [AnalysisScheduleRequirements] {
        var result: [AnalysisScheduleRequirements] = []
        if let levels {
            result.append(
                AnalysisScheduleRequirements(
                    algorithm: .levels, analysisSampleRate: Double(levels.sampleRate),
                    frameSupportSeconds: levels.windowDurationSeconds,
                    outputIntervalSeconds: Double(levels.hopLength) / Double(levels.sampleRate),
                    filterWarmupSourceSamples: levels.weighting.warmupSampleCount,
                    filterLookaheadSeconds: 0, centeredSmoothingLookaheadSeconds: 0,
                    requiresCompleteInterval: false,
                    partialWindowPolicy: levels.partialWindowPolicy,
                    placement: .leftAlignedIntegerGrid,
                    history: levels.kWeighting == nil ? .finiteWindow : .continuousCausalHistory))
        }
        if let pitch {
            let c = pitch.estimator
            result.append(
                AnalysisScheduleRequirements(
                    algorithm: .yin, analysisSampleRate: Double(c.sampleRate),
                    frameSupportSeconds: Double(c.requiredSampleCount) / Double(c.sampleRate),
                    outputIntervalSeconds: Double(c.hopLength) / Double(c.sampleRate),
                    filterWarmupSourceSamples: 0, filterLookaheadSeconds: 0,
                    centeredSmoothingLookaheadSeconds: 0, requiresCompleteInterval: false,
                    partialWindowPolicy: c.partialWindowPolicy,
                    placement: .leftAlignedIntegerGrid,
                    history: pitch.tracker == nil ? .finiteWindow : .continuousCausalHistory))
        }
        if let cpps {
            let c = cpps.cepstrogram
            let smoothing = try CPPSLayout(profile: cpps)
            let lookahead: Double
            if c.previewHopLength != nil {
                lookahead = try PreviewConditioningLayout(configuration: c.conditioning)
                    .maximumFilterLookaheadSeconds
            } else {
                lookahead = 0  // Complete-interval dependency is the explicit flag below.
            }
            result.append(
                AnalysisScheduleRequirements(
                    algorithm: .cpps, analysisSampleRate: Double(c.frame.sampleRate),
                    frameSupportSeconds: Double(c.frame.frameLength) / Double(c.frame.sampleRate),
                    outputIntervalSeconds: c.hopSeconds, filterWarmupSourceSamples: 0,
                    filterLookaheadSeconds: lookahead,
                    centeredSmoothingLookaheadSeconds: smoothing.lookaheadSeconds,
                    requiresCompleteInterval: c.previewHopLength == nil,
                    partialWindowPolicy: .emitUnavailable,
                    placement: c.previewHopLength == nil
                        ? .centeredCompleteInterval : .leftAlignedIntegerGrid,
                    history: c.previewHopLength == nil ? .completeInterval : .finiteWindow))
        }
        return result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, inputFormat, channels, channelConversion, levels, pitch, cpps
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        guard c.contains(.levels), c.contains(.pitch), c.contains(.cpps) else {
            throw AnalysisScheduleError.invalidConfiguration
        }
        try self.init(
            inputFormat: c.decode(PCMFormat.self, forKey: .inputFormat),
            channels: c.decode(PCMChannelSelection.self, forKey: .channels),
            levels: c.decodeIfPresent(LevelConfiguration.self, forKey: .levels),
            pitch: c.decodeIfPresent(YINProfile.self, forKey: .pitch),
            cpps: c.decodeIfPresent(CPPSProfile.self, forKey: .cpps))
        guard
            try c.decode(AnalysisScheduleChannelConversion.self, forKey: .channelConversion)
                == channelConversion
        else { throw AnalysisScheduleError.invalidConfiguration }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(inputFormat, forKey: .inputFormat)
        try c.encode(channels, forKey: .channels)
        try c.encode(channelConversion, forKey: .channelConversion)
        try c.encode(levels, forKey: .levels)
        try c.encode(pitch, forKey: .pitch)
        try c.encode(cpps, forKey: .cpps)
    }
}
