import Foundation
import Testing

@testable import HDXLVoiceProcessing

private let sessionScalarStart: Int64 = (1 << 54) + 29

func sessionTestSource(start: Int64 = 0, rate: Double = 16000) throws -> SessionArchiveSource {
    let epoch = StreamEpoch(streamID: calibrationTestID(5801), sequence: 7)
    return try SessionArchiveSource(
        origin: AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: epoch, startSample: start, sampleCount: 0, sampleRate: rate),
            continuityEpoch: StreamEpoch(streamID: epoch.streamID, sequence: 19)),
        acquisition: SessionAcquisitionMetadata(
            conditions: CalibrationRecordingConditions(
                routeIdentifier: "synthetic-route", recordingSettings: [:]),
            deviceIdentifier: "synthetic-device", platformDescription: "synthetic-platform"))
}

func sessionTestLevel() throws -> LevelConfiguration {
    try LevelConfiguration(
        sampleRate: 16000, inputPrecision: .float64, windowLength: 400, hopLength: 160,
        accumulation: .compensatedSliding, weighting: .none)
}

func sessionTestCatalog(
    start: Int64 = sessionScalarStart, limits: SessionArchiveLimits? = nil
) throws -> SessionArchiveCatalog {
    var catalog = try SessionArchiveCatalog(limits: limits ?? SessionArchiveLimits())
    let profile = try SessionArchiveProfile.levels(sessionTestLevel())
    let source = try sessionTestSource(start: start)
    let series = try SessionArchiveSeries(
        profileIndex: 0, sourceIndex: 0,
        measurement: MeasurementDescriptor(
            kind: .rms, unit: .normalizedAmplitude, algorithm: profile.identity().identifier),
        clock: .sourceSamples)
    try catalog.add(profile, payloadBytes: canonicalContractJSON(profile).count)
    try catalog.add(source, payloadBytes: canonicalContractJSON(source).count)
    try catalog.add(series, payloadBytes: canonicalContractJSON(series).count)
    return catalog
}

func sessionTestMeasurement(
    catalog: SessionArchiveCatalog, start: Int64 = sessionScalarStart,
    timestamp: Int64? = nil, outcome: MeasurementOutcome? = nil,
    intermediates: [IntermediateSnapshot] = [], budget: Int = 0
) throws -> SessionArchiveMeasurement {
    let (series, profile, source) = try catalog.context(for: 0)
    return try SessionArchiveMeasurement(
        timestamp: SessionArchiveTimestamp(sourceSample: timestamp ?? start + 2),
        result: MeasurementResult(
            measurement: series.measurement, profile: profile.identity,
            timing: AnalysisTiming(
                source: SourceInterval(
                    epoch: source.origin.source.epoch, startSample: start, sampleCount: 7,
                    sampleRate: 16000),
                includedSampleCount: 6, sourceStartSeconds: -2.5,
                hostStartNanoseconds: UInt64.max - 100, completedHostNanoseconds: UInt64.max - 1,
                effectiveDelaySeconds: 0.25),
            outcome: outcome
                ?? .available(
                    ScalarEstimate(
                        value: 12.5, confidence: 0.75, warnings: [.partialCoverage, .clipping])),
            intermediatePolicy: IntermediateOutputPolicy(maximumScalarCount: budget),
            intermediates: intermediates))
}

@Test func sessionScalarIndependentGoldenPreservesLargeIntegerClocks() throws {
    let catalog = try sessionTestCatalog()
    let value = try sessionTestMeasurement(catalog: catalog)
    let encoded = try SessionArchiveScalarWire.encode(value, seriesIndex: 0, catalog: catalog)
    // Python struct.pack with explicit LE integer and IEEE754 fields; independent
    // of the Swift codec and of floating-point JSON integer conversions.
    let golden =
        "000000001f000000000040001d0000000000400007000000000000000600000000000000000000000000d03f0700000000000004c09bfffffffffffffffeffffffffffffff00000000000000294001000000000000e83f050000000000000000"
    #expect(encoded.map { String(format: "%02x", $0) }.joined() == golden)
    #expect(encoded.count == 96)
    #expect(encoded.count < (try value.result.canonicalJSON().count) / 4)
    let (index, decoded) = try SessionArchiveScalarWire.decode(encoded, catalog: catalog)
    #expect(index == 0 && decoded == value)
    #expect(decoded.result.timing.source.startSample == sessionScalarStart)
    #expect(decoded.result.timing.completedHostNanoseconds == UInt64.max - 1)
    #expect(
        try SessionArchiveScalarWire.encode(decoded, seriesIndex: 0, catalog: catalog) == encoded)
}

