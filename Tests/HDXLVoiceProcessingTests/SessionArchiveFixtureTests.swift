import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func sessionFixture(_ name: String) throws -> Data {
    let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try Data(contentsOf: root.appendingPathComponent("Sessions/\(name).hvps"))
}

private func sessionFixtureReader(
    _ bytes: Data, recovery: SessionArchiveRecovery = .requireComplete
) throws -> SessionArchiveReader {
    var offset = 0
    return try SessionArchiveReader(
        limits: SessionArchiveLimits(ioChunkCapacity: 256), recovery: recovery,
        mediaAccess: .deliverBytes
    ) { requested in
        let result = Data(bytes.dropFirst(offset).prefix(min(17, requested)))
        offset += result.count
        return result
    }
}

@Test func sessionCanonicalFixturesRoundTripEveryCompleteRecordByteForByte() throws {
    for name in ["scalars-v1", "partial-v1", "embedded-pcm-v1", "omitted-pcm-v1", "calibration-v1"]
    {
        let original = try sessionFixture(name)
        let reader = try sessionFixtureReader(original)
        var output = Data()
        let writer = try SessionArchiveWriter(header: reader.header, limits: SessionArchiveLimits())
        {
            output.append($0)
        }
        while let event = try reader.next() {
            switch event {
            case .profile(let index, let value): #expect(try writer.addProfile(value) == index)
            case .source(let index, let value): #expect(try writer.addSource(value) == index)
            case .series(let index, let value): #expect(try writer.addSeries(value) == index)
            case .measurement(let index, let value): try writer.append(value, to: index)
            case .gap(let value): try writer.append(value)
            case .calibrationDataset(let index, let value):
                #expect(try writer.addCalibrationDataset(value) == index)
            case .calibrationSplit(let index, let value):
                #expect(try writer.addCalibrationSplit(value) == index)
            case .calibrationAnalysis(let index, let value):
                #expect(try writer.addCalibrationAnalysis(value) == index)
            case .target(let index, let value): #expect(try writer.addTarget(value) == index)
            case .mediaReference(let index, let value):
                #expect(try writer.addMediaReference(value) == index)
            case .mediaChunk(let chunk):
                try writer.appendMedia(#require(chunk.bytes), to: chunk.referenceIndex)
            case .replayPlan(let index, let value):
                #expect(try writer.addReplayPlan(value) == index)
            case .seal(let value): #expect(try writer.finish(value.completion) == value)
            case .incomplete: Issue.record("Complete fixture unexpectedly recovered a prefix")
            }
        }
        #expect(output == original, "Independent Python wire fixture changed: \(name)")
        #expect(reader.statistics.bytesProcessed == UInt64(original.count))
        #expect(reader.statistics.maximumIOChunkBytes == 17)
    }
}

@Test func sessionCanonicalScalarFixturePreservesIndependentMeaningAndExplicitRecovery() throws {
    let start: Int64 = (1 << 54) + 29
    for name in ["scalars-v1", "partial-v1", "interrupted-v1"] {
        let reader = try sessionFixtureReader(
            sessionFixture(name),
            recovery: name == "interrupted-v1" ? .inspectCompletePrefix : .requireComplete)
        var values: [SessionArchiveMeasurement] = []
        var gaps: [SessionArchiveGap] = []
        while let event = try reader.next() {
            if case .measurement(_, let value) = event { values.append(value) }
            if case .gap(let value) = event { gaps.append(value) }
        }
        #expect(values.count == 15 && gaps.count == 1)
        let first = try #require(values.first)
        #expect(first.timestamp.sourceSample == start + 2)
        #expect(first.result.timing.source.startSample == start)
        #expect(
            first.result.timing.source.sampleCount == 7
                && first.result.timing.includedSampleCount == 6)
        #expect(first.result.timing.sourceStartSeconds == -2.5)
        #expect(first.result.timing.hostStartNanoseconds == UInt64.max - 100)
        #expect(first.result.timing.completedHostNanoseconds == UInt64.max - 1)
        #expect(first.result.timing.effectiveDelaySeconds == 0.25)
        #expect(
            first.result.measurement.kind == .rms
                && first.result.measurement.unit == .normalizedAmplitude)
        #expect(
            first.result.outcome
                == .available(
                    try ScalarEstimate(
                        value: 0.25, confidence: 0.75, warnings: [.clipping, .partialCoverage])))
        #expect(first.result.intermediatePolicy.maximumScalarCount == 4)
        let intermediate = try #require(first.result.intermediates.first)
        #expect(intermediate.values == [0, 0.125, -4, 1e20])
        #expect(
            intermediate.xUnit == .hertz
                && intermediate.yUnit == .normalizedSquaredAmplitudeSecondsSquared)
        #expect(intermediate.xOrigin == 0 && intermediate.xStep == 0.25)
        let reasons: [UnavailabilityReason] = [
            .insufficientData, .silence, .clipping,
            .unsupportedRange, .inapplicableTask, .lowConfidence, .invalidInput, .discontinuity,
            .analysisFailure, .cancelled, .missingAcquisition, .excluded, .stale,
        ]
        #expect(
            values.dropFirst().prefix(13).map(\.result.outcome)
                == reasons.map(MeasurementOutcome.unavailable))
        #expect(gaps[0].observedSource.sampleCount == 224)
        #expect(
            gaps[0].dispatchedSourceSamples == 222 && gaps[0].pendingSourceSamplesDiscarded == 2)
        #expect(
            gaps[0].missingSource?.startSample == start + 224
                && gaps[0].missingSource?.sampleCount == 5)
        #expect(gaps[0].reason == .droppedAudio)
        #expect(values.last?.result.timing.source.startSample == start + 229)
        #expect(try reader.source(at: 1).origin.continuityEpoch.sequence == 20)
        #expect(
            try reader.source(at: 0).acquisition.conditions.routeIdentifier == "synthetic-route")
        if name == "interrupted-v1" {
            #expect(reader.isIncomplete && reader.seal == nil)
        } else {
            #expect(reader.seal?.completion == (name == "partial-v1" ? .partial : .completed))
            #expect(reader.seal?.measurementCount == 15 && reader.seal?.catalogEntryCount == 6)
        }
    }
    #expect(throws: SessionArchiveError.truncated) {
        let strict = try sessionFixtureReader(sessionFixture("interrupted-v1"))
        while try strict.next() != nil {}
    }
}

