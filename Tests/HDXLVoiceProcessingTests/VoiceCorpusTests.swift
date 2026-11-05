import Foundation
import HDXLVoiceProcessing
import Testing

@Test func corpusOriginalsAndAllFixtureIdentitiesAreVerifiedOffline() throws {
    let corpus = try VoiceCorpus.load()
    #expect(corpus.schemaVersion == 1 && corpus.corpusVersion == "pvqd3-engineering/v1")
    #expect(corpus.sources.count == 3 && corpus.fixtures.count == 21)
    #expect(Set(corpus.fixtures.map(\.id)).count == corpus.fixtures.count)
    #expect(corpus.coverage.total == corpus.fixtures.count)
    let coverage = corpus.coverage.available + corpus.coverage.unavailable.values.flatMap { $0 }
    #expect(Set(coverage) == Set(corpus.fixtures.map(\.id)))
    #expect(coverage.count == corpus.fixtures.count)
    for source in corpus.sources {
        let data = try VoiceCorpus.bytes(source.path)
        #expect(data.count == source.byteCount)
        #expect(VoiceCorpus.sha256(data) == source.sha256)
        let decoded = try CorpusPCM(data: data)
        #expect(decoded.sampleRate == source.sampleRate)
        #expect(decoded.samples.count == source.sampleCount)
        #expect(VoiceCorpus.pcmHash(decoded.samples) == source.normalizedFloat64LESHA256)
    }
    for fixture in corpus.fixtures {
        let data = try VoiceCorpus.bytes(fixture.path)
        #expect(data.count == fixture.byteCount)
        #expect(VoiceCorpus.sha256(data) == fixture.sha256, "\(fixture.id)")
    }
}

@Test func corpusExcerptsPreserveExactOriginalSamplesAndOffsets() throws {
    let corpus = try VoiceCorpus.load()
    for source in corpus.sources {
        let original = try CorpusPCM(data: VoiceCorpus.bytes(source.path))
        for fixture in corpus.fixtures
        where fixture.sourceID == source.id && fixture.condition == "unmodified-excerpt" {
            let support = fixture.sourceSupport
            let excerpt = try CorpusPCM(data: VoiceCorpus.bytes(fixture.path))
            #expect(support.sampleRate == source.sampleRate)
            #expect(
                excerpt.samples
                    == Array(
                        original.samples[
                            support.startSample..<support.startSample + support.sampleCount]))
            #expect(excerpt.sampleRate == original.sampleRate)
        }
    }
}

@Test func corpusNativeDecoderPreservesAllApplicabilityOutcomesAndPCMStatistics() throws {
    let corpus = try VoiceCorpus.load()
    var accepted = 0
    var rejected: [String: Int] = [:]
    for fixture in corpus.fixtures {
        let data = try VoiceCorpus.bytes(fixture.path)
        if let expected = fixture.decoded {
            let pcm = try CorpusPCM(data: data)
            #expect(
                fixture.expectedInput.status == "available" && fixture.expectedInput.reason == nil)
            #expect(
                pcm.sampleRate == expected.sampleRate && pcm.samples.count == expected.sampleCount)
            #expect(Double(pcm.samples.count) / Double(pcm.sampleRate) == expected.durationSeconds)
            #expect(VoiceCorpus.pcmHash(pcm.samples) == expected.normalizedFloat64LESHA256)
            #expect(pcm.samples.map(abs).max() == expected.peak)
            let energy = pcm.samples.reduce(0) { $0 + $1 * $1 } / Double(pcm.samples.count)
            #expect(abs(energy - expected.meanSquare) < 1e-14)
            #expect(pcm.samples.filter { $0 == 0 }.count == expected.zeroSampleCount)
            #expect(
                pcm.samples.filter { $0 <= -1 || $0 >= 32767.0 / 32768 }.count
                    == expected.railSampleCount)
            accepted += 1
        } else {
            let reason = try #require(fixture.expectedInput.reason)
            #expect(fixture.expectedInput.status == "unavailable")
            #expect(throws: CorpusInputError(reason)) { try CorpusPCM(data: data) }
            rejected[reason.rawValue, default: 0] += 1
        }
    }
    #expect(accepted == 17)
    #expect(rejected == ["invalidInput": 2, "insufficientData": 1, "unsupportedRange": 1])
    // Zero-filled dropout and synthetic silence remain identified modifications.
    let silence = try #require(try corpus.fixture("corpus-bl01-silence").decoded)
    #expect(silence.meanSquare == 0 && silence.zeroSampleCount == silence.sampleCount)
    #expect(try #require(try corpus.fixture("corpus-bl01-clipped").decoded).railSampleCount > 0)
    #expect(try #require(try corpus.fixture("corpus-bl01-dropout").decoded).zeroSampleCount >= 8820)
}

