import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

struct HNRReferenceProfile: Decodable {
    let method: HNRMethod
    let sampleRate: Int
    let inputPrecision: AnalysisPrecision
    let pitchFloorHz, periodsPerWindow, hopSeconds, silenceThreshold: Double
    func native() throws -> HNRConfiguration {
        try HNRConfiguration(
            method: method, sampleRate: sampleRate, inputPrecision: inputPrecision,
            pitchFloorHz: pitchFloorHz, periodsPerWindow: periodsPerWindow,
            hopSeconds: hopSeconds, silenceThreshold: silenceThreshold)
    }
}

struct HNRReferenceCase: Decodable {
    let name: String
    let profile: HNRReferenceProfile
}

struct HNRReferenceRecord: Decodable {
    struct Input: Decodable {
        let sampleCount, sampleRate: Int
        let normalizedFloat64LESHA256, encodedSHA256: String
    }
    struct Values: Decodable {
        struct Frame: Decodable {
            let index: Int
            let centerSeconds: Double
            let rawReferenceDB: Double
            let status: String
            let valueDB: Double?
        }
        let frames: [Frame]
    }
    let `case`: HNRReferenceCase
    let input: Input
    let data: Values
}

func hnrFixtureDirectory(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

func hnrReferenceSamples(_ record: HNRReferenceRecord, directory: URL) throws -> [Double] {
    let data = try Data(contentsOf: directory.appending(path: record.case.name + ".wav"))
    func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    try #require(hash(data) == record.input.encodedSHA256)
    let pcm = try CorpusPCM(data: data)
    try #require(
        pcm.sampleRate == record.input.sampleRate && pcm.samples.count == record.input.sampleCount)
    var normalized = Data()
    for sample in pcm.samples {
        var bits = sample.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { normalized.append(contentsOf: $0) }
    }
    try #require(hash(normalized) == record.input.normalizedFloat64LESHA256)
    return pcm.samples
}

@Test func hnrProfilesSerializeEveryConventionAndKeepIdentitiesDistinct() throws {
    let ac = try HNRConfiguration(method: .autocorrelation, sampleRate: 16000)
    let cc = try HNRConfiguration(method: .forwardCrossCorrelation, sampleRate: 16000)
    let causal = try HNRConfiguration(
        method: .autocorrelation, sampleRate: 16000, normalization: .causalWindow)
    #expect(try ac.identity() != cc.identity())
    #expect(try ac.identity() != causal.identity())
    #expect(ac.windowSampleCount == 1918 && cc.windowSampleCount == 958)
    #expect(ac.maximumCorrelationLag == 479 && cc.maximumCorrelationLag == 958)
    #expect(ac.localMeanSampleCount == 426 && cc.localMeanSampleCount == 426)
    for c in [ac, cc, causal] {
        #expect(
            try JSONDecoder().decode(HNRConfiguration.self, from: canonicalContractJSON(c)) == c)
    }
    let data = try canonicalContractJSON(ac)
    let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for (key, value) in [
        ("arithmeticPrecision", "float32"), ("window", "praatGaussian2"),
        ("frameGrid", "centeredWholeIntervalBinary64"), ("overshoot", "clamp"),
        ("peakResolution", "none"), ("unknown", "field"),
    ] {
        var changed = encoded
        changed[key] = value
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                HNRConfiguration.self, from: JSONSerialization.data(withJSONObject: changed))
        }
    }
    for (key, value) in [("minimumPeakCurvature", 0.0), ("reportingDecibelLimit", 100.0)] {
        var changed = encoded
        changed[key] = value
        #expect(throws: HNRError.invalidConfiguration) {
            try JSONDecoder().decode(
                HNRConfiguration.self, from: JSONSerialization.data(withJSONObject: changed))
        }
    }
    for floor in [Double.nan, .infinity, -1, 0, 19, 3000] {
        #expect(throws: HNRError.invalidConfiguration) {
            try HNRConfiguration(method: .autocorrelation, sampleRate: 16000, pitchFloorHz: floor)
        }
    }
    #expect(throws: HNRError.capacityExceeded) {
        try HNRConfiguration(
            method: .autocorrelation, sampleRate: 192000, pitchFloorHz: 20, periodsPerWindow: 10)
    }
    #expect(throws: HNRError.invalidConfiguration) {
        try HNRIntervalLayout(configuration: causal, sampleCount: 5000)
    }
}

