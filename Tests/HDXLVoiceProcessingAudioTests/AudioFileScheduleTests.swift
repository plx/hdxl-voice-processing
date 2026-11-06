import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingAudio

/// Independent PCM16 RIFF writer: expected decoded values are exact integer/32768.
private func schedulingWAV(_ samples: [Int16], rate: Int, channels: Int) throws -> URL {
    var bytes = Data()
    func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
    func integer<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
    text("RIFF")
    integer(UInt32(36 + samples.count * 2))
    text("WAVEfmt ")
    integer(UInt32(16))
    integer(UInt16(1))
    integer(UInt16(channels))
    integer(UInt32(rate))
    integer(UInt32(rate * channels * 2))
    integer(UInt16(channels * 2))
    integer(UInt16(16))
    text("data")
    integer(UInt32(samples.count * 2))
    for value in samples { integer(value) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "schedule-\(UUID()).wav")
    try bytes.write(to: url, options: .atomic)
    return url
}

private func fileScheduleProfile(
    precision: AnalysisPrecision, layout: PCMLayout,
    rate: Int = 48000, channels: Int = 2, reference: Bool = false
) throws -> AnalysisScheduleProfile {
    try AnalysisScheduleProfile(
        inputFormat: PCMFormat(
            sampleRate: Double(rate), channelCount: channels,
            encoding: precision == .float32 ? .float32 : .float64, layout: layout),
        channels: .arithmeticMean,
        levels: LevelConfiguration(
            sampleRate: rate, inputPrecision: precision,
            windowLength: 400, hopLength: 160, accumulation: .compensatedSliding, weighting: .none),
        pitch: YINProfile(
            estimator: YINConfiguration(
                sampleRate: rate, inputPrecision: precision,
                pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: 160)),
        cpps: CPPSProfile(
            cepstrogram: CepstrogramConfiguration(
                sourceSampleRate: rate,
                inputPrecision: precision, hopSeconds: 0.01,
                declaredInputBandwidthHz: Double(rate) / 2,
                conditioningMethod: reference
                    ? .praat7WholeInterval(interpolationDepth: 50)
                    : .streamingPreview(lobes: 8, cutoffFraction: 0.9)),
            settings: CPPSConfiguration(
                timeWindowSeconds: 0.02,
                prominence: CPPConfiguration(fitMethod: .leastSquares))))
}

private func fileScheduleOrigin(start: Int64, rate: Int = 48000) throws -> AnalysisScheduleOrigin {
    let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000340")!)
    return try AnalysisScheduleOrigin(
        source: SourceInterval(
            epoch: epoch, startSample: start,
            sampleCount: 0, sampleRate: Double(rate)), continuityEpoch: epoch,
        sourceStartSeconds: Double(start) / Double(rate))
}