@Test func corpusPCMFeedsNativeLevelsWithoutChunkDependentResults() throws {
    let corpus = try VoiceCorpus.load()
    for id in try #require(corpus.subsets["corpus-batch/v1"]) {
        let fixture = try corpus.fixture(id)
        let pcm = try CorpusPCM(data: VoiceCorpus.bytes(fixture.path))
        let configuration = try LevelConfiguration(
            sampleRate: pcm.sampleRate, inputPrecision: .float64, windowLength: 2205,
            hopLength: 441, accumulation: .compensatedSliding,
            weighting: .bs1770Revision5(warmupSampleCount: 4410),
            partialWindowPolicy: .emitUnavailable)
        let origin = Int64(fixture.sourceSupport.startSample)
        let whole = try captureLevels(
            pcm.samples, configuration: configuration, chunks: [pcm.samples.count], origin: origin)
        let split = try captureLevels(
            pcm.samples, configuration: configuration, chunks: [1, 127, 511, 3], origin: origin)
        #expect(whole.windows == split.windows, "\(id)")
        #expect(whole.completion == split.completion)
        #expect(whole.windows.first?.source.startSample == origin)
        #expect(whole.completion.observedSource.sampleCount == Int64(pcm.samples.count))
    }
}

@Test func corpusDecoderRejectsMalformedHeadersWithoutReadingOutsideData() throws {
    let fixture = try VoiceCorpus.load().fixture("corpus-bl01-vowel-a")
    let bytes = try VoiceCorpus.bytes(fixture.path)
    for count in 0..<44 {
        #expect(throws: CorpusInputError(.invalidInput)) {
            try CorpusPCM(data: Data(bytes.prefix(count)))
        }
    }
    var oversizedChunk = bytes
    oversizedChunk.replaceSubrange(40..<44, with: [255, 255, 255, 255])
    #expect(throws: CorpusInputError(.invalidInput)) { try CorpusPCM(data: oversizedChunk) }
    var badAlignment = bytes
    badAlignment[32] = 0
    #expect(throws: CorpusInputError(.invalidInput)) { try CorpusPCM(data: badAlignment) }
}

