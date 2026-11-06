import CryptoKit
import Foundation
import HDXLVoiceProcessing

private final class SchedulePrepared<S: BinaryFloatingPoint & Sendable> {
    let plain: PreparedAnalysisSchedule<S>?
    let masked: PreparedMaskedAnalysisSchedule<S>?
    let mask: PreparedAnalysisMask?
    var bytes: Int { (plain?.preparedBufferBytes ?? 0) + (masked?.preparedBufferBytes ?? 0) }

    init(_ item: ScheduleCase) throws {
        let origin = try AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: scheduleBenchmarkEpoch,
                startSample: 0, sampleCount: 0, sampleRate: item.profile.inputFormat.sampleRate),
            continuityEpoch: scheduleBenchmarkEpoch)
        if let plan = item.maskPlan {
            let mask = try PreparedAnalysisMask(timeline: MaskTimeline(plan), scope: .selected)
            self.mask = mask
            plain = nil
            masked = try PreparedMaskedAnalysisSchedule(
                profile: item.profile, origin: origin,
                mode: .finite, mask: mask, sourceTileCapacity: item.sourceTileCapacity)
        } else {
            mask = nil
            masked = nil
            plain = try PreparedAnalysisSchedule(
                profile: item.profile, origin: origin,
                mode: .finite, expectedSampleCount: Int64(item.inputSampleCount),
                sourceTileCapacity: item.sourceTileCapacity)
        }
    }

    func reset(_ item: ScheduleCase) throws {
        if let masked { try masked.resetToStart() }
        if let plain {
            try plain.reset(
                origin: AnalysisScheduleOrigin(
                    source: plain.origin.source,
                    continuityEpoch: plain.origin.continuityEpoch.successor()),
                expectedSampleCount: Int64(item.inputSampleCount))
        }
    }
}

final class ScheduleWorkload<S: BinaryFloatingPoint & Sendable>: ScheduleBatch {
    let item: ScheduleCase
    private let prepared: SchedulePrepared<S>
    private let input: [S]
    private let referenceMono: [S]
    private var planes: UnsafeMutableBufferPointer<UnsafeBufferPointer<S>>
    private var digest = ScheduleDigest()

    init(_ item: ScheduleCase) throws {
        self.item = item
        prepared = try SchedulePrepared(item)
        let n = item.inputSampleCount
        let channels = item.profile.inputFormat.channelCount
        let left = (0..<n).map { index in
            S(
                0.3 * sin(2 * .pi * 125 * Double(index) / Double(n))
                    + 0.07 * cos(2 * .pi * 375 * Double(index) / Double(n)))
        }
        if channels == 1 {
            input = left
            referenceMono = left
        } else {
            let right = left.map { $0 * 0.5 }
            input =
                item.profile.inputFormat.layout == .planar
                ? left + right
                : (0..<n).flatMap { [left[$0], right[$0]] }
            referenceMono = left.map { S(Double($0) * 0.75) }
        }
        planes = .allocate(capacity: channels)
        planes.initialize(repeating: UnsafeBufferPointer(start: nil, count: 0))
    }

    deinit {
        planes.deinitialize()
        planes.deallocate()
    }
    @inline(never) func prepare() throws -> AnyObject { try SchedulePrepared<S>(item) }
    @inline(never) func run() throws -> Double { try execute(chunk: item.inputChunkSamples) }

    private func consume(_ frame: ScheduledFrame) {
        precondition(frame.coverage.missing == 0)
        if item.kind == .selected { precondition(frame.coverage.selected == frame.coverage.source) }
        digest.consume(frame.value, offset: frame.origin.source.startSample)
    }

    private func execute(chunk: Int) throws -> Double {
        try prepared.reset(item)
        digest = ScheduleDigest()
        try input.withUnsafeBufferPointer { input in
            var offset = 0
            while offset < item.inputSampleCount {
                let count = min(chunk, item.inputSampleCount - offset)
                let source = try SourceInterval(
                    epoch: scheduleBenchmarkEpoch, startSample: Int64(offset),
                    sampleCount: Int64(count), sampleRate: item.profile.inputFormat.sampleRate)
                if item.profile.inputFormat.layout == .interleaved {
                    let channels = item.profile.inputFormat.channelCount
                    let part = UnsafeBufferPointer(
                        rebasing: input[(offset * channels)..<((offset + count) * channels)])
                    if let worker = prepared.plain {
                        _ = try worker.processInterleaved(part, interval: source) { consume($0) }
                    } else if let worker = prepared.masked {
                        _ = try worker.processInterleaved(part, interval: source) { consume($0) }
                    }
                } else {
                    for channel in planes.indices {
                        let start = channel * item.inputSampleCount + offset
                        planes[channel] = UnsafeBufferPointer(
                            rebasing: input[start..<(start + count)])
                    }
                    if let worker = prepared.plain {
                        _ = try worker.processPlanar(UnsafeBufferPointer(planes), interval: source)
                        { consume($0) }
                    } else if let worker = prepared.masked {
                        _ = try worker.processPlanar(UnsafeBufferPointer(planes), interval: source)
                        { consume($0) }
                    }
                }
                offset += count
            }
        }
        for index in planes.indices { planes[index] = UnsafeBufferPointer(start: nil, count: 0) }
        if let worker = prepared.plain {
            let result = try worker.finish { consume($0) }
            precondition(result.coverage.source == Int64(item.inputSampleCount))
        }
        if let worker = prepared.masked {
            let result = try worker.finish()
            precondition(result.coverage.source == Int64(item.inputSampleCount))
            precondition(result.analyzedSampleCount == Int64(item.inputSampleCount * 4 / 5))
        }
        return digest.levels.checksum + digest.pitch.checksum + digest.cpps.checksum
    }

