import Darwin
import Foundation
import HDXLVoiceProcessing

public struct ContinuityReceipt: Encodable, Sendable {
    public let schedule: ProfileIdentity
    public let observedSamples: Int
    public let observedFrames: Int
    public let preparedBufferBytes: Int
    public let heapSamples: [HeapSample]
    public let allowedWarmHeapRangeBytes: Int
    public let gaps: [Int]
    public let rejectedInputs: [String]
    public let routeSampleRate: Int
    public let routeSchedule: ProfileIdentity
}

public struct HeapSample: Encodable, Sendable {
    let sourceSamples: Int
    let bytesInUse: Int
}

/// A finite observation log is used for the short post-gap comparison. The sustained
/// worker retains only counters and one reusable PCM block, regardless of run length.
public func verifySuiteContinuity(
    fixture: SuiteFixture, routeFixture: SuiteFixture, directory: URL
) throws -> ContinuityReceipt {
    let profile = try fixture.loadInput(in: directory, composition: .full).recipe.schedule
    let route = try routeFixture.loadInput(in: directory, composition: .full).recipe.schedule
    guard profile.inputPrecision == route.inputPrecision,
        profile.inputFormat.sampleRate != route.inputFormat.sampleRate
    else {
        throw SuiteError.invalidInput("Expected distinct routes with matching sample precision")
    }
    if profile.inputPrecision == .float32 { return try verify(Float.self, profile, route) }
    return try verify(Double.self, profile, route)
}

