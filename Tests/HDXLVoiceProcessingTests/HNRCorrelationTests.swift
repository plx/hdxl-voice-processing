import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func hnrFFTCorrelationsMatchIndependentDirectSumStages() throws {
    struct Stages: Decodable {
        struct Equations: Decodable {
            let localMean: Double
            let windowed: [Double]
            let signalCorrelation, windowCorrelation: [Double]?
            let correlation: [Double?]
            let correlationStartSample, correlationSampleCount: Int
            let computedMaximumLag: Int?
        }
        let `case`: HNRReferenceCase
        let equations: Equations
    }
    let directory = try hnrFixtureDirectory("HNRStages")
    let references = try hnrFixtureDirectory("HNR")
    let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
    var cells = 0
    for file in files {
        let stage = try JSONDecoder().decode(Stages.self, from: Data(contentsOf: file))
        let c = try stage.case.profile.native()
        let e = stage.equations
        let worker = try PreparedHNRCorrelation(c, diagnostics: WorkerDiagnostics())
        let input: [Double]
        if c.method == .autocorrelation {
            input = e.windowed
        } else {
            let external = try JSONDecoder().decode(
                HNRReferenceRecord.self,
                from: Data(contentsOf: references.appending(path: stage.case.name + ".json")))
            let samples = try hnrReferenceSamples(external, directory: references)
            input = samples[
                e.correlationStartSample..<e.correlationStartSample + e.correlationSampleCount
            ]
            .map { $0 - e.localMean }
        }
        try input.withUnsafeBufferPointer {
            try worker.compute($0, maximumLag: e.computedMaximumLag ?? c.maximumCorrelationLag)
        }
        #expect(worker.curve.count == e.correlation.count)
        for (i, expected) in e.correlation.enumerated() {
            #expect(worker.valid[i] == (expected != nil))
            if let expected {
                #expect(
                    abs(worker.curve[i] - expected) <= 2e-14,
                    "\(stage.case.name) correlation lag \(i), error \(worker.curve[i] - expected)")
            }
            cells += 1
        }
        for (actual, expected) in [
            (worker.signalCorrelation, e.signalCorrelation),
            (worker.windowCorrelation, e.windowCorrelation),
        ] {
            if let expected {
                #expect(actual.count == expected.count)
                for (i, value) in expected.enumerated() {
                    #expect(
                        abs(actual[i] - value) <= 2e-12,
                        "\(stage.case.name) unnormalized correlation lag \(i)")
                }
            } else {
                #expect(actual.isEmpty)
            }
        }
    }
    #expect(files.count == 16 && cells > 20_000)
}

@Test func hnrCorrelationClosedFormsAndUndefinedEnergySurviveWorkspaceReuse() throws {
    for method in HNRMethod.allCases {
        let c = try HNRConfiguration(
            method: method, sampleRate: 4000, pitchFloorHz: 500, periodsPerWindow: 2)
        let worker = try PreparedHNRCorrelation(c, diagnostics: WorkerDiagnostics())
        let lag = method == .autocorrelation ? c.maximumCorrelationLag : c.maximumCandidateLag
        let count = c.windowSampleCount + (method == .forwardCrossCorrelation ? lag : 0)
        var samples = Array(repeating: 0.0, count: count)
        samples[0] = 1
        try samples.withUnsafeBufferPointer { try worker.compute($0, maximumLag: lag) }
        #expect(worker.curve[0] == 1)
        if method == .autocorrelation {
            #expect(abs(worker.signalCorrelation[0] - 1) < 1e-15)
            for k in 1...lag { #expect(abs(worker.signalCorrelation[k]) < 1e-15) }
        } else {
            for k in 1...lag { #expect(!worker.valid[k]) }
            #expect(worker.directEnergyLagCount > 0)
            for k in (lag + 1)...c.maximumCorrelationLag {
                #expect(worker.curve[k] == 0 && worker.valid[k])
            }
        }
        samples = Array(repeating: 1.0, count: count)
        try samples.withUnsafeBufferPointer { try worker.compute($0, maximumLag: lag) }
        if method == .forwardCrossCorrelation {
            for k in 0...lag {
                #expect(worker.valid[k] && abs(worker.curve[k] - 1) < 2e-15)
            }
        } else {
            for k in 0...lag {
                #expect(abs(worker.signalCorrelation[k] - Double(c.windowSampleCount - k)) < 1e-13)
            }
        }
        samples[0] = .nan
        #expect(throws: HNRError.invalidInput) {
            try samples.withUnsafeBufferPointer { try worker.compute($0, maximumLag: lag) }
        }
        #expect(throws: HNRError.invalidBufferSize) {
            try samples.dropLast().withUnsafeBufferPointer {
                try worker.compute($0, maximumLag: lag)
            }
        }
    }
}
