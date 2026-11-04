import CryptoKit
import Foundation
import HDXLVoiceProcessing
import Testing

private struct ReferenceFixture: Decodable {
    struct Inputs: Decodable {
        struct PCM: Decodable {
            let artifactSHA256: String
            let normalizedFloat64LESHA256: String
            let sampleRate: Double
            let sampleCount: Int
        }
        let input: PCM
        let profile: ProfileIdentity
    }
    struct Components: Decodable {
        struct Axes: Decodable {
            let frameCount: Int
            let firstCenterSeconds: Double
            let hopSeconds: Double
            let quefrencyBinCount: Int
            let quefrencyOriginSeconds: Double
            let quefrencyStepSeconds: Double
        }
        struct Frames: Decodable {
            let columns: [String]
            let values: [[Double?]]
        }
        struct Matrix: Decodable {
            let rows: Int
            let columns: Int
            let order: String
            let unit: String
            let values: [Double?]
        }
        let axes: Axes
        let frames: [String: Frames]
        let matrices: [String: Matrix]
    }
    let schemaVersion: Int
    let referenceIdentity: String
    let identityInputs: Inputs
    let profile: AnalysisProfile
    let result: MeasurementResult
    let data: Components
    let rawOutputSHA256: String
}

private func referenceBytes(_ relative: String) throws -> Data {
    let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try Data(contentsOf: root.appending(path: "Reference/" + relative))
}

private func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private enum ReferenceValidationError: Error { case mismatch }

private func decodeAndValidate(_ bytes: Data) throws -> ReferenceFixture {
    let fixture = try JSONDecoder().decode(ReferenceFixture.self, from: bytes)
    let identity = try fixture.profile.identity()
    guard fixture.schemaVersion == 1, fixture.referenceIdentity.count == 64,
        identity == fixture.identityInputs.profile, identity == fixture.result.profile,
        fixture.result.measurement == fixture.profile.measurement,
        fixture.result.timing.source.sampleCount == fixture.identityInputs.input.sampleCount,
        fixture.result.timing.source.sampleRate == fixture.identityInputs.input.sampleRate,
        fixture.result.timing.coverage == 1,
        fixture.data.axes.frameCount == 11, fixture.data.axes.quefrencyBinCount == 513,
        fixture.data.axes.hopSeconds == 0.002,
        fixture.data.axes.quefrencyStepSeconds == 0.0001,
        fixture.data.axes.quefrencyOriginSeconds == 0
    else { throw ReferenceValidationError.mismatch }
    return fixture
}

@Test func referenceCPPSComponentsAndContractAreIndependentlyConsumable() throws {
    let fixture = try decodeAndValidate(referenceBytes("cpps-saw/reference.json"))
    let pcm = try referenceBytes("saw-120ms.wav")
    #expect(sha256(pcm) == fixture.identityInputs.input.artifactSHA256)
    // Original generator has fmt(16), fact(4), and Float64 data; no lossy decode.
    #expect(pcm.count == 56 + 1920 * 8)
    #expect(sha256(pcm.dropFirst(56)) == fixture.identityInputs.input.normalizedFloat64LESHA256)
    #expect(try sha256(referenceBytes("cpps-saw/reference.raw.txt")) == fixture.rawOutputSHA256)
    #expect(fixture.result.measurement.unit == .decibelsRatio)
    #expect(fixture.result.timing.sourceStartSeconds == 0)
    #expect(fixture.result.timing.source.durationSeconds == 0.12)
    #expect(fixture.result.timing.effectiveDelaySeconds == 0.06)
    for stage in ["raw", "smoothed"] {
        let frames = try #require(fixture.data.frames[stage])
        #expect(
            frames.columns == [
                "timeSeconds", "slopeDBPerSecond", "interceptDB", "peakDB",
                "peakQuefrencySeconds", "cppDB",
            ])
        #expect(frames.values.count == fixture.data.axes.frameCount)
        for (index, row) in frames.values.enumerated() {
            #expect(row.count == 6)
            let values = try row.map { try #require($0) }
            #expect(abs(values[0] - (0.05 + Double(index) * 0.002)) < 1e-12)
            #expect(abs(values[5] - (values[3] - values[1] * values[4] - values[2])) < 1e-7)
        }
        let matrix = try #require(fixture.data.matrices[stage])
        #expect(matrix.rows == 513 && matrix.columns == 11)
        #expect(matrix.values.count == matrix.rows * matrix.columns)
        #expect(matrix.order == "quefrency-row-major")
        #expect(matrix.unit == "praat7-linear-power-cepstrum")
        #expect(matrix.values.allSatisfy { $0.map { $0.isFinite && $0 >= 0 } == true })
    }
    let values = try #require(fixture.data.frames["smoothed"]).values.map { try #require($0[5]) }
    let mean = values.reduce(0, +) / Double(values.count)
    #expect(abs(mean - (try #require(fixture.result.outcome.estimate).value)) < 1e-8)
}