@Test func sessionScalarAvailabilityWarningsAndIntermediatesRoundTrip() throws {
    let catalog = try sessionTestCatalog()
    let base = try sessionTestMeasurement(catalog: catalog)
    let snapshot = try IntermediateSnapshot(
        stage: VersionedIdentifier(name: "synthetic-spectrum", version: 1),
        source: base.result.timing.source,
        xUnit: .hertz, yUnit: .normalizedSquaredAmplitudeSecondsSquared,
        xOrigin: -0.0, xStep: 0.25, values: [-0.0, 0.125, -4, 1e200])
    var outcomes = UnavailabilityReason.allCases.map(MeasurementOutcome.unavailable)
    for bits in 0..<16 {
        outcomes.append(
            .available(
                try ScalarEstimate(
                    value: bits == 0 ? -0.0 : Double(bits), confidence: bits % 2 == 0 ? nil : 0.5,
                    warnings: SessionArchiveScalarWire.warnings.enumerated().compactMap {
                        bits & (1 << $0.offset) != 0 ? $0.element : nil
                    })))
    }
    for outcome in outcomes {
        let value = try sessionTestMeasurement(
            catalog: catalog, outcome: outcome, intermediates: [snapshot], budget: 5)
        let encoded = try SessionArchiveScalarWire.encode(value, seriesIndex: 0, catalog: catalog)
        let (_, decoded) = try SessionArchiveScalarWire.decode(encoded, catalog: catalog)
        #expect(decoded == value)
        #expect(decoded.result.intermediates[0].values[0].bitPattern == 0)
        #expect(decoded.result.intermediates[0].source == value.result.timing.source)
    }
    #expect(Set(SessionArchiveScalarWire.reasons) == Set(UnavailabilityReason.allCases))
    #expect(Set(SessionArchiveScalarWire.tags) == Set(MaskTag.allCases))
    #expect(Set(SessionArchiveScalarWire.units) == Set(MeasurementUnit.allCases))
}

@Test func sessionScalarRejectsMalformedFieldsBeforeReturningAValue() throws {
    let catalog = try sessionTestCatalog()
    let value = try sessionTestMeasurement(catalog: catalog)
    let encoded = try SessionArchiveScalarWire.encode(value, seriesIndex: 0, catalog: catalog)
    for length in 0..<encoded.count {
        #expect(throws: (any Error).self) {
            _ = try SessionArchiveScalarWire.decode(Data(encoded.prefix(length)), catalog: catalog)
        }
    }
    var trailing = encoded
    trailing.append(0)
    #expect(throws: SessionArchiveError.malformedRecord) {
        _ = try SessionArchiveScalarWire.decode(trailing, catalog: catalog)
    }
    for (offset, byte) in [(0, UInt8(9)), (19, 128), (44, 128), (69, 2), (78, 2), (87, 128)] {
        var corrupt = encoded
        corrupt[offset] = byte
        #expect(throws: (any Error).self) {
            _ = try SessionArchiveScalarWire.decode(corrupt, catalog: catalog)
        }
    }
    for bits in [Double.infinity.bitPattern, Double.nan.bitPattern, (-0.0).bitPattern] {
        var corrupt = encoded
        var number = Data()
        SessionArchiveWire.append(bits, to: &number)
        corrupt.replaceSubrange(70..<78, with: number)
        #expect(throws: SessionArchiveError.malformedRecord) {
            _ = try SessionArchiveScalarWire.decode(corrupt, catalog: catalog)
        }
    }
    var confidence = encoded
    var number = Data()
    SessionArchiveWire.append(2.0.bitPattern, to: &number)
    confidence.replaceSubrange(79..<87, with: number)
    #expect(throws: SessionArchiveError.malformedRecord) {
        _ = try SessionArchiveScalarWire.decode(confidence, catalog: catalog)
    }
    var oversized = encoded
    oversized.replaceSubrange(88..<92, with: [255, 255, 255, 255])
    #expect(throws: SessionArchiveError.sizeLimitExceeded) {
        _ = try SessionArchiveScalarWire.decode(oversized, catalog: catalog)
    }
}

