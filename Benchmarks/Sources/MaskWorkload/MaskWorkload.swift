import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum MaskOperation: String, CaseIterable {
    case prepare = "Prepare"
    case run = "Run"
}
public enum MaskWorkloadKind: String, Codable, Sendable, CaseIterable {
    case spectral = "LTSF"
    case energy = "Energy"
    case routing = "Routing"
    case resolution = "Resolution"
    case export = "Metadata"
    case resetSpectral = "ResetLTSF"
    case resetEnergy = "ResetEnergy"
    case resetRouting = "ResetRouting"
}
public struct MaskCase: Encodable, Sendable {
    public let name: String
    public let kind: MaskWorkloadKind
    public let sampleRate: Int
    public let precision: AnalysisPrecision
    public let chunkSamples: Int
    public let inputDurationSeconds = 600
    public let ltsf: LTSFConfiguration
    public let energy: EnergyEligibilityConfiguration
    public var hasPCM: Bool { [.spectral, .energy, .routing].contains(kind) }
    public var shard: String { kind == .spectral ? precision.rawValue : "operations" }
    private init(
        _ kind: MaskWorkloadKind, rate: Int = 16000,
        precision: AnalysisPrecision = .float64, chunk: Int = 256
    ) throws {
        self.kind = kind
        self.sampleRate = rate
        self.precision = precision
        chunkSamples = chunk
        ltsf = try LTSFConfiguration(
            sampleRate: rate, inputPrecision: precision, declaredInputBandwidthHz: Double(rate) / 2)
        energy = try EnergyEligibilityConfiguration(
            sampleRate: rate, inputPrecision: precision,
            declaredInputBandwidthHz: Double(rate) / 2, windowSamples: rate / 100)
        name = "\(kind.rawValue).\(precision.rawValue).\(rate)Hz.600s.\(chunk)chunk"
    }
    public static func matrix() throws -> [Self] {
        var rows: [Self] = []
        for kind in [MaskWorkloadKind.spectral, .energy, .routing] {
            for precision in [AnalysisPrecision.float32, .float64] {
                for chunk in [64, 256, 1024] {
                    rows.append(try Self(kind, precision: precision, chunk: chunk))
                }
            }
            rows.append(try Self(kind, rate: 48000))
        }
        for kind in [
            MaskWorkloadKind.resolution, .export, .resetSpectral, .resetEnergy, .resetRouting,
        ] {
            rows.append(try Self(kind))
        }
        return rows
    }
    public func makeWorkload() throws -> any MaskBatch {
        if precision == .float32 { return try MaskWorkload<Float>(self) }
        return try MaskWorkload<Double>(self)
    }
}
public struct MaskEvidence: Encodable {
    public let name: String
    public let workload: MaskCase
    public let inputSHA256: String
    public let planSHA256: String
    public let preparedInputBytes: Int
    public let preparedScalarWorkspaceBytes: Int
    public let layout: LTSFIntervalLayout
    public let ltsfIdentity: ProfileIdentity
    public let energyIdentity: ProfileIdentity
    public let observations: Int
    public let coverage: MaskCoverage
    public let emittedUnits: Int
    public let exportedBytes: Int
    public let checksum: Double
}
public protocol MaskBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> MaskEvidence
}
private final class MaskPrepared<S: BinaryFloatingPoint & Sendable> {
    let spectral: PreparedLTSFDetector<S>?
    let energy: PreparedEnergyEligibility<S>?
    let cursor: PreparedMaskCursor<S>?
    let timeline: MaskTimeline?
    init(_ item: MaskCase, plan: MaskPlan) throws {
        spectral =
            [.spectral, .resetSpectral].contains(item.kind)
            ? try PreparedLTSFDetector(configuration: item.ltsf, source: plan.source) : nil
        energy =
            [.energy, .resetEnergy].contains(item.kind)
            ? try PreparedEnergyEligibility(configuration: item.energy, epoch: plan.source.epoch)
            : nil
        timeline =
            [.routing, .resetRouting, .export].contains(item.kind) ? try MaskTimeline(plan) : nil
        cursor =
            [.routing, .resetRouting].contains(item.kind)
            ? PreparedMaskCursor(timeline: timeline!, scope: .selected) : nil
    }
}
private final class MaskWorkload<S: BinaryFloatingPoint & Sendable>: MaskBatch {
    let item: MaskCase
    let prepared: MaskPrepared<S>
    let plan: MaskPlan
    let pcm: [S]
    var checksum = 0.0
    var emitted = 0, exported = 0
    init(_ item: MaskCase) throws {
        self.item = item
        let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000034")!)
        let source = try SourceInterval(
            epoch: epoch, startSample: 0,
            sampleCount: Int64(600 * item.sampleRate), sampleRate: Double(item.sampleRate))
        let provenance = try MaskProvenance(
            kind: .externalAnnotation,
            identifier: VersionedIdentifier(name: "benchmark-dense-20ms", version: 1))
        let width = item.sampleRate / 50
        var observations: [MaskObservation] = []
        observations.reserveCapacity(30000)
        for index in 0..<30000 {
            let part = try SourceInterval(
                epoch: epoch, startSample: Int64(index * width),
                sampleCount: Int64(width), sampleRate: source.sampleRate)
            let tags: [MaskTag] =
                index % 101 == 0
                ? [.missingAcquisition]
                : index % 3 == 0 ? [.lowPeriodicityConfidence, .suspectedExternalNoise] : []
            observations.append(
                try MaskObservation(
                    source: part, provenanceIndex: 0,
                    selection: index % 2 == 0 ? .selected : .rejected, tags: tags))
        }
        plan = try MaskPlan(
            source: source, provenances: [provenance],
            policy: MaskSelectionPolicy(selectionSources: [0]), observations: observations)
        prepared = try MaskPrepared(item, plan: plan)
        if item.hasPCM {
            var state: UInt32 = 34
            pcm = (0..<Int(source.sampleCount)).map { index in
                state = 1_664_525 &* state &+ 1_013_904_223
                let noise = (Double(state) - 2_147_483_648) / 21_474_836_480
                let phase = Double(index) * (2 * Double.pi * 125 / Double(item.sampleRate))
                let amplitude = (index / (item.sampleRate / 4)) % 4 == 0 ? 0.001 : 0.2
                return S(amplitude * (sin(phase) + 0.5 * sin(2 * phase + 0.13) + noise))
            }
        } else {
            pcm = []
        }
    }
    @inline(never) func prepare() throws -> AnyObject { try MaskPrepared<S>(item, plan: plan) }
    @inline(never) func run() throws -> Double { try execute(chunk: item.chunkSamples) }
    private func resetEnergy() throws {
        let previous = prepared.energy!.epoch
        try prepared.energy!.reset(
            for: SourceDiscontinuity(
                previousEpoch: previous,
                nextEpoch: previous.successor(), reason: .explicitReset))
    }
    private func execute(chunk: Int) throws -> Double {
        checksum = 0
        emitted = 0
        exported = 0
        switch item.kind {
        case .resolution:
            let result = try MaskTimeline(plan)
            emitted = result.segments.count
            checksum = Double(
                result.coverage.selectedSampleCount + result.coverage.missingSampleCount)
        case .export:
            let data = try prepared.timeline!.canonicalJSON()
            exported = data.count
            emitted = 1
            // Consume every encoded byte, separate from detector/routing hot paths.
            checksum = data.reduce(0.0) { $0 + Double($1) }
        case .resetSpectral:
            try prepared.spectral!.reset(source: plan.source)
            checksum = Double(prepared.spectral!.layout.frameCount)
            emitted = 1
        case .resetEnergy:
            try resetEnergy()
            checksum = 1
            emitted = 1
        case .resetRouting:
            try prepared.cursor!.resetToStart()
            checksum = 1
            emitted = 1
        case .spectral, .energy, .routing:
            try prepared.spectral?.reset(source: plan.source)
            if prepared.energy != nil { try resetEnergy() }
            try prepared.cursor?.resetToStart()
            let epoch = prepared.energy?.epoch ?? plan.source.epoch
            try pcm.withUnsafeBufferPointer { input in
                for start in stride(from: 0, to: input.count, by: chunk) {
                    let end = min(input.count, start + chunk)
                    let interval = try SourceInterval(
                        epoch: epoch, startSample: Int64(start),
                        sampleCount: Int64(end - start), sampleRate: plan.source.sampleRate)
                    let buffer = UnsafeBufferPointer(rebasing: input[start..<end])
                    try prepared.spectral?.append(buffer, interval: interval)
                    try prepared.energy?.process(buffer, interval: interval) { output in
                        emitted += 1
                        checksum +=
                            output.level.mathematicalDecibels! + (output.isEligible == true ? 1 : 0)
                    }
                    try prepared.cursor?.process(buffer, interval: interval) { samples, context in
                        emitted += samples.count
                        for (offset, sample) in samples.enumerated() {
                            checksum +=
                                Double(sample)
                                * Double((context.source.startSample + Int64(offset)) % 17 + 1)
                        }
                    }
                }
            }
            try prepared.spectral?.finish { output in
                emitted = output.flatness.count
                for value in output.flatness { checksum += value }
                for value in output.referenceIntensityDB { checksum += value }
                for region in output.speechIntervals {
                    checksum += region.endSeconds + (region.isSpeech ? 1 : 0)
                }
            }
            try prepared.energy?.finish { _ in
                preconditionFailure("No partial windows in declared workload")
            }
        }
        return checksum
    }
    func verify() throws -> MaskEvidence {
        let first = try run()
        let count = emitted
        let bytes = exported
        let second = try execute(chunk: 137)
        precondition(
            first == second && first.isFinite && first != 0 && count == emitted && bytes == exported
        )
        let timeline = try MaskTimeline(plan)
        let layout = try LTSFIntervalLayout(configuration: item.ltsf, source: plan.source)
        switch item.kind {
        case .spectral: precondition(emitted == layout.frameCount)
        case .energy: precondition(emitted == 60000)
        case .routing: precondition(Int64(emitted) == timeline.coverage.selectedSampleCount)
        case .resolution: precondition(emitted == 30000)
        default: precondition(emitted == 1)
        }
        let input = pcm.withUnsafeBytes { Data($0) }
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return MaskEvidence(
            name: item.name, workload: item, inputSHA256: digest(input),
            planSHA256: digest(try plan.canonicalJSON()), preparedInputBytes: input.count,
            preparedScalarWorkspaceBytes: prepared.spectral?.scalarWorkspaceBytes ?? 0,
            layout: layout, ltsfIdentity: try item.ltsf.identity(),
            energyIdentity: try item.energy.provenance().identity(),
            observations: plan.observations.count, coverage: timeline.coverage,
            emittedUnits: emitted, exportedBytes: exported, checksum: checksum)
    }
}
