import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func swipePrimeArchivePreservesRecipeAndScheduledScalarAvailability() throws {
    let source = try sessionTestSource(start: (1 << 54) + 44, rate: 4000)
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 100, pitchCeilingHz: 500,
        hopLength: 40, strengthThreshold: 0.99)
    let standalone = SessionArchiveProfile.swipePrime(c)
    #expect(try standalone.identity() == c.identity())
    #expect(standalone.sourceSampleRate == 4000)
    #expect(
        try JSONDecoder().decode(
            SessionArchiveProfile.self, from: canonicalContractJSON(standalone)) == standalone)
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 4000, channelCount: 1, encoding: .float64),
        channels: .arithmeticMean, swipePrime: c)
    let recipe = SessionArchiveProfile.schedule(profile)
    #expect(
        try JSONDecoder().decode(SessionArchiveProfile.self, from: canonicalContractJSON(recipe))
            == recipe)
    let descriptor = try MeasurementDescriptor(
        kind: .fundamentalFrequency, unit: .hertz, algorithm: c.identity().identifier)
    #expect(try standalone.descriptors() == [descriptor] && recipe.descriptors() == [descriptor])
    let count = c.requiredSampleCount + 1
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: source.origin,
        mode: .finite, expectedSampleCount: Int64(count), sourceTileCapacity: 31)
    let support = try SourceInterval(
        epoch: source.origin.source.epoch, startSample: source.origin.source.startSample,
        sampleCount: Int64(count), sampleRate: 4000)
    let pcm = (0..<count).map { 0.3 * sin(2 * .pi * 250 * Double($0) / 4000) }
    var frames: [ScheduledFrame] = []
    try pcm.withUnsafeBufferPointer {
        _ = try worker.processInterleaved($0, interval: support) { frames.append($0) }
    }
    try worker.finish { frames.append($0) }
    var catalog = try SessionArchiveCatalog(limits: SessionArchiveLimits())
    try catalog.add(recipe, payloadBytes: canonicalContractJSON(recipe).count)
    try catalog.add(source, payloadBytes: canonicalContractJSON(source).count)
    let series = try SessionArchiveSeries(
        profileIndex: 0, sourceIndex: 0, measurement: descriptor,
        clock: .secondsFromOrigin, isScheduled: true)
    try catalog.add(series, payloadBytes: canonicalContractJSON(series).count)
    var available = 0
    var missing = 0
    for frame in frames {
        let export = try frame.export(.fundamentalFrequency)
        let value = try SessionArchiveMeasurement(export, source: source, series: series)
        let wire = try SessionArchiveScalarWire.encode(value, seriesIndex: 0, catalog: catalog)
        let (index, decoded) = try SessionArchiveScalarWire.decode(wire, catalog: catalog)
        #expect(index == 0 && decoded == value && decoded.result == export.result)
        #expect(decoded.scheduled?.dependencyTiming == frame.timing)
        if case .available(let estimate) = decoded.result.outcome {
            available += 1
            #expect(estimate.confidence == nil && estimate.warnings == [.lowConfidence])
        } else {
            missing += 1
            #expect(decoded.result.outcome == .unavailable(.insufficientData))
        }
        catalog.accepted(decoded, seriesIndex: 0)
    }
    #expect(available == 1 && missing == 1)
}