@Test func corpusNativeLoadingAndDecodingPerformance() throws {
    guard ProcessInfo.processInfo.environment["HDXL_CORPUS_PERFORMANCE"] == "1" else { return }
    let corpus = try VoiceCorpus.load()
    let manifestHash = try VoiceCorpus.sha256(VoiceCorpus.bytes("manifest.json"))
    let diagnostics = WorkerDiagnostics(mode: .detailed)
    let clock = ContinuousClock()
    func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    for (ordinal, name) in corpus.subsets.keys.sorted().enumerated() {
        let fixtures = try #require(corpus.subsets[name]).map { try corpus.fixture($0) }
        var urls = try fixtures.map { try VoiceCorpus.url($0.path) }
        var identities = fixtures.map(\.sha256)
        var counts = fixtures.map { $0.decoded?.sampleCount ?? 0 }
        var reasons = fixtures.map { $0.expectedInput.reason }
        if name == "corpus-long-stream/v1" {
            let directory = try #require(
                ProcessInfo.processInfo.environment["HDXL_CORPUS_PREPARED"])
            let root = URL(fileURLWithPath: directory)
            struct Prepared: Decodable {
                let outputSHA256: String
                let sampleCount: Int
                let continuityBoundarySamples: [Int]
                let corpusManifestSHA256: String
            }
            let prepared = try JSONDecoder().decode(
                Prepared.self, from: Data(contentsOf: root.appending(path: "long-stream.json")))
            #expect(
                prepared.corpusManifestSHA256 == manifestHash && prepared.sampleCount == 44100 * 60)
            #expect(
                prepared.continuityBoundarySamples
                    == Array(stride(from: 88200, to: 44100 * 60, by: 88200)))
            urls = [root.appending(path: "long-stream.wav")]
            identities = [prepared.outputSHA256]
            counts = [prepared.sampleCount]
            reasons = [nil]
        }
        let preloaded = try urls.map { try Data(contentsOf: $0) }
        #expect(preloaded.map(VoiceCorpus.sha256) == identities)
        func decodeAll(_ inputs: [Data]) throws -> [CorpusPCM?] {
            try inputs.enumerated().map { index, data in
                do {
                    let pcm = try CorpusPCM(data: data)
                    guard reasons[index] == nil, pcm.samples.count == counts[index] else {
                        throw CorpusInputError(.analysisFailure)
                    }
                    return pcm
                } catch let error as CorpusInputError {
                    guard error.reason == reasons[index] else { throw error }
                    return nil
                }
            }
        }
        _ = try decodeAll(preloaded)  // untimed warm-up
        var loadSeconds: [Double] = []
        var decodeSeconds: [Double] = []
        var checksums: [Double] = []
        for trial in 0..<10 {
            var metadata = DiagnosticMetadata()
            metadata.profileToken = UInt64(2700 + ordinal)
            metadata.frameSequence = UInt64(trial)
            metadata.sampleCount = UInt32(counts.reduce(0, +))
            var loaded: [Data] = []
            loadSeconds.append(
                seconds(
                    try clock.measure {
                        try diagnostics.withFrame(metadata) {
                            try diagnostics.withInterval(.fixtureLoad) {
                                loaded = try urls.map { try Data(contentsOf: $0) }
                            }
                        }
                    }))
            #expect(loaded.map(VoiceCorpus.sha256) == identities)  // hashes are untimed
            var decoded: [CorpusPCM?] = []
            decodeSeconds.append(
                seconds(
                    try clock.measure {
                        try diagnostics.withFrame(metadata) {
                            try diagnostics.withInterval(.fixtureDecode) {
                                decoded = try decodeAll(preloaded)
                            }
                        }
                    }))
            // Consume every decoded sample outside timing; keeps work observable.
            checksums.append(
                decoded.compactMap { $0 }.reduce(0) { result, pcm in
                    result + pcm.samples.reduce(0) { $0 + $1 * $1 }
                })
        }
        #expect(checksums.allSatisfy { $0 == checksums[0] && $0.isFinite })
        let report: [String: Any] = [
            "schemaVersion": 1, "workload": name, "corpusManifestSHA256": manifestHash,
            "inputSHA256": identities, "fixtureIDs": fixtures.map(\.id), "sampleRate": 44100,
            "decodedSampleCount": counts.reduce(0, +),
            "inputByteCount": preloaded.reduce(0) { $0 + $1.count },
            "decodedPCMBytes": counts.reduce(0, +) * MemoryLayout<Double>.size,
            "unavailableReasons": reasons.compactMap { $0?.rawValue },
            "precision": "PCM16 to Float64 (invalid probes include Float32 NaN)",
            "loadTrialsSeconds": loadSeconds, "decodeTrialsSeconds": decodeSeconds,
            "energyChecksums": checksums,
            "timingBoundary":
                "warm-cache Data reads separate from preloaded RIFF validation/owned decode; hashes, energy consumption, source acquisition and transformations excluded; includes two detailed diagnostic scopes per trial",
            "allocations":
                "unavailable: no audited allocation backend in this test process; input and decoded payload bytes reported, not peak RSS",
            "frameLength": NSNull(), "hopLength": NSNull(), "algorithmPerformance": false,
            "longStreamNaturalContinuity": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("CORPUS_PERFORMANCE " + String(decoding: data, as: UTF8.self))
    }
}