    private func directReference() throws -> ScheduleDigest {
        let regions: [SourceInterval]
        if let mask = prepared.mask {
            regions = mask.timeline.selectedRegions
        } else {
            regions = [
                try SourceInterval(
                    epoch: scheduleBenchmarkEpoch, startSample: 0,
                    sampleCount: Int64(item.inputSampleCount),
                    sampleRate: item.profile.inputFormat.sampleRate)
            ]
        }
        var reference = ScheduleDigest()
        try referenceMono.withUnsafeBufferPointer { input in
            for region in regions {
                let part = UnsafeBufferPointer(
                    rebasing: input[Int(region.startSample)..<Int(region.endSample)])
                let local = try SourceInterval(
                    epoch: scheduleBenchmarkEpoch, startSample: 0,
                    sampleCount: region.sampleCount, sampleRate: region.sampleRate)
                if let configuration = item.profile.levels {
                    let worker = try PreparedLevelAnalyzer<S>(
                        configuration: configuration, epoch: local.epoch)
                    _ = try worker.process(part, interval: local) {
                        reference.consume(.levels($0), offset: region.startSample)
                    }
                    _ = try worker.finish {
                        reference.consume(.levels($0), offset: region.startSample)
                    }
                }
                if let profile = item.profile.pitch {
                    let worker = try PreparedYINAnalyzer<S>(profile: profile, epoch: local.epoch)
                    _ = try worker.process(part, interval: local) {
                        reference.consume(
                            .pitch(raw: $0.raw.result, tracked: $0.tracked),
                            offset: region.startSample)
                    }
                    _ = try worker.finish {
                        reference.consume(
                            .pitch(raw: $0.raw.result, tracked: $0.tracked),
                            offset: region.startSample)
                    }
                }
                if let profile = item.profile.cpps {
                    if item.kind == .whole {
                        let worker = try PreparedIntervalCPPS<S>(profile: profile, source: local)
                        try worker.append(part, interval: local)
                        _ = try worker.finish {
                            reference.consume(.cpps($0.result), offset: region.startSample)
                        }
                    } else {
                        let worker = try PreparedPreviewCPPS<S>(
                            profile: profile, epoch: local.epoch)
                        _ = try worker.process(part, interval: local) {
                            reference.consume(.cpps($0.result), offset: region.startSample)
                        }
                        _ = try worker.finish {
                            reference.consume(.cpps($0.result), offset: region.startSample)
                        }
                    }
                }
            }
        }
        return reference
    }

    func verify() throws -> ScheduleEvidence {
        let memory = prepared.bytes
        _ = try run()
        let baseline = digest
        _ = try execute(chunk: 63)
        let split = digest
        precondition(split == baseline && prepared.bytes == memory)
        _ = try execute(chunk: item.inputSampleCount)
        precondition(digest == baseline && prepared.bytes == memory)
        let direct = try directReference()
        precondition(
            direct == baseline,
            "Direct native kernels disagree for \(item.name): \(direct) vs \(baseline)")
        precondition(baseline.levels.available > 0 && baseline.pitch.available > 0)
        if item.composition == .full { precondition(baseline.cpps.available > 0) }
        let hash = input.withUnsafeBytes {
            SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined()
        }
        return ScheduleEvidence(
            name: item.name, workload: item, inputSHA256: hash,
            preparedBufferBytes: memory + planes.count
                * MemoryLayout<UnsafeBufferPointer<S>>.stride,
            preparedInputBytes: input.count * MemoryLayout<S>.stride,
            inputDurationSeconds: 1, analyzedDurationSeconds: item.kind == .selected ? 0.8 : 1,
            digest: baseline, directDigest: direct, splitDigest: split)
    }
}
