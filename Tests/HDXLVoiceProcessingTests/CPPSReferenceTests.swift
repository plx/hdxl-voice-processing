import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct CPPSReference: Decodable {
    struct Recipe: Decodable {
        struct Source: Decodable {
            struct Missing: Decodable { let startSample, sampleCount: Int }
            let kind: String
            let path: String?
            let startSample, sampleCount: Int?
            let missingAcquisition: Missing?
        }
        struct Settings: Decodable {
            let constructionFloorHz, hopSeconds, maximumFrequencyHz, preEmphasisFromHz: Double
            let timeWindowSeconds, quefrencyWindowSeconds, pitchTolerance: Double
            let subtractTrendBeforeSmoothing: Bool
        }
        let name: String
        let source: Source
        let profile: Settings
        let validationScope: String?
    }
    struct Input: Decodable {
        let sampleCount: Int?
        let sampleRate: Int?
    }
    struct ReferenceData: Decodable {
        struct Axes: Decodable {
            let frameCount, binCount: Int
            let firstCenterSeconds, hopSeconds, quefrencyStepSeconds: Double
        }
        let axes: Axes
        let cppsDB: Double?
        let matrixColumns: [Int]
        let matrices: [String: [Double?]]
        let metrics: [String: [[Double?]]]
    }
    let recipe: Recipe
    let input: Input
    let data: ReferenceData
    enum CodingKeys: String, CodingKey {
        case recipe = "case"
        case input, data
    }
}

private func cppsReferenceFiles(isolated: Bool) throws -> [URL] {
    let env = ProcessInfo.processInfo.environment
    let root =
        try env["HDXL_CPPS_REFERENCE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        ?? #require(
            Bundle.module.url(forResource: "CPPS", withExtension: nil, subdirectory: "Fixtures"))
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .filter { url in
            let reference = try JSONDecoder().decode(
                CPPSReference.self, from: Data(contentsOf: url))
            return (reference.recipe.source.kind == "power-object") == isolated
        }
}

