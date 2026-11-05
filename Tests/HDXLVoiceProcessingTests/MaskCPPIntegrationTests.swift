import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func maskCPP(
    _ pcm: [Double], timeline: MaskTimeline, scope: MaskAnalysisScope, chunk: Int
) throws -> [CPPFrameResult] {
    let source = timeline.plan.source
    let configuration = try CepstrogramConfiguration(
        sourceSampleRate: Int(source.sampleRate),
        inputPrecision: .float64, hopSeconds: 0.01, declaredInputBandwidthHz: source.sampleRate / 2)
    let consumer = try PreparedCPP(
        CPPProfile(cepstrogram: configuration, settings: CPPConfiguration.murtonRecipePraat7()))
    let cursor = PreparedMaskCursor<Double>(timeline: timeline, scope: scope)
    var worker: PreparedIntervalCepstrogram<Double>?
    var rows: [CPPFrameResult] = []
    var callbackError: (any Error)?
    try pcm.withUnsafeBufferPointer { input in
        for start in stride(from: 0, to: pcm.count, by: chunk) {
            let end = min(pcm.count, start + chunk)
            let interval = try SourceInterval(
                epoch: source.epoch, startSample: source.startSample + Int64(start),
                sampleCount: Int64(end - start), sampleRate: source.sampleRate)
            try cursor.process(
                UnsafeBufferPointer(rebasing: input[start..<end]), interval: interval
            ) { samples, context in
                do {
                    if context.startsRegion {
                        if let existing = worker,
                            existing.source.sampleCount == context.region.sampleCount
                        {
                            try existing.reset(source: context.region)
                        } else {
                            worker = try PreparedIntervalCepstrogram(
                                configuration: configuration, source: context.region)
                        }
                    }
                    let active = try #require(worker)
                    try active.append(samples, interval: context.source)
                    if context.endsRegion {
                        try active.finish { frame in
                            do {
                                #expect(frame.context.timing.source == context.region)
                                let membership =
                                    try scope == .selected
                                    ? timeline.selectedRegion(
                                        containing: frame.context.timing.source)
                                    : timeline.eligibleRegion(
                                        containing: frame.context.timing.source)
                                #expect(membership == context.regionIndex)
                                try consumer.analyze(frame) { rows.append($0.result) }
                            } catch { callbackError = error }
                        }
                    }
                } catch { callbackError = error }
            }
            if let callbackError { throw callbackError }
        }
    }
    return rows
}