@Test func hnrNativeGridMatchesAllPinnedFramesAndAcquiredSupport() throws {
    let directory = try hnrFixtureDirectory("HNR")
    struct Manifest: Decodable { let catalog: [HNRReferenceCase] }
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    var frameCount = 0
    for item in manifest.catalog {
        let record = try JSONDecoder().decode(
            HNRReferenceRecord.self,
            from: Data(contentsOf: directory.appending(path: item.name + ".json")))
        let c = try item.profile.native()
        let layout = try HNRIntervalLayout(configuration: c, sampleCount: record.input.sampleCount)
        #expect(layout.frameCount == record.data.frames.count)
        for (index, external) in record.data.frames.enumerated() {
            let frame = try layout.frame(at: index)
            #expect(frame.centerSecondsFromOrigin == external.centerSeconds)
            #expect(frame.frameIndex + 1 == external.index)
            #expect(
                frame.support.lowerBound >= 0
                    && frame.support.upperBound <= record.input.sampleCount)
            #expect(frame.support.contains(frame.centeredWindowStartSample))
            #expect(
                frame.support.contains(frame.centeredWindowStartSample + c.windowSampleCount - 1))
            #expect(frame.support.contains(frame.localMeanStartSample + c.localMeanSampleCount - 1))
            let last =
                frame.correlationStartSample + c.windowSampleCount - 1
                + (c.method == .forwardCrossCorrelation ? frame.computedMaximumLag : 0)
            #expect(frame.support.contains(last))
            frameCount += 1
        }
    }
    #expect(manifest.catalog.count == 180 && frameCount == 4113)
    let c = try HNRConfiguration(method: .autocorrelation, sampleRate: 16000)
    #expect(try HNRIntervalLayout(configuration: c, sampleCount: 1919).frameCount == 0)
    #expect(try HNRIntervalLayout(configuration: c, sampleCount: 1920).frameCount == 1)
    #expect(throws: HNRError.invalidBufferSize) {
        try HNRIntervalLayout(configuration: c, sampleCount: 1920).frame(at: -1)
    }
    #expect(throws: HNRError.capacityExceeded) {
        try HNRIntervalLayout(configuration: c, sampleCount: Int.max)
    }
    let high = try HNRConfiguration(
        method: .autocorrelation, sampleRate: 16000, hopSeconds: 1.0 / 16000)
    #expect(throws: HNRError.capacityExceeded) {
        try HNRIntervalLayout(
            configuration: high, sampleCount: HNRConfiguration.maximumIntervalSampleCount)
    }
}

@Test func hnrReportingLimitsPreserveFiniteAndNumericalZeroNoiseStates() throws {
    let zero = try HNRPeriodicityEstimate(unreflectedCorrelation: 0.5)
    #expect(zero.status == .finite && zero.finiteDecibels == 0)
    #expect(zero.referenceReportingDecibels == 0 && zero.noiseFraction == 0.5)
    let exact = try HNRPeriodicityEstimate(unreflectedCorrelation: 1)
    #expect(exact.status == .numericalZeroNoise && exact.finiteDecibels == nil)
    #expect(exact.referenceReportingDecibels == 150 && exact.noiseFraction == 0)
    let near = try HNRPeriodicityEstimate(unreflectedCorrelation: 1.0.nextDown)
    #expect(near.status == .upperReportingLimit && near.noiseFraction > 0)
    #expect(try #require(near.finiteDecibels) > 150)
    let tiny = try HNRPeriodicityEstimate(unreflectedCorrelation: Double.leastNonzeroMagnitude)
    #expect(tiny.status == .lowerReportingLimit && tiny.referenceReportingDecibels == -150)
    #expect(try #require(tiny.finiteDecibels).isFinite)
    #expect(try #require(tiny.finiteDecibels) < -3000)
    let reflected = try HNRPeriodicityEstimate(unreflectedCorrelation: 2)
    #expect(reflected.wasReflected && reflected.periodicity == 0.5 && reflected.finiteDecibels == 0)
    for value in [Double.nan, .infinity, -.infinity, -1, 0] {
        #expect(throws: HNRError.numericalFailure) {
            try HNRPeriodicityEstimate(unreflectedCorrelation: value)
        }
    }
}

@Test func hnrPeakResolutionKeepsHalfGridTiesAndRejectsRoundoffPeaks() {
    #expect(HNRNumerics.peakKind(left: 0.4, middle: 0.5, right: 0.5) == .resolved)
    #expect(HNRNumerics.peakKind(left: 0.5, middle: 0.5, right: 0.4) == .notLocalMaximum)
    #expect(HNRNumerics.peakKind(left: 0.5, middle: 0.5.nextUp, right: 0.5) == .numericallyFlat)
    #expect(HNRNumerics.peakKind(left: -0.2, middle: -0.1, right: -0.2) == .notLocalMaximum)
}

