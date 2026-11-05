import Foundation
import Testing

@testable import HDXLVoiceProcessing

private let maskEpoch = StreamEpoch(
    streamID: UUID(uuidString: "cd4af9b8-b5a3-4d1a-bd4b-ab505942d824")!)

private func maskInterval(_ start: Int64, _ count: Int64, rate: Double = 16_000) throws
    -> SourceInterval
{
    try SourceInterval(epoch: maskEpoch, startSample: start, sampleCount: count, sampleRate: rate)
}

private func maskProvenance(_ name: String = "test-annotation") throws -> MaskProvenance {
    try MaskProvenance(
        kind: .externalAnnotation, identifier: VersionedIdentifier(name: name, version: 1))
}

@Test func maskSweepMatchesIndependentPerSampleOracleWithOverlaps() throws {
    var seed: UInt64 = 34
    func random(_ limit: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return Int((seed >> 32) % UInt64(limit))
    }
    let sources = try [maskProvenance("a"), maskProvenance("b"), maskProvenance("c")]
    for trial in 0..<40 {
        let origin: Int64 = trial.isMultiple(of: 2) ? 0 : 9_007_199_254_740_993
        let whole = try maskInterval(origin, 67)
        var observations: [MaskObservation] = []
        for _ in 0..<23 {
            let start = random(67)
            let length = 1 + random(67 - start)
            observations.append(
                try MaskObservation(
                    source: maskInterval(origin + Int64(start), Int64(length)),
                    provenanceIndex: random(3),
                    selection: [MaskSelectionVote.selected, .rejected, .unspecified][random(3)],
                    tags: [MaskTag.allCases[random(MaskTag.allCases.count)]]))
        }
        for required in [[], [0], [0, 2], [0, 1, 2]] {
            for combination in [MaskSourceCombination.all, .any] {
                let policy = try MaskSelectionPolicy(
                    selectionSources: required, combination: combination,
                    rejectedTags: [.suspectedExternalNoise])
                let timeline = try MaskTimeline(
                    MaskPlan(
                        source: whole, provenances: sources,
                        policy: policy, observations: observations.reversed()))
                var eligibleTotal: Int64 = 0
                var selectedTotal: Int64 = 0
                var tagCounts: [MaskTag: Int64] = [:]
                for sample in origin..<whole.endSample {
                    let covering = observations.filter {
                        $0.source.startSample <= sample && sample < $0.source.endSample
                    }
                    let tags = Set(covering.flatMap(\.tags))
                    let eligible = !tags.contains(.missingAcquisition)
                    let votes = required.map { index in
                        let sourceVotes = covering.filter { $0.provenanceIndex == index }.map(
                            \.selection)
                        return sourceVotes.contains(.selected) && !sourceVotes.contains(.rejected)
                    }
                    let selection =
                        required.isEmpty
                        || (combination == .all ? votes.allSatisfy { $0 } : votes.contains(true))
                    let selected = eligible && selection && !tags.contains(.suspectedExternalNoise)
                    let part = try #require(
                        timeline.segments.first {
                            $0.source.startSample <= sample && sample < $0.source.endSample
                        })
                    #expect(part.isEligible == eligible)
                    #expect(part.isSelected == selected)
                    #expect(Set(part.tags) == tags)
                    if eligible { eligibleTotal += 1 }
                    if selected { selectedTotal += 1 }
                    for tag in tags { tagCounts[tag, default: 0] += 1 }
                }
                #expect(timeline.coverage.eligibleSampleCount == eligibleTotal)
                #expect(timeline.coverage.selectedSampleCount == selectedTotal)
                #expect(
                    timeline.coverage.excludedEligibleSampleCount + selectedTotal == eligibleTotal)
                #expect(timeline.coverage.missingSampleCount + eligibleTotal == 67)
                #expect(timeline.selectedRegions.reduce(0) { $0 + $1.sampleCount } == selectedTotal)
                #expect(timeline.eligibleRegions.reduce(0) { $0 + $1.sampleCount } == eligibleTotal)
                for coverage in timeline.coverage.tags {
                    #expect(coverage.sampleCount == tagCounts[coverage.tag, default: 0])
                }
                for pair in zip(timeline.segments, timeline.segments.dropFirst()) {
                    #expect(pair.0.source.endSample == pair.1.source.startSample)
                }
            }
        }
    }
}