@Test func maskSelectionReportsInflatedCPPAlongsideLostCoverageAndOriginalRegions() throws {
    let rate = 16000
    let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000003435")!)
    let origin: Int64 = (1 << 54) + 34
    func interval(_ start: Int, _ count: Int) throws -> SourceInterval {
        try SourceInterval(
            epoch: epoch, startSample: origin + Int64(start), sampleCount: Int64(count),
            sampleRate: Double(rate))
    }
    var state: UInt32 = 34
    let pcm = (0..<(4 * rate)).map { index -> Double in
        state = 1_664_525 &* state &+ 1_013_904_223
        let noise = (Double(state) - 2_147_483_648) / 21_474_836_480
        let phase = 2 * Double.pi * 125 * Double(index) / Double(rate)
        if (index / rate) % 2 != 0 { return noise }
        var voice = noise * 0.01
        for harmonic in 1...12 { voice += 0.15 * sin(Double(harmonic) * phase) / Double(harmonic) }
        return voice
    }
    let provenance = try MaskProvenance(
        kind: .externalAnnotation,
        identifier: VersionedIdentifier(name: "synthetic-harmonics-and-noise-intervals", version: 1)
    )
    let plan = try MaskPlan(
        source: interval(0, pcm.count), provenances: [provenance],
        policy: MaskSelectionPolicy(selectionSources: [0]),
        observations: [
            MaskObservation(
                source: interval(0, rate), provenanceIndex: 0, selection: .selected,
                tags: [.speechDetected]),
            MaskObservation(
                source: interval(2 * rate, rate), provenanceIndex: 0, selection: .selected,
                tags: [.speechDetected]),
            MaskObservation(
                source: interval(rate, rate), provenanceIndex: 0, selection: .rejected,
                tags: [.lowPeriodicityConfidence]),
            MaskObservation(
                source: interval(3 * rate, rate), provenanceIndex: 0, selection: .rejected,
                tags: [.lowPeriodicityConfidence]),
            MaskObservation(
                source: interval(19 * rate / 10, rate / 10), provenanceIndex: 0,
                tags: [.missingAcquisition]),
        ])
    let timeline = try MaskTimeline(plan)
    let all = try maskCPP(pcm, timeline: timeline, scope: .allEligible, chunk: 1024)
    let selected = try maskCPP(pcm, timeline: timeline, scope: .selected, chunk: 64)
    #expect(try selected == maskCPP(pcm, timeline: timeline, scope: .selected, chunk: 1024))
    let rawValues = all.compactMap { $0.observation?.prominenceDB }
    let selectedValues = selected.compactMap { $0.observation?.prominenceDB }
    #expect(!rawValues.isEmpty && !selectedValues.isEmpty)
    let rawMean = rawValues.reduce(0, +) / Double(rawValues.count)
    let selectedMean = selectedValues.reduce(0, +) / Double(selectedValues.count)
    #expect(selectedMean > rawMean + 1)
    #expect(timeline.coverage.sourceCoverage == 0.5)
    #expect(timeline.coverage.eligibleCoverage == 32000.0 / 62400)
    #expect(timeline.coverage.missingSampleCount == 1600)
    #expect(
        all.contains { row in
            row.context.timing.source.startSample < origin + Int64(rate)
                && row.context.timing.source.endSample > origin + Int64(rate)
        })
    // Independently prepared selected regions reproduce the routed outputs, including
    // the second region that reuses the first region's worker through reset.
    for region in timeline.selectedRegions {
        let offset = Int(region.startSample - origin)
        let isolatedPlan = try MaskPlan(
            source: region, provenances: [], policy: MaskSelectionPolicy(), observations: [])
        let isolated = try maskCPP(
            Array(pcm[offset..<(offset + Int(region.sampleCount))]),
            timeline: MaskTimeline(isolatedPlan), scope: .allEligible, chunk: 137)
        #expect(selected.filter { $0.context.origin.startSample == region.startSample } == isolated)
    }
    if let path = ProcessInfo.processInfo.environment["HDXL_MASK_CPP_REPORT"] {
        let report: [String: Any] = [
            "schemaVersion": 1, "case": "original-harmonics-and-noise-intervals",
            "inputFloat64SHA256": pcm.withUnsafeBytes {
                SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined()
            },
            "rawFrameCount": rawValues.count, "selectedFrameCount": selectedValues.count,
            "rawMeanCPPDB": rawMean, "selectedMeanCPPDB": selectedMean,
            "sourceCoverage": timeline.coverage.sourceCoverage,
            "eligibleCoverage": timeline.coverage.eligibleCoverage,
            "missingSamples": timeline.coverage.missingSampleCount,
            "interpretation":
                "Illustrative selection bias, not a clinical or phonation label. Each contiguous region is conditioned independently; the two means have different conditioning contexts.",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: path))
    }
}

@Test func maskSeparatedShortRegionsNeverMakeSyntheticCPPFrameAndEmptySelectionHasNoRows() throws {
    let epoch = StreamEpoch(streamID: UUID())
    func interval(_ start: Int64, _ count: Int64) throws -> SourceInterval {
        try SourceInterval(epoch: epoch, startSample: start, sampleCount: count, sampleRate: 16000)
    }
    let provenance = try MaskProvenance(
        kind: .externalAnnotation,
        identifier: VersionedIdentifier(name: "short-regions", version: 1))
    let plan = try MaskPlan(
        source: interval(0, 3200), provenances: [provenance],
        policy: MaskSelectionPolicy(selectionSources: [0]),
        observations: [
            MaskObservation(source: interval(0, 1280), provenanceIndex: 0, selection: .selected),
            MaskObservation(source: interval(1920, 1280), provenanceIndex: 0, selection: .selected),
        ])
    let pcm = (0..<3200).map { 0.2 * sin(Double($0) * 0.05) }
    let rows = try maskCPP(pcm, timeline: MaskTimeline(plan), scope: .selected, chunk: 1024)
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.observation == nil && $0.unavailability == .insufficientData })
    let empty = try MaskTimeline(
        MaskPlan(
            source: plan.source, provenances: [provenance], policy: plan.policy, observations: []))
    #expect(empty.coverage.sourceCoverage == 0)
    #expect(try maskCPP(pcm, timeline: empty, scope: .selected, chunk: 64).isEmpty)
    #expect(
        try maskCPP(pcm, timeline: empty, scope: .allEligible, chunk: 64).contains {
            $0.observation != nil
        })
}