private func fileScheduleParity<Sample: BinaryFloatingPoint & Sendable>(
    _: Sample.Type, layout: PCMLayout, reference: Bool = false
) throws {
    let rate = reference ? 16000 : 48000
    let input: [Int16] = (0..<6401).flatMap { index in
        let sample = Int16(9000 * sin(2 * .pi * 125 * Double(index) / Double(rate)))
        return [sample, -sample / 2]
    }
    let url = try schedulingWAV(input, rate: rate, channels: 2)
    defer { try? FileManager.default.removeItem(at: url) }
    let profile = try fileScheduleProfile(
        precision: Sample.self == Float.self ? .float32 : .float64,
        layout: layout, rate: rate, reference: reference)
    let origin = try fileScheduleOrigin(start: 97, rate: rate)
    let count = 6304  // Exact EOF, with an uneven final decoder chunk.
    let source = try SourceInterval(
        epoch: origin.source.epoch, startSample: 97,
        sampleCount: Int64(count), sampleRate: Double(rate))
    let values = input[(97 * 2)...].map { Sample($0) / 32768 }
    let direct = try PreparedAnalysisSchedule<Sample>(
        profile: profile, origin: origin,
        mode: .finite, expectedSampleCount: Int64(count), sourceTileCapacity: 128)
    var expected: [ScheduledFrame] = []
    if layout == .interleaved {
        _ = try values.withUnsafeBufferPointer {
            try direct.processInterleaved($0, interval: source) { expected.append($0) }
        }
    } else {
        let left = stride(from: 0, to: values.count, by: 2).map { values[$0] }
        let right = stride(from: 1, to: values.count, by: 2).map { values[$0] }
        _ = try left.withUnsafeBufferPointer { l in
            try right.withUnsafeBufferPointer { r in
                try [l, r].withUnsafeBufferPointer {
                    try direct.processPlanar($0, interval: source) { expected.append($0) }
                }
            }
        }
    }
    let expectedCompletion = try direct.finish { expected.append($0) }
    #expect(
        expected.contains {
            if case .cpps(let value) = $0.value { return value.observation != nil }
            return false
        })
    for capacity in [1, 173, 4096] {
        let worker = try PreparedAudioFileSchedule<Sample>(
            url: url, profile: profile, origin: origin,
            chunkCapacity: capacity, sourceTileCapacity: 128)
        let memory = worker.preparedBufferBytes
        var frames: [ScheduledFrame] = []
        var regions: [AnalysisScheduleCompletion] = []
        var decoded: Int64 = 0
        while worker.completion == nil {
            let progress = try worker.read(
                maximumChunks: 7,
                emit: {
                    #expect($0.decoding.storage.bitsPerChannel == 16)
                    #expect($0.decoding.decodedPCM == profile.inputFormat)
                    #expect($0.decoding.fileSampleCount == 6401)
                    #expect($0.frame.origin.hostStartNanoseconds == nil)
                    frames.append($0.frame)
                }, regionCompleted: { regions.append($0) })
            decoded += progress.decodedSampleCount
        }
        #expect(decoded == Int64(count))
        #expect(worker.preparedBufferBytes == memory)
        #expect(frames == expected)
        #expect(regions == [expectedCompletion])
        #expect(worker.completion == .analyzed(expectedCompletion))
        #expect(try worker.read(emit: { _ in Issue.record("File finalized twice") }).isFinished)
    }
}

@Test func schedulingFilesMatchMemoryAcrossDecoderChunksPrecisionsAndLayouts() throws {
    for layout in [PCMLayout.interleaved, .planar] {
        try fileScheduleParity(Float.self, layout: layout)
        try fileScheduleParity(Double.self, layout: layout)
    }
    try fileScheduleParity(Double.self, layout: .planar, reference: true)
}

@Test func schedulingFileMasksSkipMissingPCMAndPreserveEmptyClipResults() throws {
    let url = try schedulingWAV(Array(repeating: 8192, count: 1000), rate: 16000, channels: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    let profile = try fileScheduleProfile(
        precision: .float64, layout: .planar, rate: 16000, channels: 1)
    let origin = try fileScheduleOrigin(start: 0, rate: 16000)
    func source(_ start: Int64, _ count: Int64) throws -> SourceInterval {
        try SourceInterval(
            epoch: origin.source.epoch, startSample: start, sampleCount: count, sampleRate: 16000)
    }
    let provenance = try MaskProvenance(
        kind: .acquisitionDiagnostics,
        identifier: VersionedIdentifier(name: "file-gap-test", version: 1))
    let mask = try PreparedAnalysisMask(
        timeline: MaskTimeline(
            MaskPlan(
                source: source(0, 1000),
                provenances: [provenance], policy: MaskSelectionPolicy(),
                observations: [
                    MaskObservation(
                        source: source(300, 400), provenanceIndex: 0, tags: [.missingAcquisition])
                ])), scope: .allEligible)
    let worker = try PreparedAudioFileSchedule<Double>(
        url: url, profile: profile,
        origin: origin, chunkCapacity: 512, mask: mask)
    var decoded: Int64 = 0
    var advanced: Int64 = 0
    var regions: [AnalysisScheduleCompletion] = []
    while worker.completion == nil {
        let report = try worker.read(
            emit: {
                #expect($0.frame.coverage.missing == 0)
                #expect(
                    $0.frame.timing.source.endSample <= 300
                        || $0.frame.timing.source.startSample >= 700)
            }, regionCompleted: { regions.append($0) })
        decoded += report.decodedSampleCount
        advanced += report.advancedSourceSamples
    }
    #expect(decoded == 600)
    #expect(advanced == 1000)
    #expect(regions.map(\.observedSource.sampleCount) == [300, 300])
    guard case .masked(let result) = worker.completion else {
        Issue.record("Missing masked result")
        return
    }
    #expect(result.coverage.missing == 400)
    #expect(result.coverage.eligible == 600)

    let empty = try PreparedAudioFileSchedule<Double>(
        url: url, profile: profile,
        origin: fileScheduleOrigin(start: 1000, rate: 16000))
    #expect(try empty.read(emit: { _ in Issue.record("Empty clip emitted a frame") }).isFinished)
    guard case .analyzed(let emptyResult) = empty.completion else {
        Issue.record("Missing empty result")
        return
    }
    #expect(emptyResult.observedSource.sampleCount == 0)
    #expect(emptyResult.cpps?.unavailability == .insufficientData)
}