@Test func maskSelectionDoesNotImplicitlyDiscardLowPeriodicityClippingOrNoise() throws {
    let source = try maskInterval(100, 100)
    let diagnostics = try MaskObservation(
        source: source, provenanceIndex: 0,
        tags: [.clipping, .lowPeriodicityConfidence, .suspectedExternalNoise])
    let raw = try MaskTimeline(
        MaskPlan(
            source: source, provenances: [maskProvenance()],
            policy: MaskSelectionPolicy(), observations: [diagnostics]))
    #expect(raw.coverage.selectedSampleCount == 100)
    #expect(raw.selectedRegions == [source])
    #expect(
        raw.coverage.tags.first { $0.tag == .lowPeriodicityConfidence }?.selectedSampleCount == 100)
    let empty = try MaskTimeline(
        MaskPlan(
            source: source, provenances: [maskProvenance()],
            policy: MaskSelectionPolicy(selectionSources: [0]), observations: [diagnostics]))
    #expect(empty.coverage.selectedSampleCount == 0)
    #expect(empty.coverage.sourceCoverage == 0)
    #expect(empty.selectedRegions.isEmpty)
    #expect(empty.segments[0].exclusions == [.sourceUnspecified])
    #expect(try empty.selectedRegion(containing: source) == nil)
    let zero = try MaskTimeline(
        MaskPlan(
            source: maskInterval(100, 0), provenances: [],
            policy: MaskSelectionPolicy(), observations: []))
    #expect(zero.coverage.sourceCoverage == 0)
    #expect(zero.coverage.eligibleCoverage == 0)
    #expect(zero.segments.isEmpty)
}

@Test func maskProvenanceAndInputContractsRoundTripAndRejectUnknownFields() throws {
    let identifier = try VersionedIdentifier(name: "consumer-vad", version: 1)
    let learned = try MaskProvenance(
        kind: .consumerLearnedSpeechActivity, identifier: identifier,
        parameters: ["threshold": .real(0.4)], modelName: "Example", modelVersion: "2.0")
    let changed = try MaskProvenance(
        kind: .consumerLearnedSpeechActivity, identifier: identifier,
        parameters: ["threshold": .real(0.4)], modelName: "Example", modelVersion: "2.1")
    #expect(try learned.identity() != changed.identity())
    #expect(throws: MaskError.invalidConfiguration) {
        try MaskProvenance(kind: .consumerLearnedSpeechActivity, identifier: identifier)
    }
    #expect(throws: MaskError.invalidConfiguration) {
        try MaskProvenance(
            kind: .externalAnnotation, identifier: identifier, modelName: "Example",
            modelVersion: "2.0")
    }
    let source = try maskInterval(0, 100)
    let plan = try MaskPlan(
        source: source, provenances: [learned], policy: MaskSelectionPolicy(selectionSources: [0]),
        observations: [
            MaskObservation(
                source: source, provenanceIndex: 0, selection: .selected,
                tags: [.speechDetected, .speechDetected])
        ])
    let bytes = try plan.canonicalJSON()
    #expect(try JSONDecoder().decode(MaskPlan.self, from: bytes) == plan)
    var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    json["unrecognized"] = true
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(MaskPlan.self, from: JSONSerialization.data(withJSONObject: json))
    }
    json.removeValue(forKey: "unrecognized")
    var entries = try #require(json["observations"] as? [[String: Any]])
    entries[0]["provenanceIndex"] = 1
    json["observations"] = entries
    #expect(throws: MaskError.invalidObservation) {
        try JSONDecoder().decode(MaskPlan.self, from: JSONSerialization.data(withJSONObject: json))
    }
    let export = try #require(
        JSONSerialization.jsonObject(with: MaskTimeline(plan).canonicalJSON()) as? [String: Any])
    let coverage = try #require(export["coverage"] as? [String: Any])
    #expect(coverage["selectedDurationSeconds"] as? Double == 100.0 / 16_000)
}

