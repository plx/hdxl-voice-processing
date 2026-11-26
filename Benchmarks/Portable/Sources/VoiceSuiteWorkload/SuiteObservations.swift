import Foundation
import HDXLVoiceProcessing

/// Source-frame counts repeat within each acquisition region. An empty or zero-sized
/// partition would prevent the input cursor from advancing.
public struct SuitePartition: Sendable {
    public let sizes: [Int]

    public init(_ sizes: [Int]) throws {
        guard !sizes.isEmpty, sizes.allSatisfy({ $0 > 0 }) else {
            throw SuiteError.invalidInput("chunk sizes")
        }
        self.sizes = sizes
    }

    func next(at index: inout Int) -> Int {
        let size = sizes[index]
        index += 1
        if index == sizes.count { index = 0 }
        return size
    }
}

public struct SuitePoint: Encodable, Equatable, Sendable {
    public let sample: Int64
    public let value: Double?
    public let status: String?
    public let reason: UnavailabilityReason?
}

/// Preserve the support of the reported measurement separately from its complete
/// dependency interval. Both use the original, unspliced fixture coordinates.
public struct SuiteSupport: Encodable, Equatable, Sendable {
    public let epoch: UInt64
    public let windowStart, windowCount, dependencyStart, dependencyCount: Int64
    public let eligible, selected: Int64
    public let metricTiming: AnalysisTiming
    public let centerSecondsFromRegionOrigin, effectiveDelaySeconds: Double
    public let selectedCandidate, trackedCandidate, strongestCandidate: Int?
    public let smoothingFrames: Int?
    public let smoothingEdge: Bool?
    public let lookahead: Double?
    public let warnings: [MeasurementWarning]
}

public struct SuiteObservations: Encodable, Equatable, Sendable {
    public internal(set) var spectra: [String: SuiteBinSequence] = [:]
    public internal(set) var landmarks: [SuitePulsePoint] = []
    public internal(set) var cycleAmplitudes: [SuiteCycleAmplitude] = []
    public internal(set) var completions: [SuiteCompletion] = []
    public internal(set) var nativeUnits: [String: MeasurementUnit] = [:]

    mutating func register(_ unit: MeasurementUnit, for key: String) throws {
        if let previous = nativeUnits[key], previous != unit {
            throw SuiteError.mismatch("Measurement changed unit: " + key)
        }
        nativeUnits[key] = unit
    }
    public internal(set) var values: [String: [SuitePoint]] = [:]
    public internal(set) var support: [String: [SuiteSupport]] = [:]
    public internal(set) var candidates: [String: [SuiteCandidateCount]] = [:]
    public internal(set) var descriptors: [String: MeasurementDescriptor] = [:]

