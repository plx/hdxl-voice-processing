import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func sessionGenericProfile() throws -> AnalysisProfile {
    try AnalysisProfile(
        identifier: VersionedIdentifier(name: "synthetic-generic-profile", version: 1),
        measurement: MeasurementDescriptor(
            kind: .clippingFraction, unit: .fraction,
            algorithm: VersionedIdentifier(name: "synthetic-generic-algorithm", version: 1)),
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: .arithmeticMean, precision: .float64, frameLength: 400, hopLength: 160,
        analysisSampleRate: 16000, window: VersionedIdentifier(name: "rectangular", version: 1),
        preprocessing: ["synthetic": .boolean(true)], algorithmSettings: ["threshold": .real(1)],
        partialWindowPolicy: .emitUnavailable)
}

@Test func sessionCatalogPreservesEverySupportedRecipeAndReferenceIdentity() throws {
    let yin = try YINConfiguration(
        sampleRate: 16000, inputPrecision: .float64, pitchFloorHz: 50, pitchCeilingHz: 700,
        hopLength: 160)
    let cpps = try CPPSProfile.murtonRecipePraat7(
        sourceSampleRate: 16000, declaredInputBandwidthHz: 8000)
    let schedule = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: .arithmeticMean,
        levels: sessionTestLevel(),
        pitch: YINProfile(estimator: yin, tracker: YINTrackerConfiguration()), cpps: cpps)
    let recipes: [SessionArchiveProfile] = try [
        .analysis(sessionGenericProfile()), .schedule(schedule), .levels(sessionTestLevel()),
        .yin(yin), .trackedYIN(YINProfile(estimator: yin, tracker: YINTrackerConfiguration())),
        .cpp(CPPProfile(cepstrogram: cpps.cepstrogram, settings: cpps.settings.prominence)),
        .cpps(cpps),
    ]
    for recipe in recipes {
        let bytes = try canonicalContractJSON(recipe)
        let decoded = try decodeSessionMetadata(SessionArchiveProfile.self, from: bytes)
        #expect(recipe == decoded)
        #expect(try recipe.identity() == decoded.identity())
        #expect(try recipe.descriptors() == decoded.descriptors())
        #expect(recipe.sourceSampleRate == 16000)
    }
    let descriptors = try SessionArchiveProfile.schedule(schedule).descriptors()
    #expect(
        descriptors.contains(
            try MeasurementDescriptor(
                kind: .cpps, unit: .decibelsRatio, algorithm: cpps.identity().identifier)))
    #expect(
        descriptors.contains(
            try MeasurementDescriptor(
                kind: .fundamentalFrequency, unit: .hertz,
                algorithm: schedule.pitch!.identity().identifier)))
    #expect(descriptors.count == 11)
    #expect(!descriptors.contains(where: { $0.kind == .clippingFraction && $0.unit == .percent }))
}

@Test func sessionCatalogRejectsDuplicateTablesAndChecksBudgetsBeforeMutation() throws {
    var catalog = try sessionTestCatalog()
    let before = catalog.retainedMetadataBytes
    #expect(throws: SessionArchiveError.duplicateIdentity) {
        try catalog.add(catalog.profiles[0].recipe, payloadBytes: 1)
    }
    #expect(throws: SessionArchiveError.duplicateIdentity) {
        try catalog.add(catalog.sources[0], payloadBytes: 1)
    }
    #expect(throws: SessionArchiveError.duplicateIdentity) {
        try catalog.add(catalog.series[0], payloadBytes: 1)
    }
    let anotherClock = try SessionArchiveSeries(
        profileIndex: 0, sourceIndex: 0, measurement: catalog.series[0].measurement,
        clock: .secondsFromOrigin)
    #expect(throws: SessionArchiveError.duplicateIdentity) {
        try catalog.add(anotherClock, payloadBytes: 1)
    }
    #expect(catalog.entryCount == 3 && catalog.retainedMetadataBytes == before)
    var small = try SessionArchiveCatalog(limits: SessionArchiveLimits(maximumCatalogBytes: 128))
    #expect(throws: SessionArchiveError.catalogLimitExceeded) {
        try small.add(catalog.profiles[0].recipe, payloadBytes: 129)
    }
    #expect(small.entryCount == 0 && small.retainedMetadataBytes == 0 && small.profiles.isEmpty)
    var full = try sessionTestCatalog(limits: SessionArchiveLimits(maximumCatalogEntries: 3))
    #expect(throws: SessionArchiveError.catalogLimitExceeded) {
        try full.reserveMetadata(payloadBytes: 1)
    }
    #expect(full.entryCount == 3)
}

