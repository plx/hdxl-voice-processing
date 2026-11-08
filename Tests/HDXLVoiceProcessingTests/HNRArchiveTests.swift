import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func hnrArchiveRecipesRoundTripDistinctMethodsNormalizationsAndPopulationPolicy() throws {
    var identities: Set<ProfileIdentity> = []
    for method in HNRMethod.allCases {
        for normalization in [HNRNormalizationDefinition.wholeInterval, .causalWindow] {
            let c = try HNRConfiguration(
                method: method, sampleRate: 16000, normalization: normalization)
            let statistic = try HNRStatisticProfile(
                measurement: c, population: .allEligible,
                selection: MaskSelectionPolicy(), provenances: [])
            for profile in [SessionArchiveProfile.hnr(c), .hnrStatistic(statistic)] {
                let data = try canonicalContractJSON(profile)
                #expect(try JSONDecoder().decode(SessionArchiveProfile.self, from: data) == profile)
                #expect(profile.sourceSampleRate == 16000)
                let identity = try profile.identity()
                identities.insert(identity)
                #expect(
                    try profile.descriptors() == [
                        MeasurementDescriptor(
                            kind: .harmonicToNoiseRatio,
                            unit: .decibelsRatio, algorithm: identity.identifier)
                    ])
            }
        }
    }
    #expect(identities.count == 8)
}

@Test func hnrScheduledArchivePreservesRawMethodWholeDependencyCentersAndUnavailableTails() throws {
    for method in HNRMethod.allCases {
        for normalization in [HNRNormalizationDefinition.wholeInterval, .causalWindow] {
            let source = try sessionTestSource(start: (1 << 54) + 39, rate: 4000)
            let c = try HNRConfiguration(
                method: method, sampleRate: 4000,
                pitchFloorHz: 500, periodsPerWindow: 2, hopSeconds: 0.005,
                normalization: normalization)
            let profile = try AnalysisScheduleProfile(
                inputFormat: PCMFormat(
                    sampleRate: 4000,
                    channelCount: 1, encoding: .float64), channels: .arithmeticMean, hnr: c)
            let count = 201
            let worker = try PreparedAnalysisSchedule<Double>(
                profile: profile, origin: source.origin,
                mode: .finite, expectedSampleCount: Int64(count), sourceTileCapacity: 31)
            let support = try SourceInterval(
                epoch: source.origin.source.epoch,
                startSample: source.origin.source.startSample, sampleCount: Int64(count),
                sampleRate: 4000)
            var frames: [ScheduledFrame] = []
            let pcm = (0..<count).map {
                0.3 * sin(Double($0) * 2 * .pi / 7) + 0.04 * cos(Double($0) * 2 * .pi / 3.2)
            }
            try pcm.withUnsafeBufferPointer {
                try worker.processInterleaved($0, interval: support) { frames.append($0) }
            }
            try worker.finish { frames.append($0) }
            var catalog = try SessionArchiveCatalog(limits: SessionArchiveLimits())
            let recipe = SessionArchiveProfile.schedule(profile)
            try catalog.add(recipe, payloadBytes: canonicalContractJSON(recipe).count)
            try catalog.add(source, payloadBytes: canonicalContractJSON(source).count)
            let series = try SessionArchiveSeries(
                profileIndex: 0, sourceIndex: 0,
                measurement: MeasurementDescriptor(
                    kind: .harmonicToNoiseRatio, unit: .decibelsRatio,
                    algorithm: c.identity().identifier), clock: .secondsFromOrigin,
                isScheduled: true)
            try catalog.add(series, payloadBytes: canonicalContractJSON(series).count)
            var centers: [Double] = []
            var dependencies: Set<SourceInterval> = []
            var sawUnavailable = false
            for frame in frames {
                let exported = try frame.export(.harmonicToNoiseRatio)
                let value = try SessionArchiveMeasurement(exported, source: source, series: series)
                let encoded = try SessionArchiveScalarWire.encode(
                    value, seriesIndex: 0, catalog: catalog)
                let (index, decoded) = try SessionArchiveScalarWire.decode(
                    encoded, catalog: catalog)
                #expect(index == 0 && value == decoded)
                #expect(try decoded.result.measurement.algorithm == c.identity().identifier)
                let metadata = try #require(decoded.scheduled)
                centers.append(metadata.frameCenterSecondsFromOrigin)
                dependencies.insert(metadata.dependencyTiming.source)
                if case .unavailable = decoded.result.outcome { sawUnavailable = true }
                catalog.accepted(decoded, seriesIndex: 0)
            }
            #expect(frames.count > 1 && Set(centers).count == frames.count)
            if normalization == .wholeInterval {
                #expect(dependencies == [support])
            } else {
                #expect(sawUnavailable && dependencies.count == frames.count)
            }
        }
    }
}