@Test func maskCursorPreservesRegionsAcrossChunkingAndAcquisitionGaps() throws {
    let source = try maskInterval(10, 30)
    let observations = try [
        MaskObservation(source: maskInterval(10, 9), provenanceIndex: 0, selection: .selected),
        MaskObservation(source: maskInterval(21, 12), provenanceIndex: 0, selection: .selected),
        MaskObservation(
            source: maskInterval(25, 3), provenanceIndex: 0, tags: [.missingAcquisition]),
    ]
    let timeline = try MaskTimeline(
        MaskPlan(
            source: source, provenances: [maskProvenance()],
            policy: MaskSelectionPolicy(selectionSources: [0]), observations: observations))
    #expect(timeline.selectedRegions.map(\.startSample) == [10, 21, 28])
    #expect(try timeline.selectedRegion(containing: maskInterval(18, 4)) == nil)
    #expect(try timeline.eligibleRegion(containing: maskInterval(18, 4)) == 0)
    #expect(try timeline.eligibleRegion(containing: maskInterval(24, 5)) == nil)
    for scope in [MaskAnalysisScope.selected, .allEligible] {
        let expected = scope == .selected ? timeline.selectedRegions : timeline.eligibleRegions
        for chunkSize in [1, 2, 7, 64, 1024] {
            let cursor = PreparedMaskCursor<Double>(timeline: timeline, scope: scope)
            var seen = [[Double]](repeating: [], count: expected.count)
            var starts: [Int64] = []
            var ends: [Int64] = []
            for block in [10..<25, 28..<40] {
                var start = block.lowerBound
                while start < block.upperBound {
                    let count = min(chunkSize, block.upperBound - start)
                    let pcm = (start..<(start + count)).map(Double.init)
                    try pcm.withUnsafeBufferPointer {
                        let report = try cursor.process(
                            $0, interval: maskInterval(Int64(start), Int64(count))
                        ) { values, context in
                            seen[context.regionIndex].append(contentsOf: values)
                            if context.startsRegion { starts.append(context.source.startSample) }
                            if context.endsRegion { ends.append(context.source.endSample) }
                        }
                        #expect(report.consumedSampleCount == count)
                    }
                    start += count
                }
                if block.upperBound == 25 { try cursor.skipMissingAcquisition(maskInterval(25, 3)) }
            }
            #expect(starts == expected.map(\.startSample))
            #expect(ends == expected.map(\.endSample))
            #expect(seen == expected.map { ($0.startSample..<$0.endSample).map(Double.init) })
            #expect(cursor.nextInputSample == 40)
        }
    }
}

@Test func maskCursorRejectsInvalidInputAtomicallyAndSupportsCancellationAndReplay() throws {
    let source = try maskInterval(0, 20)
    let timeline = try MaskTimeline(
        MaskPlan(
            source: source, provenances: [maskProvenance()],
            policy: MaskSelectionPolicy(selectionSources: [0]),
            observations: [
                MaskObservation(
                    source: maskInterval(2, 3), provenanceIndex: 0, selection: .selected),
                MaskObservation(
                    source: maskInterval(8, 5), provenanceIndex: 0, selection: .selected),
            ]))
    let cursor = PreparedMaskCursor<Double>(timeline: timeline, scope: .selected)
    #expect(throws: MaskError.unexpectedInterval) {
        try cursor.skipMissingAcquisition(maskInterval(0, 2))
    }
    #expect(throws: MaskError.nonfiniteInput) {
        try [0.0, .nan].withUnsafeBufferPointer {
            try cursor.process($0, interval: maskInterval(0, 2)) { _, _ in
                Issue.record("Invalid input emitted")
            }
        }
    }
    #expect(cursor.nextInputSample == 0)
    let pcm = (0..<20).map(Double.init)
    try pcm.withUnsafeBufferPointer {
        let report = try cursor.process($0, interval: source) { _, context in
            #expect(context.startsRegion && context.endsRegion)
            #expect(throws: MaskError.reentrantCall) { try cursor.resetToStart() }
            cursor.cancel()
        }
        #expect(report.isCancelled)
        #expect(report.consumedSampleCount == 5)
        #expect(report.emittedSampleCount == 3)
    }
    try cursor.resetToStart()
    var delivered = 0
    _ = try pcm.withUnsafeBufferPointer {
        try cursor.process($0, interval: source) { values, _ in delivered += values.count }
    }
    #expect(delivered == 8)
    #expect(cursor.nextInputSample == 20)
}