@Test func hnrNativeInterpolationMatchesIndependentIntermediateAnchors() throws {
    struct Stages: Decodable {
        struct Equations: Decodable {
            struct Candidate: Decodable {
                let integerLag: Int
                let initialLag, initialStrength, lag, unreflectedCorrelation: Double
            }
            let correlation: [Double?]
            let window: [Double]?
            let centeredStartSample, localMeanStartSample, correlationStartSample: Int
            let computedMaximumLag: Int?
            let candidates: [Candidate]
        }
        struct Input: Decodable { let sampleCount: Int }
        let `case`: HNRReferenceCase
        let input: Input
        let frameIndex: Int
        let equations: Equations
    }
    let directory = try hnrFixtureDirectory("HNRStages")
    let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
    var candidateCount = 0
    for file in files {
        let stage = try JSONDecoder().decode(Stages.self, from: Data(contentsOf: file))
        let c = try stage.case.profile.native()
        let layout = try HNRIntervalLayout(configuration: c, sampleCount: stage.input.sampleCount)
            .frame(at: stage.frameIndex)
        let e = stage.equations
        #expect(layout.centeredWindowStartSample == e.centeredStartSample)
        #expect(layout.localMeanStartSample == e.localMeanStartSample)
        #expect(layout.correlationStartSample == e.correlationStartSample)
        if let lag = e.computedMaximumLag { #expect(layout.computedMaximumLag == lag) }
        if let window = e.window {
            for (i, value) in window.enumerated() {
                #expect(abs(HNRNumerics.gaussian(index: i, count: window.count) - value) <= 4e-16)
            }
        }
        let values = e.correlation.map { $0 ?? 0 }
        let valid = e.correlation.map { $0 != nil }
        try values.withUnsafeBufferPointer { curve in
            try valid.withUnsafeBufferPointer { flags in
                for candidate in e.candidates {
                    let initial = try #require(
                        HNRNumerics.sinc(
                            curve, valid: flags, position: candidate.initialLag, depth: 30))
                    let reflected = initial > 1 ? 1 / initial : initial
                    #expect(abs(reflected - candidate.initialStrength) < 2e-14)
                    let maximum = try #require(
                        HNRNumerics.maximum(curve, valid: flags, integerLag: candidate.integerLag))
                    #expect(
                        abs(maximum.correlation - candidate.unreflectedCorrelation) < 2e-14,
                        "\(stage.case.name), integer lag \(candidate.integerLag), native \(maximum), oracle \(candidate.lag), \(candidate.unreflectedCorrelation)"
                    )
                    #expect(
                        abs(maximum.lag - candidate.lag) < 2e-5,
                        "\(stage.case.name), integer lag \(candidate.integerLag), native \(maximum), oracle \(candidate.lag), \(candidate.unreflectedCorrelation)"
                    )
                    candidateCount += 1
                }
            }
        }
    }
    #expect(files.count == 16 && candidateCount > 50)
}

@Test func hnrSincHonorsIntegerSymmetryUndefinedCellsAndBounds() throws {
    let values = [1.0, 0.5, -0.25, 0, 0.1, 0.2, 0, 0]
    var flags = Array(repeating: true, count: values.count)
    values.withUnsafeBufferPointer { curve in
        flags.withUnsafeBufferPointer { valid in
            for (i, value) in values.enumerated() {
                #expect(
                    HNRNumerics.sinc(curve, valid: valid, position: Double(i), depth: 700) == value)
                #expect(
                    HNRNumerics.sinc(curve, valid: valid, position: -Double(i), depth: 700) == value
                )
            }
            #expect(HNRNumerics.sinc(curve, valid: valid, position: .nan, depth: 700) == nil)
            #expect(HNRNumerics.sinc(curve, valid: valid, position: 8, depth: 700) == nil)
        }
    }
    flags[3] = false
    values.withUnsafeBufferPointer { curve in
        flags.withUnsafeBufferPointer { valid in
            #expect(HNRNumerics.sinc(curve, valid: valid, position: 3, depth: 700) == nil)
            #expect(HNRNumerics.sinc(curve, valid: valid, position: 3.2, depth: 700) == nil)
        }
    }
}
