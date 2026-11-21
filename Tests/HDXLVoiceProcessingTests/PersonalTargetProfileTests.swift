import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct TargetProfileReference: Decodable {
    struct Case: Decodable {
        let name, sourcePath, sourceSHA256: String
        let sampleCount: Int
        let boundary: Bool
        let expected: [String: [Double?]]
        let pitchStatus: [YINVoicingStatus]
    }
    let schemaVersion: Int
    let definition: String
    let yinProfile: YINConfiguration
    let comparisonBudgetsAbsolute: [String: Double]
    let cases: [Case]
}

func targetReferenceProfile() throws -> AnalysisScheduleProfile {
    try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: PCMChannelSelection(channelIndex: 0),
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64, windowLength: 400, hopLength: 160,
            accumulation: .compensatedSliding, weighting: .none),
        pitch: YINProfile(
            estimator: YINConfiguration(
                sampleRate: 16000, inputPrecision: .float64, pitchFloorHz: 50,
                pitchCeilingHz: 700, hopLength: 160, differenceBackend: .fft)),
        cpps: .murtonRecipePraat7(sourceSampleRate: 16000, declaredInputBandwidthHz: 8000))
}

private func targetProfileFrames(
    samples: [Double], profile: AnalysisScheduleProfile, chunks: [Int]
) throws -> [ScheduledFrame] {
    let start: Int64 = (1 << 54) + 53
    let epoch = StreamEpoch(streamID: calibrationTestID(53))
    let origin = try AnalysisScheduleOrigin(
        source: SourceInterval(epoch: epoch, startSample: start, sampleCount: 0, sampleRate: 16000),
        continuityEpoch: epoch)
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .finite,
        expectedSampleCount: Int64(samples.count), sourceTileCapacity: 137)
    var result: [ScheduledFrame] = []
    var offset = 0
    var index = 0
    try samples.withUnsafeBufferPointer { input in
        while offset < input.count {
            let count = min(chunks[index % chunks.count], input.count - offset)
            let interval = try SourceInterval(
                epoch: epoch, startSample: start + Int64(offset), sampleCount: Int64(count),
                sampleRate: 16000)
            _ = try worker.processInterleaved(
                UnsafeBufferPointer(rebasing: input[offset..<offset + count]), interval: interval
            ) { result.append($0) }
            offset += count
            index += 1
        }
    }
    let completion = try worker.finish { result.append($0) }
    try #require(completion.observedSource.sampleCount == samples.count)
    try #require(completion.observedSource.startSample == start)
    try #require(
        try worker.finish { _ in Issue.record("Repeated finish emitted a frame") } == completion)
    if samples.count < 1600 {
        try #require(completion.cpps?.meanDB == nil)
        try #require(completion.cpps?.unavailability == .insufficientData)
    }
    return result
}

private func targetProfileMetric(_ frame: ScheduledFrame) -> ScheduledMetric {
    switch frame.value {
    case .levels: .levelDBFS
    case .pitch: .fundamentalFrequency
    case .swipePrime: .fundamentalFrequency
    case .cpps: .cpps
    case .hnr: .harmonicToNoiseRatio
    }
}