@Test func sessionCanonicalScheduledFixtureRetainsOriginalPCMOrItsExplicitAbsence() throws {
    for embedded in [false, true] {
        let reader = try sessionFixtureReader(
            sessionFixture(embedded ? "embedded-pcm-v1" : "omitted-pcm-v1"))
        var values: [SessionArchiveMeasurement] = []
        var audio = Data()
        while let event = try reader.next() {
            if case .measurement(_, let value) = event { values.append(value) }
            if case .mediaChunk(let chunk) = event { audio.append(try #require(chunk.bytes)) }
        }
        #expect(values.count == 4)
        for (index, value) in values.enumerated() {
            #expect(value.timestamp.secondsFromOrigin == Double(index * 8) / 16000 + 0.00025)
            #expect(value.result.outcome == .available(try ScalarEstimate(value: 0.25)))
            let scheduled = try #require(value.scheduled)
            #expect(
                scheduled.dependencyCoverage.source == 8
                    && scheduled.dependencyCoverage.eligible == 8
                    && scheduled.dependencyCoverage.selected == 8)
            #expect(scheduled.dependencyTiming == value.result.timing)
            #expect(scheduled.workerBatchingUpperBoundSeconds == 0.008)
        }
        let reference = try reader.mediaReference(at: 0)
        #expect(reference.inclusion == (embedded ? .embedded : .omitted))
        #expect(reader.header.audioPolicy == (embedded ? .explicitlyInclude : .omit))
        #expect(reference.decoder.runtime == "synthetic-fixture-origin")
        #expect(reference.media.byteCount == 108 && reference.decoder.fileSampleCount == 32)
        #expect(try reader.mediaBytesAreVerified(at: 0) == embedded)
        #expect(reader.replayPlanIndex(for: 0) == 0)
        if embedded {
            #expect(
                audio.count == 108 && CalibrationDigest(bytes: audio) == reference.media.content)
            #expect(String(decoding: audio.prefix(4), as: UTF8.self) == "RIFF")
            #expect(audio.dropFirst(44) == Data((0..<32).flatMap { _ in [UInt8(0), UInt8(32)] }))
        } else {
            #expect(audio.isEmpty)
        }
    }
}

@Test func sessionCanonicalCalibrationClaimsRequireSeparateMatchingEvaluation() throws {
    let reader = try sessionFixtureReader(sessionFixture("calibration-v1"))
    var inspectedBeforeSeal = 0
    while let event = try reader.next() {
        if case .target = event {
            #expect(reader.seal == nil)
            inspectedBeforeSeal += 1
        }
    }
    #expect(inspectedBeforeSeal == 2 && reader.seal?.completion == .completed)
    #expect(try reader.calibrationDataset(at: 0).takeCount == 64)
    let current = try reader.target(at: 0)
    let future = try reader.target(at: 1)
    guard case .schedule(let profile) = try reader.profile(at: 0) else {
        throw SessionArchiveError.invalidMetadata
    }
    #expect(try current.compatibility(with: profile) == .requiresVerifiedEvaluation)
    #expect(try future.compatibility(with: profile) == .unsupportedFittingImplementation)
    #expect(current.candidate.rule.featureScaling == "identity; CPPS dB")
    #expect(current.candidate.rule.statistic == .selectedIntervalLowerMedianV1)
    #expect(current.claimedEvaluationIdentity != nil && future.claimedEvaluationIdentity == nil)
    let other = try TargetTestFixture(dataset: targetTestDataset())
    let otherEvaluation = try other.evaluate(other.fit())
    #expect(otherEvaluation.activated != nil)
    for index: UInt32 in [0, 1] {
        #expect(throws: SessionArchiveError.activationRefused) {
            try reader.activateTarget(
                at: index, currentProfile: profile, verifiedEvaluation: otherEvaluation)
        }
    }
    // A checksum/encoding round trip cannot reinterpret a formerly supported CPPS
    // scale. Unknown rule semantics must be refused even for a known schema.
    var json = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
    var candidate = try #require(json["candidate"] as? [String: Any])
    var rule = try #require(candidate["rule"] as? [String: Any])
    rule["featureScaling"] = "different-CPPS-scale"
    candidate["rule"] = rule
    json["candidate"] = candidate
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(
            SessionArchiveTarget.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