@Test func sessionScalarChecksIntermediateBudgetBeforeAllocation() throws {
    let catalog = try sessionTestCatalog()
    let base = try sessionTestMeasurement(catalog: catalog)
    let snapshot = try IntermediateSnapshot(
        stage: VersionedIdentifier(name: "a", version: 1), source: base.result.timing.source,
        xUnit: .samples, yUnit: .dimensionless, xOrigin: 0, xStep: 1, values: [0, 1])
    let value = try sessionTestMeasurement(catalog: catalog, intermediates: [snapshot], budget: 2)
    let bytes = try SessionArchiveScalarWire.encode(value, seriesIndex: 0, catalog: catalog)
    // Header96 + string(2+1)+version4+interval16+units2+axes16 =137.
    var corrupt = bytes
    corrupt.replaceSubrange(137..<141, with: [255, 255, 255, 255])
    #expect(throws: SessionArchiveError.sizeLimitExceeded) {
        _ = try SessionArchiveScalarWire.decode(corrupt, catalog: catalog)
    }
    let limited = try sessionTestCatalog(
        limits: SessionArchiveLimits(maximumIntermediateScalars: 1))
    #expect(throws: SessionArchiveError.sizeLimitExceeded) {
        _ = try SessionArchiveScalarWire.encode(value, seriesIndex: 0, catalog: limited)
    }
    #expect(throws: SessionArchiveError.sizeLimitExceeded) {
        _ = try SessionArchiveScalarWire.decode(bytes, catalog: limited)
    }
    var encoder = SessionArchiveBinaryEncoder(limit: 9)
    try encoder.integer(UInt64.max)
    #expect(throws: SessionArchiveError.sizeLimitExceeded) { try encoder.integer(UInt16.max) }
    #expect(encoder.data.count == 8)
}

@Test func sessionScalarMonotonicityIsPerSeriesAndDoesNotRetainHistory() throws {
    var catalog = try sessionTestCatalog(start: 0)
    let second = try SessionArchiveSeries(
        profileIndex: 0, sourceIndex: 0,
        measurement: MeasurementDescriptor(
            kind: .peakAmplitude, unit: .normalizedAmplitude,
            algorithm: catalog.profiles[0].identity.identifier),
        clock: .sourceSamples)
    try catalog.add(second, payloadBytes: canonicalContractJSON(second).count)
    let retained = catalog.retainedMetadataBytes
    for index in 0..<2048 {
        let value = try sessionTestMeasurement(catalog: catalog, start: Int64(index))
        _ = try SessionArchiveScalarWire.encode(value, seriesIndex: 0, catalog: catalog)
        catalog.accepted(value, seriesIndex: 0)
        #expect(throws: SessionArchiveError.duplicateTimestamp) {
            try catalog.validate(value, seriesIndex: 0)
        }
    }
    let previous = try sessionTestMeasurement(catalog: catalog, start: 0)
    #expect(throws: SessionArchiveError.outOfOrder) {
        try catalog.validate(previous, seriesIndex: 0)
    }
    let other = SessionArchiveMeasurement(
        timestamp: previous.timestamp,
        result: try MeasurementResult(
            measurement: second.measurement, profile: previous.result.profile,
            timing: previous.result.timing, outcome: previous.result.outcome))
    try catalog.validate(other, seriesIndex: 1)
    #expect(catalog.retainedMetadataBytes == retained && catalog.entryCount == 4)
    #expect(catalog.profiles.count == 1 && catalog.sources.count == 1 && catalog.series.count == 2)
}