    mutating func record(
        _ frame: ScheduledFrame, origin: AnalysisScheduleOrigin, region: SourceInterval,
        base: Int64, expectedProfile: ProfileIdentity
    ) throws {
        guard frame.schedule == expectedProfile, frame.origin == origin,
            frame.timing.source.epoch == region.epoch,
            frame.timing.source.endSample <= region.endSample
        else { throw SuiteError.mismatch("Scheduled provenance or dependency crossed a region") }

        let metrics: [ScheduledMetric]
        var selected: Int?
        var tracked: Int?
        var strongest: Int?
        var smoothingFrames: Int?
        var smoothingEdge: Bool?
        var lookahead: Double?
        switch frame.value {
        case .levels:
            metrics = [
                .meanSquare, .rms, .peakAmplitude, .crestFactor, .levelDBFS,
                .clippingFraction, .kWeightedEnergy,
            ]
        case .pitch(let raw, let track):
            metrics = [.fundamentalFrequency, .trackedFundamentalFrequency]
            selected = raw.selectedCandidateIndex
            tracked = track?.selectedCandidateIndex
        case .hnr(let hnr):
            metrics = [.harmonicToNoiseRatio]
            if case .frame(let result) = hnr {
                selected = result.selectedCandidateIndex
                strongest = result.strongestCandidateIndex
            }
        case .cpps(let result):
            metrics = [.cpp, .cpps]
            smoothingFrames = result.temporalSupportFrameCount
            smoothingEdge = result.usesSmoothingEdge
            lookahead = result.lookaheadSeconds
        case .swipePrime(let result):
            metrics = [.fundamentalFrequency]
            selected = result.selectedCandidateIndex
        }
        for metric in metrics {
            let export = try frame.export(metric)
            let key = frame.algorithm.rawValue + "." + metric.rawValue
            let descriptor = export.result.measurement
            let window = export.observationWindow
            let measurement = export.result.timing
            guard export.result.profile == expectedProfile, export.origin == origin,
                window.epoch == region.epoch, window.startSample >= region.startSample,
                window.endSample <= region.endSample, export.dependencyTiming == frame.timing,
                measurement.source.epoch == region.epoch,
                measurement.source.startSample >= region.startSample,
                measurement.source.endSample <= region.endSample,
                descriptors[key].map({ $0 == descriptor }) ?? true
            else {
                throw SuiteError.mismatch("Measurement support, profile or units differ: " + key)
            }
            descriptors[key] = descriptor
            support[key, default: []].append(
                SuiteSupport(
                    epoch: region.epoch.sequence, windowStart: base + window.startSample,
                    windowCount: window.sampleCount,
                    dependencyStart: base + frame.timing.source.startSample,
                    dependencyCount: frame.timing.source.sampleCount,
                    eligible: frame.coverage.eligible,
                    selected: frame.coverage.selected,
                    metricTiming: measurement,
                    centerSecondsFromRegionOrigin: frame.frameCenterSecondsFromOrigin,
                    effectiveDelaySeconds: frame.timing.effectiveDelaySeconds,
                    selectedCandidate: selected, trackedCandidate: tracked,
                    strongestCandidate: strongest,
                    smoothingFrames: smoothingFrames, smoothingEdge: smoothingEdge,
                    lookahead: lookahead,
                    warnings: export.result.outcome.estimate?.warnings ?? []))
        }
    }
}

public struct SuiteCandidateCount: Encodable, Equatable, Sendable {
    public let epoch, frame: UInt64
    public let count: Int
}

/// Borrowed candidate storage is valid only during the inspector callback.
final class SuiteCandidateInspection {
    var counts: [String: [SuiteCandidateCount]] = [:]

    func inspect(_ inspection: BorrowedScheduledInspection) {
        let count: Int
        switch inspection.output {
        case .pitch(let pitch): count = pitch.raw.candidates.count
        case .harmonicity(.frame(let hnr)): count = hnr.candidates.count
        case .harmonicity(.unavailable): count = 0
        case .cpps: return
        }
        counts[inspection.frame.algorithm.rawValue, default: []].append(
            SuiteCandidateCount(
                epoch: inspection.frame.origin.continuityEpoch.sequence,
                frame: inspection.frameIndex, count: count))
    }
}

/// The binary payload is a row-major sequence of little-endian Float64 values.
/// Widening Float bins here is exact; this keeps long reference reports compact.
public struct SuiteBinSequence: Encodable, Equatable, Sendable {
    public struct Row: Encodable, Equatable, Sendable {
        let start: Int64
        let count: Int
        let status: String
    }
    public private(set) var rows: [Row] = []
    public private(set) var values = Data()

    mutating func append<C: Collection>(_ bins: C, at start: Int64, status: SpectralFrameStatus)
    where C.Element: BinaryFloatingPoint {
        let label: String
        switch status {
        case .measured: label = "measured"
        case .noEnergy: label = "noEnergy"
        case .unavailable(let reason): label = "unavailable." + reason.rawValue
        }
        rows.append(Row(start: start, count: bins.count, status: label))
        bins.map { Double($0).bitPattern.littleEndian }.withUnsafeBytes {
            values.append(contentsOf: $0)
        }
    }
}

public struct SuitePulsePoint: Encodable, Equatable, Sendable {
    let epoch: UInt64
    let sourceStart: Int64
    let index, voicedInterval: Int
    let timeSeconds: Double
    let run: Int?
    let eligible: Bool
}

public struct SuiteCycleAmplitude: Encodable, Equatable, Sendable {
    let epoch: UInt64
    let sourceStart: Int64
    let pulse: Int
    let rms, supportStartSeconds, supportEndSeconds: Double?
    let observedSamples: Int
    let rejections: PulseRejections
    let eligible: Bool
}
