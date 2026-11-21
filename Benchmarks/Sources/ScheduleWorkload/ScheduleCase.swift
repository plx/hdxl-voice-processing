import Foundation
import HDXLVoiceProcessing

let scheduleBenchmarkEpoch = StreamEpoch(
    streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000440")!)

public enum ScheduleOperation: String, Sendable, CaseIterable {
    case prepare = "Prepare"
    case run = "Run"
}
public enum ScheduleKind: String, Codable, Sendable { case preview, selected, whole }
public enum ScheduleComposition: String, Codable, Sendable { case light, full }

public struct ScheduleCase: Codable, Sendable {
    public let name: String
    public let profile: AnalysisScheduleProfile
    public let identity: ProfileIdentity
    public let kind: ScheduleKind
    public let composition: ScheduleComposition
    public let sourceTileCapacity: Int
    public let inputChunkSamples: Int
    public let inputSampleCount: Int
    public let maskPlan: MaskPlan?

    init(
        rate: Int, precision: AnalysisPrecision, composition: ScheduleComposition,
        channels: Int = 1, layout: PCMLayout = .interleaved, kind: ScheduleKind = .preview
    ) throws {
        self.composition = composition
        self.kind = kind
        sourceTileCapacity = 256
        inputChunkSamples = 173
        inputSampleCount = rate
        let full = composition == .full
        profile = try AnalysisScheduleProfile(
            inputFormat: PCMFormat(
                sampleRate: Double(rate),
                channelCount: channels, encoding: precision == .float32 ? .float32 : .float64,
                layout: layout),
            channels: .arithmeticMean,
            levels: LevelConfiguration(
                sampleRate: rate, inputPrecision: precision,
                windowLength: rate / 40, hopLength: rate / 100, accumulation: .compensatedSliding,
                weighting: full ? .bs1770Revision5(warmupSampleCount: rate / 10) : .none),
            pitch: YINProfile(
                estimator: YINConfiguration(
                    sampleRate: rate, inputPrecision: precision,
                    pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: rate / 100),
                tracker: full ? YINTrackerConfiguration() : nil),
            cpps: full
                ? CPPSProfile(
                    cepstrogram: CepstrogramConfiguration(
                        sourceSampleRate: rate,
                        inputPrecision: precision, hopSeconds: 0.01,
                        declaredInputBandwidthHz: Double(rate) / 2,
                        conditioningMethod: kind == .whole
                            ? .praat7WholeInterval(interpolationDepth: 50)
                            : .streamingPreview(lobes: 16, cutoffFraction: 0.9)),
                    settings: CPPSConfiguration(
                        timeWindowSeconds: 0.02,
                        prominence: CPPConfiguration(
                            pitchCeilingHz: 330, fitEndSeconds: 0,
                            fitMethod: .praat7002Robust))) : nil)
        identity = try profile.identity()
        name =
            "\(composition.rawValue).\(precision.rawValue).\(rate)Hz.c\(channels).\(layout.rawValue).\(kind.rawValue)"
        if kind == .selected {
            let whole = try SourceInterval(
                epoch: scheduleBenchmarkEpoch, startSample: 0,
                sampleCount: Int64(rate), sampleRate: Double(rate))
            let provenance = try MaskProvenance(
                kind: .externalAnnotation,
                identifier: VersionedIdentifier(name: "schedule-benchmark-regions", version: 1))
            maskPlan = try MaskPlan(
                source: whole, provenances: [provenance],
                policy: MaskSelectionPolicy(selectionSources: [0]),
                observations: [
                    MaskObservation(
                        source: SourceInterval(
                            epoch: whole.epoch, startSample: 0,
                            sampleCount: Int64(rate * 2 / 5), sampleRate: whole.sampleRate),
                        provenanceIndex: 0, selection: .selected, tags: [.speechDetected]),
                    MaskObservation(
                        source: SourceInterval(
                            epoch: whole.epoch, startSample: Int64(rate * 3 / 5),
                            sampleCount: Int64(rate * 2 / 5), sampleRate: whole.sampleRate),
                        provenanceIndex: 0, selection: .selected, tags: [.speechDetected]),
                ])
        } else {
            maskPlan = nil
        }
    }

    public static func matrix() throws -> [Self] {
        var result: [Self] = []
        for precision in [AnalysisPrecision.float32, .float64] {
            for rate in [16000, 44100, 48000] {
                for composition in [ScheduleComposition.light, .full] {
                    result.append(
                        try Self(rate: rate, precision: precision, composition: composition))
                }
            }
            for layout in [PCMLayout.interleaved, .planar] {
                result.append(
                    try Self(
                        rate: 48000, precision: precision, composition: .full,
                        channels: 2, layout: layout))
            }
            result.append(
                try Self(rate: 16000, precision: precision, composition: .full, kind: .selected))
            result.append(
                try Self(rate: 16000, precision: precision, composition: .full, kind: .whole))
        }
        return result
    }

    public func makeWorkload() throws -> any ScheduleBatch {
        if profile.inputPrecision == .float32 { return try ScheduleWorkload<Float>(self) }
        return try ScheduleWorkload<Double>(self)
    }
}

public struct ScheduleLaneDigest: Codable, Equatable, Sendable {
    public var frames = 0
    public var available = 0
    public var sourceStartSum: Int64 = 0
    public var sourceCountSum: Int64 = 0
    public var checksum = 0.0
    public var auxiliaryChecksum = 0.0

    mutating func support(_ source: SourceInterval, offset: Int64) {
        frames += 1
        sourceStartSum += source.startSample + offset
        sourceCountSum += source.sampleCount
    }
}

public struct ScheduleDigest: Codable, Equatable, Sendable {
    public var levels = ScheduleLaneDigest()
    public var pitch = ScheduleLaneDigest()
    public var cpps = ScheduleLaneDigest()

    mutating func consume(_ value: ScheduledFrameValue, offset: Int64) {
        switch value {
        case .levels(let value):
            levels.support(value.filterHistorySource ?? value.source, offset: offset)
            if let energy = value.unweighted.energy {
                levels.available += 1
                levels.checksum += energy.normalizedMeanSquare * energy.scale * energy.scale
            }
            if let energy = value.weighted?.energy {
                levels.auxiliaryChecksum +=
                    energy.normalizedMeanSquare * energy.scale * energy.scale
            }
        case .pitch(let raw, let tracked):
            pitch.support(tracked?.dependencyTiming.source ?? raw.timing.source, offset: offset)
            if let observation = raw.observation {
                pitch.available += 1
                pitch.checksum += observation.frequencyHz
            }
            pitch.auxiliaryChecksum += tracked?.observation?.frequencyHz ?? 0
        case .hnr:
            // This suite fixes the pre-HNR scheduler compositions. HNR has its
            // own matrix; silently accepting an unexpected lane would hide drift.
            preconditionFailure("HNR is not configured in this scheduler workload")
        case .swipePrime:
            preconditionFailure("SWIPE-prime is not configured in this scheduler workload")
        case .cpps(let value):
            cpps.support(value.context.timing.source, offset: offset)
            if let observation = value.observation {
                cpps.available += 1
                cpps.checksum += observation.prominenceDB
            }
            cpps.auxiliaryChecksum += value.rawCPP.observation?.prominenceDB ?? 0
        }
    }
}

public struct ScheduleEvidence: Codable, Sendable {
    public let name: String
    public let workload: ScheduleCase
    public let inputSHA256: String
    public let preparedBufferBytes: Int
    public let preparedInputBytes: Int
    public let inputDurationSeconds: Double
    public let analyzedDurationSeconds: Double
    public let digest: ScheduleDigest
    public let directDigest: ScheduleDigest
    public let splitDigest: ScheduleDigest
}

public protocol ScheduleBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> ScheduleEvidence
}