private func compareCPPSReference(_ reference: CPPSReference, isolated: Bool) throws -> [String:
    Any]
{
    let data = reference.data
    let rate = isolated ? 10_000 : try #require(reference.input.sampleRate)
    let count =
        isolated
        ? 1000 + (data.axes.frameCount - 1) * 20 : try #require(reference.input.sampleCount)
    let p = reference.recipe.profile
    let characterization =
        reference.recipe.validationScope == "unmasked-acquisition-loss-characterization"
    let profile = try CPPSProfile(
        cepstrogram: CepstrogramConfiguration(
            sourceSampleRate: rate, analysisSampleRate: Int(2 * p.maximumFrequencyHz),
            pitchFloorHz: p.constructionFloorHz, hopSeconds: p.hopSeconds,
            preEmphasisFromHz: p.preEmphasisFromHz, declaredInputBandwidthHz: Double(rate) / 2),
        settings: CPPSConfiguration(
            timeWindowSeconds: p.timeWindowSeconds,
            quefrencyWindowSeconds: p.quefrencyWindowSeconds,
            subtractTrendBeforeSmoothing: p.subtractTrendBeforeSmoothing,
            pitchTolerance: p.pitchTolerance, prominence: .murtonRecipePraat7()))
    let epoch = StreamEpoch(streamID: UUID())
    let origin = try SourceInterval(
        epoch: epoch,
        startSample: 9_007_199_254_740_993 + Int64(reference.recipe.source.startSample ?? 0),
        sampleCount: 0, sampleRate: Double(rate))
    let source = try SourceInterval(
        epoch: epoch, startSample: origin.startSample,
        sampleCount: Int64(count), sampleRate: Double(rate))
    var emitted = 0
    var maximumPowerFraction = 0.0
    var maximumMetricFraction = 0.0
    var maximumRawMetricFraction = 0.0
    let lossMask: MaskTimeline?
    if let missing = reference.recipe.source.missingAcquisition {
        let provenance = try MaskProvenance(
            kind: .acquisitionDiagnostics,
            identifier: VersionedIdentifier(name: "corpus-explicit-dropout", version: 1))
        lossMask = try MaskTimeline(
            MaskPlan(
                source: source, provenances: [provenance],
                policy: MaskSelectionPolicy(),
                observations: [
                    MaskObservation(
                        source: SourceInterval(
                            epoch: epoch,
                            startSample: source.startSample + Int64(missing.startSample),
                            sampleCount: Int64(missing.sampleCount), sampleRate: Double(rate)),
                        provenanceIndex: 0, tags: [.missingAcquisition])
                ]))
    } else {
        lossMask = nil
    }
    #expect(characterization == (lossMask != nil))
    let dbBudget = isolated ? 1e-8 : 1e-4
    let slopeBudget = isolated ? 1e-6 : 0.01
    let qBudget = isolated ? 1e-12 : 1e-8
    let receive: (BorrowedCPPSOutput) -> Void = { output in
        let index = Int(output.result.context.frameIndex)
        #expect(index == emitted, "\(reference.recipe.name)")
        emitted += 1
        guard index < data.axes.frameCount else {
            Issue.record("Too many CPPS frames")
            return
        }
        #expect(output.result.context.origin == origin)
        if let lossMask {
            // Noncausal whole-input conditioning depends on the declared gap.
            // Even a frame centered outside the gap cannot be selected as though
            // it came from an independently conditioned acquired region.
            do {
                #expect(
                    try lossMask.selectedRegion(containing: output.result.context.timing.source)
                        == nil)
            } catch { Issue.record(error) }
        }
        #expect(
            abs(
                output.result.context.centerSecondsFromOrigin
                    - (data.axes.firstCenterSeconds
                        + Double(index) * data.axes.hopSeconds)) <= 1e-12)
        if isolated {
            for (stage, key) in [
                (CPPSIntermediate.rawPower, "1"), (.preparedPower, "2"), (.smoothedPower, "3"),
            ] {
                let actual = output.values(stage)
                #expect(actual.count == data.axes.binCount)
                guard actual.count == data.axes.binCount else { continue }
                for bin in actual.indices {
                    guard let expected = data.matrices[key]?[bin * data.axes.frameCount + index]
                    else {
                        Issue.record("Undefined constructed reference")
                        continue
                    }
                    let fraction = abs(actual[bin] - expected) / (1e-10 + 1e-11 * abs(expected))
                    maximumPowerFraction = max(maximumPowerFraction, fraction)
                    #expect(
                        fraction <= 1,
                        "\(reference.recipe.name) \(stage) frame \(index), bin \(bin)")
                }
            }
        }
        for (observation, stage) in [
            (output.result.rawCPP.observation, "1"), (output.result.observation, "3"),
        ] {
            let row = data.metrics[stage]![index]
            guard let expectedCPP = row[5] else {
                #expect(observation == nil)
                continue
            }
            guard let observation else {
                Issue.record("Missing native CPP: \(reference.recipe.name) frame \(index)")
                continue
            }
            let actual = [
                observation.slopeDBPerSecond, observation.interceptDB,
                observation.peakDB, observation.peakQuefrencySeconds, observation.prominenceDB,
            ]
            let expected = [row[1], row[2], row[3], row[4], expectedCPP]
            let budgets = [slopeBudget, dbBudget, dbBudget, qBudget, dbBudget]
            for i in actual.indices {
                guard let expected = expected[i] else {
                    Issue.record("Undefined metric")
                    continue
                }
                let fraction = abs(actual[i] - expected) / budgets[i]
                if stage == "1" {
                    maximumRawMetricFraction = max(maximumRawMetricFraction, fraction)
                } else {
                    maximumMetricFraction = max(maximumMetricFraction, fraction)
                }
                if isolated || (stage == "3" && !characterization) {
                    #expect(
                        fraction <= 1,
                        "\(reference.recipe.name) stage \(stage) frame \(index) metric \(i): \(actual[i]) versus \(expected)"
                    )
                }
            }
        }
    }
    let completion: CPPSCompletion
    if isolated {
        let worker = try PreparedCPPS(profile: profile, origin: origin)
        let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        for index in 0..<data.axes.frameCount {
            let input = try (0..<data.axes.binCount).map { bin in
                try #require(data.matrices["1"]?[bin * data.axes.frameCount + index])
            }
            let context = try CepstralFrameContext(
                origin: origin, timing: timing,
                frameIndex: UInt64(index), firstAnalysisSampleIndex: Int64(index * 20),
                suppliedAnalysisSampleCount: 1000,
                centerSecondsFromOrigin: data.axes.firstCenterSeconds + Double(index) * p.hopSeconds
            )
            try input.withUnsafeBufferPointer {
                try worker.appendPowerCepstrum(
                    $0, context: context, sourceProfile: worker.sourceIdentity, emit: receive)
            }
        }
        completion = try worker.finish(
            source: source, expectedFrameCount: data.axes.frameCount, emit: receive)
    } else {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let original = try CorpusPCM(
            data: Data(contentsOf: root.appending(path: #require(reference.recipe.source.path)))
        ).samples
        let start = reference.recipe.source.startSample ?? 0
        let samples = Array(original[start..<start + count])
        #expect(samples.count == count)
        let worker = try PreparedIntervalCPPS<Double>(profile: profile, source: source)
        try samples.withUnsafeBufferPointer { try worker.append($0, interval: source) }
        completion = try worker.finish(emit: receive)
    }
    #expect(emitted == data.axes.frameCount)
    let aggregateFraction: Double?
    if let expected = data.cppsDB {
        let value = try #require(completion.meanDB)
        aggregateFraction = abs(value - expected) / dbBudget
        if !characterization {
            #expect(aggregateFraction! <= 1, "\(reference.recipe.name) aggregate")
        }
    } else {
        #expect(completion.meanDB == nil)
        aggregateFraction = nil
    }
    return [
        "name": reference.recipe.name, "frameCount": emitted,
        "maximumPowerBudgetFraction": maximumPowerFraction,
        "maximumMetricBudgetFraction": maximumMetricFraction,
        "maximumRawDiagnosticBudgetFraction": maximumRawMetricFraction,
        "gatedWholeCPPSParity": !characterization,
        "meetsFinalCPPSBudget": maximumMetricFraction <= 1
            && (aggregateFraction.map { $0 <= 1 } ?? false),
        "validationScope": reference.recipe.validationScope ?? "same-input-isolated-parity",
        "aggregateBudgetFraction": aggregateFraction as Any? ?? NSNull(),
        "profileSHA256": try profile.identity().sha256,
    ]
}

private func runCPPSReferences(isolated: Bool) throws {
    let files = try cppsReferenceFiles(isolated: isolated)
    #expect(files.count == 18)
    var report: [[String: Any]] = []
    for file in files {
        let reference = try JSONDecoder().decode(CPPSReference.self, from: Data(contentsOf: file))
        report.append(try compareCPPSReference(reference, isolated: isolated))
    }
    if let path = ProcessInfo.processInfo.environment["HDXL_CPPS_REFERENCE_REPORT"] {
        let destination = URL(fileURLWithPath: path + (isolated ? "-isolated.json" : "-pcm.json"))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
    }
}

@Test func cppsExternalIsolatedReferences() throws { try runCPPSReferences(isolated: true) }
@Test func cppsWholePCMExternalReferences() throws { try runCPPSReferences(isolated: false) }