@Test func referenceRejectsMismatchedProfileAndBadUnits() throws {
    let bytes = try referenceBytes("cpps-saw/reference.json")
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var profile = try #require(object["profile"] as? [String: Any])
    profile["hopLength"] = 40
    object["profile"] = profile
    let modified = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ReferenceValidationError.self) { try decodeAndValidate(modified) }
    let wrongUnit = String(decoding: bytes, as: UTF8.self).replacingOccurrences(
        of: "decibelsRatio", with: "percent")
    #expect(throws: ContractError.self) { try decodeAndValidate(Data(wrongUnit.utf8)) }
}

@Test func referenceSilentHNRIsUnavailableWithoutPython() throws {
    struct Auxiliary: Decodable {
        struct Contents: Decodable {
            struct Scalar: Decodable {
                let measurement: MeasurementDescriptor
                let outcome: MeasurementOutcome
            }
            let scalars: [String: Scalar]
            let rows: [[Double?]]
        }
        let data: Contents
    }
    let fixture = try JSONDecoder().decode(
        Auxiliary.self, from: referenceBytes("hnr-silence/reference.json"))
    let hnr = try #require(fixture.data.scalars["harmonicToNoiseRatio"])
    #expect(hnr.measurement.unit == .decibelsRatio)
    #expect(hnr.outcome == .unavailable(.analysisFailure))
    #expect(!fixture.data.rows.isEmpty)
    #expect(fixture.data.rows.allSatisfy { $0.count == 2 && $0[0] != nil && $0[1] == nil })
}

@Test func referenceAnalyticPrimitivesMatchDirectEquations() throws {
    struct Primitives: Decodable {
        struct Vector: Decodable {
            let samples: [Double]
            let normalizedFloat64LESHA256: String
            let dftReal: [Double]
            let dftImaginary: [Double]
            let meanSquare: Double
            let rms: Double
            let peak: Double
        }
        let floatingAbsoluteTolerance: Double
        let vectors: [Vector]
    }
    let fixture = try JSONDecoder().decode(Primitives.self, from: referenceBytes("primitives.json"))
    #expect(fixture.vectors.count == 6)
    for vector in fixture.vectors {
        let samples = vector.samples
        let pcm = samples.flatMap { value -> [UInt8] in
            var bits = value.bitPattern.littleEndian
            return withUnsafeBytes(of: &bits) { Array($0) }
        }
        #expect(sha256(Data(pcm)) == vector.normalizedFloat64LESHA256)
        for k in samples.indices {
            var real = 0.0
            var imaginary = 0.0
            for n in samples.indices {
                let phase = -2 * Double.pi * Double(k * n) / Double(samples.count)
                real += samples[n] * cos(phase)
                imaginary += samples[n] * sin(phase)
            }
            #expect(abs(real - vector.dftReal[k]) < fixture.floatingAbsoluteTolerance)
            #expect(abs(imaginary - vector.dftImaginary[k]) < fixture.floatingAbsoluteTolerance)
        }
        let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count)
        #expect(meanSquare == vector.meanSquare)
        #expect(abs(sqrt(meanSquare) - vector.rms) < fixture.floatingAbsoluteTolerance)
        #expect(samples.map(abs).max() == vector.peak)
    }
}

@Test func referenceNativeValidationPerformance() throws {
    guard ProcessInfo.processInfo.environment["HDXL_REFERENCE_PERFORMANCE"] == "1" else { return }
    let bytes = try referenceBytes("cpps-saw/reference.json")
    let fixture = try decodeAndValidate(bytes)  // untimed load and warm-up
    let diagnostics = WorkerDiagnostics(mode: .detailed)
    let clock = ContinuousClock()
    var seconds: [Double] = []
    for index in 0..<10 {
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 26  // process-local fixture token; full hash in evidence below
        metadata.frameSequence = UInt64(index)
        metadata.sampleCount = 1920
        let elapsed = try clock.measure {
            try diagnostics.withFrame(metadata) {
                try diagnostics.withInterval(.referenceValidation) {
                    _ = try decodeAndValidate(bytes)
                }
            }
        }
        seconds.append(
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
    let report: [String: Any] = [
        "schemaVersion": 1, "workload": "native-fixture-decode-contract-validation",
        "referenceIdentity": fixture.referenceIdentity,
        "profileSHA256": fixture.identityInputs.profile.sha256, "trialsSeconds": seconds,
        "timingBoundary":
            "preloaded JSON decode plus contract/hash/axis validation; includes detailed signposts",
        "sampleRate": 16000, "inputDurationSeconds": 0.12, "frameLength": 1000,
        "analysisSampleRate": 10000, "hopLength": 20, "precision": "float64",
        "allocations": "unavailable; no audited allocator backend in this test process",
        "algorithmPerformance": false,
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("REFERENCE_VALIDATION " + String(decoding: data, as: UTF8.self))
}