private func verify<S: BinaryFloatingPoint & Sendable>(
    _ sampleType: S.Type, _ profile: AnalysisScheduleProfile, _ route: AnalysisScheduleProfile
) throws -> ContinuityReceipt {
    let rate = Int(profile.inputFormat.sampleRate)
    let stream = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000061")!)
    func origin(_ acquisition: StreamEpoch, _ continuity: StreamEpoch, _ start: Int64, _ hz: Int)
        throws
        -> AnalysisScheduleOrigin
    {
        try AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: acquisition, startSample: start, sampleCount: 0, sampleRate: Double(hz)),
            continuityEpoch: continuity)
    }
    func append(
        _ pcm: [S], to worker: PreparedAnalysisSchedule<S>,
        at start: Int64, epoch: StreamEpoch, rate: Int,
        emit: (ScheduledFrame) -> Void
    ) throws {
        let source = try SourceInterval(
            epoch: epoch, startSample: start, sampleCount: Int64(pcm.count),
            sampleRate: Double(rate))
        try pcm.withUnsafeBufferPointer { input in
            _ = try worker.processInterleaved(input, interval: source, emit: emit)
        }
    }
    let first = try origin(stream, stream, 0, rate)
    let worker = try PreparedAnalysisSchedule<S>(profile: profile, origin: first, mode: .continuous)
    let bytes = worker.preparedBufferBytes
    let blockSize = 256
    let block = (0..<blockSize).map { S(0.25 * sin(2 * Double.pi * Double($0) / 128)) }
    let iterations = (60 * rate + blockSize - 1) / blockSize
    var observed = 0
    var heapSamples: [HeapSample] = []
    heapSamples.reserveCapacity(6)
    for i in 0..<iterations {
        try append(block, to: worker, at: Int64(i * blockSize), epoch: stream, rate: rate) { _ in
            observed += 1
        }
        guard worker.preparedBufferBytes == bytes else {
            throw SuiteError.mismatch("Growing prepared storage")
        }
        let consumed = (i + 1) * blockSize
        if consumed >= (heapSamples.count + 1) * 10 * rate {
            var statistics = malloc_statistics_t()
            malloc_zone_statistics(nil, &statistics)
            heapSamples.append(
                HeapSample(sourceSamples: consumed, bytesInUse: statistics.size_in_use))
        }
    }
    let heapSlack = 256 * 1024
    let warmHeap = heapSamples.map(\.bytesInUse)
    guard warmHeap.count == 6, let minimum = warmHeap.min(), minimum > 0,
        let maximum = warmHeap.max(),
        maximum - minimum <= heapSlack
    else {
        throw SuiteError.mismatch(
            "Warm live heap exceeded bounded variation: " + String(describing: warmHeap))
    }
    let received = Int64(iterations * blockSize)
    guard observed > 0, worker.receivedSampleCount == received else {
        throw SuiteError.mismatch("Empty sustained run")
    }

    func requireRejection(_ expected: AnalysisScheduleError, _ action: () throws -> Void) throws {
        do { try action() } catch let error as AnalysisScheduleError where error == expected {
            return
        }
        throw SuiteError.mismatch("Expected rejection: " + String(describing: expected))
    }
    var invalidEmissions = 0
    for invalid in [S.nan, S.infinity] {
        try requireRejection(.invalidInput) {
            try append([S.zero, invalid], to: worker, at: received, epoch: stream, rate: rate) {
                _ in invalidEmissions += 1
            }
        }
    }
    try requireRejection(.unexpectedInput) {
        try append(block, to: worker, at: received + 1, epoch: stream, rate: rate) { _ in
            invalidEmissions += 1
        }
    }
    let nextRoute = try stream.successor()
    try requireRejection(.unexpectedInput) {
        try append(
            block, to: worker, at: received, epoch: stream, rate: Int(route.inputFormat.sampleRate)
        ) { _ in invalidEmissions += 1 }
    }
    try requireRejection(.unexpectedInput) {
        try append(block, to: worker, at: received, epoch: nextRoute, rate: rate) { _ in
            invalidEmissions += 1
        }
    }
    guard invalidEmissions == 0, worker.receivedSampleCount == received else {
        throw SuiteError.mismatch("Rejected input advanced the worker")
    }

    let silence = [S](repeating: 0, count: 120 * rate / 1000)
    let gaps = [1, rate / 10]
    var start = received
    var continuity = stream
    for missing in gaps {
        let end = start + Int64(missing)
        continuity = try continuity.successor()
        let after = try origin(stream, continuity, end, rate)
        let gap = try SourceInterval(
            epoch: stream, startSample: start, sampleCount: Int64(missing), sampleRate: Double(rate)
        )
        let reset = try worker.reset(origin: after, reason: .droppedAudio, missingSource: gap)
        guard reset.missingSource == gap, reset.observedSource.endSample == start else {
            throw SuiteError.mismatch("Gap was silently spliced")
        }
        let fresh = try PreparedAnalysisSchedule<S>(
            profile: profile, origin: after, mode: .continuous)
        var actual: [ScheduledFrame] = []
        var expected: [ScheduledFrame] = []
        try append(silence, to: worker, at: end, epoch: stream, rate: rate) { actual.append($0) }
        try append(silence, to: fresh, at: end, epoch: stream, rate: rate) { expected.append($0) }
        let complete = try worker.finish { actual.append($0) }
        let independent = try fresh.finish { expected.append($0) }
        let repeated = try worker.finish { _ in invalidEmissions += 1 }
        guard !actual.isEmpty, actual == expected, complete == independent, repeated == complete,
            invalidEmissions == 0,
            actual.allSatisfy({
                $0.origin.continuityEpoch == continuity && $0.timing.source.startSample >= end
            }),
            worker.preparedBufferBytes == bytes
        else { throw SuiteError.mismatch("History or final edge crossed a gap") }
        start = end + Int64(silence.count)
    }
    let hz = Int(route.inputFormat.sampleRate)
    let switched = try PreparedAnalysisSchedule<S>(
        profile: route, origin: origin(nextRoute, nextRoute, 0, hz),
        mode: .finite, expectedSampleCount: Int64(hz / 8))
    var routeFrames: [ScheduledFrame] = []
    try append([S](repeating: 0, count: hz / 8), to: switched, at: 0, epoch: nextRoute, rate: hz) {
        routeFrames.append($0)
    }
    let routeEnd = try switched.finish { routeFrames.append($0) }
    let routeID = try route.identity()
    guard routeEnd.observedSource.sampleRate == Double(hz),
        routeEnd.observedSource.epoch == nextRoute,
        !routeFrames.isEmpty,
        routeFrames.allSatisfy({ $0.schedule == routeID && $0.origin.continuityEpoch == nextRoute })
    else { throw SuiteError.mismatch("Route or profile identity was lost") }
    return try ContinuityReceipt(
        schedule: profile.identity(), observedSamples: Int(received), observedFrames: observed,
        preparedBufferBytes: bytes, heapSamples: heapSamples, allowedWarmHeapRangeBytes: heapSlack,
        gaps: gaps,
        rejectedInputs: [
            "nan", "infinity", "unannounced-gap", "unannounced-sample-rate", "unannounced-epoch",
        ],
        routeSampleRate: hz, routeSchedule: routeID)
}