@Test func sessionCatalogRefusesIncompatibleUnitsRecipesAndSourceRates() throws {
    var catalog = try SessionArchiveCatalog(limits: SessionArchiveLimits())
    let generic = try sessionGenericProfile()
    let profile = SessionArchiveProfile.analysis(generic)
    let source = try sessionTestSource()
    try catalog.add(profile, payloadBytes: canonicalContractJSON(profile).count)
    try catalog.add(source, payloadBytes: canonicalContractJSON(source).count)
    let percent = try MeasurementDescriptor(
        kind: .clippingFraction, unit: .percent, algorithm: generic.measurement.algorithm)
    #expect(throws: SessionArchiveError.incompatibleUnit) {
        try catalog.add(
            SessionArchiveSeries(
                profileIndex: 0, sourceIndex: 0, measurement: percent, clock: .sourceSamples),
            payloadBytes: 1)
    }
    let wrong = try MeasurementDescriptor(
        kind: .clippingFraction, unit: .fraction,
        algorithm: VersionedIdentifier(name: "different-scale", version: 2))
    #expect(throws: SessionArchiveError.incompatibleProfile) {
        try catalog.add(
            SessionArchiveSeries(
                profileIndex: 0, sourceIndex: 0, measurement: wrong, clock: .sourceSamples),
            payloadBytes: 1)
    }
    #expect(throws: SessionArchiveError.outOfOrder) {
        try catalog.add(
            SessionArchiveSeries(
                profileIndex: 9, sourceIndex: 0, measurement: generic.measurement,
                clock: .sourceSamples), payloadBytes: 1)
    }
    let wrongRate = try sessionTestSource(rate: 48000)
    try catalog.add(wrongRate, payloadBytes: canonicalContractJSON(wrongRate).count)
    #expect(throws: SessionArchiveError.incompatibleProfile) {
        try catalog.add(
            SessionArchiveSeries(
                profileIndex: 0, sourceIndex: 1, measurement: generic.measurement,
                clock: .sourceSamples), payloadBytes: 1)
    }
    #expect(catalog.series.isEmpty)
    try catalog.add(
        SessionArchiveSeries(
            profileIndex: 0, sourceIndex: 0, measurement: generic.measurement, clock: .sourceSamples
        ), payloadBytes: 1)
    #expect(catalog.series.count == 1)
}

@Test func sessionMetadataRefusesNoncanonicalUnknownAndFutureJSON() throws {
    let profile = try SessionArchiveProfile.levels(sessionTestLevel())
    let json = String(decoding: try canonicalContractJSON(profile), as: UTF8.self)
    for changed in [
        " " + json,
        json.replacingOccurrences(
            of: "\"kind\":\"levels\"", with: "\"kind\":\"levels\",\"kind\":\"levels\""),
        json.replacingOccurrences(
            of: "\"kind\":\"levels\"", with: "\"kind\":\"levels\",\"unknown\":0"),
        json.replacingOccurrences(of: "\"kind\":\"levels\"", with: "\"kind\":\"future-kernel\""),
    ] {
        #expect(throws: SessionArchiveError.malformedRecord) {
            _ = try decodeSessionMetadata(SessionArchiveProfile.self, from: Data(changed.utf8))
        }
    }
    let future = json.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
    #expect(throws: SessionArchiveError.unsupportedVersion) {
        _ = try decodeSessionMetadata(SessionArchiveProfile.self, from: Data(future.utf8))
    }
    let source = try sessionTestSource()
    #expect(
        try decodeSessionMetadata(SessionArchiveSource.self, from: canonicalContractJSON(source))
            == source)
}

@Test func sessionCoverageAndMaskValidationRetainsOverlappingEvidence() throws {
    let evidence = try SessionArchiveCoverage(
        source: 10, eligible: 8, selected: 5,
        tags: [
            .missingAcquisition: 2, .speechDetected: 8, .clipping: 7, .lowPeriodicityConfidence: 6,
        ])
    #expect(evidence.missing == 2 && evidence.excludedEligible == 3)
    #expect(evidence.samples(tag: .clipping) == 7 && evidence.samples(tag: .silence) == 0)
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveCoverage(
            source: 10, eligible: 8, selected: 9, tags: [.missingAcquisition: 2])
    }
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveCoverage(source: 10, eligible: 8, selected: 5)
    }
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveCoverage(source: 10, eligible: 10, selected: 5, tags: [.clipping: 11])
    }
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveTimestamp(secondsFromOrigin: .infinity)
    }
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveTimestamp(sourceSample: -1)
    }
    let identity = try sessionTestLevel().identity()
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveMask(
            planIdentity: identity, scope: .selected,
            policy: MaskSelectionPolicy(selectionSources: [0]), sources: [],
            effectiveDelaySeconds: 0)
    }
}

@Test func sessionCatalogDoesNotInventOriginalRateForStandaloneCepstralKernel() throws {
    let cpps = try CPPSProfile.murtonRecipePraat7(
        sourceSampleRate: 16000, declaredInputBandwidthHz: 8000)
    let recipe = SessionArchiveProfile.cpp(
        CPPProfile(frame: cpps.cepstrogram.frame, settings: cpps.settings.prominence))
    #expect(recipe.sourceSampleRate == nil)
    var catalog = try SessionArchiveCatalog(limits: SessionArchiveLimits())
    try catalog.add(recipe, payloadBytes: canonicalContractJSON(recipe).count)
    let source = try sessionTestSource()
    try catalog.add(source, payloadBytes: canonicalContractJSON(source).count)
    let series = try SessionArchiveSeries(
        profileIndex: 0, sourceIndex: 0,
        measurement: MeasurementDescriptor(
            kind: .cpp, unit: .decibelsRatio, algorithm: recipe.identity().identifier),
        clock: .secondsFromOrigin)
    try catalog.add(series, payloadBytes: canonicalContractJSON(series).count)
    let rawOnly = try YINProfile(
        estimator: YINConfiguration(
            sampleRate: 16000, inputPrecision: .float64,
            pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: 160))
    #expect(throws: SessionArchiveError.incompatibleProfile) {
        try catalog.add(.trackedYIN(rawOnly), payloadBytes: canonicalContractJSON(rawOnly).count)
    }
    #expect(catalog.profiles.count == 1)
}