@Test func personalTargetExactProfileMatchesIndependentReferencesAndChunkBoundaries() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtureURL =
        ProcessInfo.processInfo.environment["HDXL_PERSONAL_TARGET_REFERENCE"].map {
            URL(fileURLWithPath: $0)
        }
        ?? root.appending(
            path:
                "Tests/HDXLVoiceProcessingTests/Fixtures/PersonalTargets/Profile/profile-reference.json"
        )
    let bytes = try Data(contentsOf: fixtureURL)
    let reference = try JSONDecoder().decode(TargetProfileReference.self, from: bytes)
    try #require(reference.schemaVersion == 1)
    try #require(
        reference.definition == "personal-target-offline-16k-murton7-yin50to700-level25ms-v1")
    try #require(reference.cases.count == 14)
    try #require(reference.cases.filter(\.boundary).count == 10)
    try #require(
        reference.comparisonBudgetsAbsolute == [
            "cpps": 1e-4, "fundamentalFrequency": 0.001, "levelDBFS": 1e-10,
        ])
    let profile = try targetReferenceProfile()
    try #require(profile.pitch?.estimator == reference.yinProfile)
    var reports: [[String: Any]] = []
    for item in reference.cases {
        let data = try Data(contentsOf: root.appending(path: item.sourcePath))
        try #require(CalibrationDigest(bytes: data).sha256 == item.sourceSHA256)
        let pcm = try CorpusPCM(data: data)
        try #require(pcm.sampleRate == 16000 && pcm.samples.count >= item.sampleCount)
        let samples = Array(pcm.samples.prefix(item.sampleCount))
        let baseline = try targetProfileFrames(
            samples: samples, profile: profile, chunks: [max(1, samples.count)])
        var comparisons = 0
        for chunks in [[1], [7, 131, 2, 509, 3, 64], [137, 1023, 31, 5]] {
            let chunked = try targetProfileFrames(
                samples: samples, profile: profile, chunks: chunks)
            try #require(chunked == baseline, "\(item.name) complete frame and boundary metadata")
            comparisons += 1
        }
        let pitchStatus = baseline.compactMap { frame -> YINVoicingStatus? in
            if case .pitch(let raw, _) = frame.value { return raw.status }
            return nil
        }
        try #require(pitchStatus == item.pitchStatus)
        var metricReports: [String: Any] = [:]
        for metric in [ScheduledMetric.cpps, .fundamentalFrequency, .levelDBFS] {
            let frames = baseline.filter { targetProfileMetric($0) == metric }
            let expected = try #require(item.expected[metric.rawValue])
            let budget = try #require(reference.comparisonBudgetsAbsolute[metric.rawValue])
            try #require(frames.count == expected.count, "\(item.name) \(metric)")
            var maximum = 0.0
            var available = 0
            var nativeValues: [Double] = []
            for (frame, wanted) in zip(frames, expected) {
                let outcome = try frame.measurementResult(metric).outcome
                if let wanted {
                    let actual = try #require(outcome.estimate?.value)
                    let fraction = abs(actual - wanted) / budget
                    maximum = max(maximum, fraction)
                    try #require(fraction <= 1, "\(item.name) \(metric) error/budget=\(fraction)")
                    available += 1
                    nativeValues.append(actual)
                } else {
                    try #require(outcome.estimate == nil, "\(item.name) \(metric) invented value")
                }
            }
            let expectedValues = expected.compactMap { $0 }.sorted()
            if !expectedValues.isEmpty {
                let expectedMedian = expectedValues[(expectedValues.count - 1) / 2]
                let nativeMedian = try PersonalTargetDistribution(nativeValues).median
                try #require(abs(nativeMedian - expectedMedian) <= budget)
            }
            metricReports[metric.rawValue] = [
                "frames": frames.count, "available": available,
                "maximumErrorToBudget": maximum, "absoluteBudget": budget,
            ]
        }
        reports.append([
            "name": item.name, "sampleCount": item.sampleCount, "boundary": item.boundary,
            "chunkComparisons": comparisons, "chunkMaximumErrorToBudget": 0,
            "metrics": metricReports,
        ])
    }
    if let path = ProcessInfo.processInfo.environment["HDXL_PERSONAL_TARGET_PROFILE_REPORT"] {
        let profileObject = try JSONSerialization.jsonObject(with: canonicalContractJSON(profile))
        let identityObject = try JSONSerialization.jsonObject(
            with: canonicalContractJSON(profile.identity()))
        let implementationObject = try JSONSerialization.jsonObject(
            with: canonicalContractJSON(CalibrationAnalysisKey.currentImplementation))
        let report: [String: Any] = [
            "schemaVersion": 1, "status": "passed", "definition": reference.definition,
            "profile": profileObject, "profileIdentity": identityObject,
            "analysisImplementation": implementationObject,
            "referenceSHA256": CalibrationDigest(bytes: bytes).sha256,
            "cases": reports, "physicalDeviceEvidence": false,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