@Test func schedulingBatchFailureAndCancellationCannotAffectLaterInputs() throws {
    let url = try schedulingWAV(Array(repeating: 8192, count: 1600), rate: 16000, channels: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    let profile = try fileScheduleProfile(
        precision: .float64, layout: .interleaved, rate: 16000, channels: 1)
    let origin = try fileScheduleOrigin(start: 0, rate: 16000)
    let good = AudioFileScheduleInput(url: url, profile: profile, origin: origin)
    let missing = AudioFileScheduleInput(
        url: url.appendingPathExtension("missing"), profile: profile, origin: origin)
    var results: [AudioFileBatchResult] = []
    var byInput: [Int: [ScheduledFrame]] = [:]
    let report = AudioFileAnalysisBatch.run(
        Double.self, inputs: [good, missing, good, good],
        chunkCapacity: 173, sourceTileCapacity: 64,
        control: {
            $0.inputIndex == 0 && $0.nextSourceSample >= 173 ? .cancelInput : .proceed
        }, emit: { byInput[$0, default: []].append($1.frame) },
        inputCompleted: { _, result in results.append(result) })
    #expect(report.successfulInputs == 2)
    #expect(report.failedInputs == 1)
    #expect(report.cancelledInputs == 1)
    #expect(results.count == 4)
    guard case .analyzed(_, .cancelled(let observed, let coverage)) = results[0] else {
        Issue.record("Expected first-input cancellation")
        return
    }
    #expect(observed.sampleCount == 173)
    #expect(coverage.eligible == 173)
    guard case .failed(let failure) = results[1] else {
        Issue.record("Expected missing-file failure")
        return
    }
    #expect(failure.stage == .preparation)
    #expect(byInput[2] == byInput[3])
    #expect(byInput[2]?.isEmpty == false)
    let stop = AudioFileAnalysisBatch.run(
        Double.self, inputs: [good, missing, good],
        control: { _ in .cancelBatch }, emit: { _, _ in Issue.record("Cancelled batch emitted") },
        inputCompleted: { _, result in
            guard case .cancelledBeforePreparation = result else {
                Issue.record("Batch opened a cancelled input")
                return
            }
        })
    #expect(stop.cancelledInputs == 3)
    #expect(stop.failedInputs == 0)
}

@Test func schedulingFileCallbackCancellationRetainsBorrowAndRejectsReentry() throws {
    let url = try schedulingWAV(Array(repeating: 8192, count: 1600), rate: 16000, channels: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    let worker = try PreparedAudioFileSchedule<Double>(
        url: url,
        profile: fileScheduleProfile(
            precision: .float64, layout: .planar, rate: 16000, channels: 1),
        origin: fileScheduleOrigin(start: 0, rate: 16000), chunkCapacity: 512,
        sourceTileCapacity: 64)
    var calls = 0
    let progress = try worker.read { frame in
        calls += 1
        #expect(throws: AnalysisScheduleError.reentrantCall) { try worker.read { _ in } }
        worker.cancel()
        #expect(frame.frame.timing.source.sampleCount > 0)
    }
    #expect(calls == 1)
    #expect(progress.isCancelled)
    #expect(progress.decodedSampleCount == 512)
    #expect(progress.advancedSourceSamples == 448)
    guard case .cancelled(let source, _) = worker.completion else {
        Issue.record("Missing cancellation")
        return
    }
    #expect(source.sampleCount == 448)
}
