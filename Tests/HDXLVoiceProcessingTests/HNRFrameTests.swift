import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct HNRImpulseProof: Encodable {
    let definition = "singleImpulseFlatCCLagCurve"
    let impulseIndex, meanSamples, windowSamples, comparedLagCount: Int
    let expectedCorrelation, maximumCurveError: Double
}
private struct HNRNativeFrameAudit: Encodable {
    let name: String
    let inputSHA256: String
    let configuration: HNRConfiguration
    let profileIdentity: ProfileIdentity
    let frameIndex: Int
    let expectedCenterSeconds, actualCenterSeconds: Double
    let expectedStatus, actualStatus: String
    let actualDecibelStatus: HNRDecibelStatus?
    let expectedDB, actualDB: Double?
    let budgetFraction: Double?
    let proof: HNRImpulseProof?
}
private struct HNRNativeAudit: Encodable {
    let schemaVersion = 1
    let status = "qualified"
    let cases: Int
    let frames: Int
    let documentedReferenceDisagreements: Int
    let rows: [HNRNativeFrameAudit]
}

private func hnrProveFlatImpulse<Sample: BinaryFloatingPoint & Sendable>(
    samples: [Sample], output: BorrowedHNROutput
) -> HNRImpulseProof? {
    let layout = output.result.layout
    let c = layout.configuration
    guard c.method == .forwardCrossCorrelation, output.result.selectedObservation == nil,
        output.candidates.allSatisfy({ $0.estimate == nil }),
        layout.computedMaximumLag == c.maximumCandidateLag
    else { return nil }
    let positions = samples.indices.filter { samples[$0] != 0 }
    guard positions.count == 1 else { return nil }
    let i = positions[0]
    let k = c.localMeanSampleCount
    let n = c.windowSampleCount
    guard i >= layout.localMeanStartSample, i < layout.localMeanStartSample + k,
        i >= layout.correlationStartSample + layout.computedMaximumLag,
        i < layout.correlationStartSample + n
    else { return nil }
    let expectedMean = Double(samples[i]) / Double(k) / output.result.frameAmplitudeScale
    guard abs(output.result.scaledLocalMean - expectedMean) < 2e-15 else { return nil }
    let expected = Double(n - 2 * k) / Double(k * k - 2 * k + n)
    guard expected > 0, expected < 1, output.correlation.count > layout.computedMaximumLag else {
        return nil
    }
    let maximumError = (1...layout.computedMaximumLag).map {
        abs(output.correlation[$0] - expected)
    }.max()!
    guard
        (1...layout.computedMaximumLag).allSatisfy({
            output.correlationValidity[$0] && abs(output.correlation[$0] - expected) <= 2e-14
        })
    else { return nil }
    return HNRImpulseProof(
        impulseIndex: i, meanSamples: k, windowSamples: n,
        comparedLagCount: layout.computedMaximumLag, expectedCorrelation: expected,
        maximumCurveError: maximumError)
}

private func hnrCompareFrames<Sample: BinaryFloatingPoint & Sendable>(
    _ record: HNRReferenceRecord, samples: [Sample]
) throws -> [HNRNativeFrameAudit] {
    let c = try record.case.profile.native()
    let worker = try PreparedHNR<Sample>(c)
    let layout = try HNRIntervalLayout(configuration: c, sampleCount: samples.count)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 101,
        sampleCount: Int64(samples.count), sampleRate: Double(c.sampleRate))
    let timing = try AnalysisTiming(
        source: source, includedSampleCount: source.sampleCount,
        sourceStartSeconds: 12.5, hostStartNanoseconds: 1_000_000_000,
        completedHostNanoseconds: 3_000_000_000)
    let reference = try samples.withUnsafeBufferPointer {
        try HNRNormalization($0, timing: timing, definition: .wholeInterval)
    }
    var audits: [HNRNativeFrameAudit] = []
    try samples.withUnsafeBufferPointer { input in
        for (index, expected) in record.data.frames.enumerated() {
            let frame = try layout.frame(at: index)
            try worker.analyze(
                UnsafeBufferPointer(rebasing: input[frame.support]), layout: frame,
                normalization: reference
            ) { output in
                #expect(
                    output.result.centerSecondsFromNormalizationOrigin == expected.centerSeconds)
                #expect(output.result.dependencyTiming.source == source)
                #expect(
                    output.result.frameTiming.source.startSample == source.startSample
                        + Int64(frame.support.lowerBound))
                #expect(output.result.centerSourceSeconds == 12.5 + expected.centerSeconds)
                let selected = output.result.selectedObservation
                let proof =
                    expected.status == "finite" && selected == nil
                    ? hnrProveFlatImpulse(samples: samples, output: output) : nil
                var budgetFraction: Double?
                var state = "unavailable"
                defer {
                    audits.append(
                        HNRNativeFrameAudit(
                            name: record.case.name,
                            inputSHA256: record.input.encodedSHA256, configuration: c,
                            profileIdentity: worker.identity, frameIndex: index,
                            expectedCenterSeconds: expected.centerSeconds,
                            actualCenterSeconds: output.result.centerSecondsFromNormalizationOrigin,
                            expectedStatus: expected.status, actualStatus: state,
                            actualDecibelStatus: selected?.status,
                            expectedDB: expected.valueDB,
                            actualDB: selected?.referenceReportingDecibels,
                            budgetFraction: budgetFraction, proof: proof))
                }
                switch selected?.status {
                case nil: state = "unavailable"
                case .finite: state = "finite"
                case .upperReportingLimit, .numericalZeroNoise: state = "upperReportingLimit"
                case .lowerReportingLimit: state = "lowerReportingLimit"
                }
                if proof != nil { return }
                budgetFraction = state == expected.status ? 0 : nil
                #expect(
                    state == expected.status,
                    "\(record.case.name), frame \(index), native \(String(describing: selected)), reference \(expected.rawReferenceDB)"
                )
                if let selected, let db = expected.valueDB, expected.status == "finite" {
                    let actual = selected.referenceReportingDecibels
                    let fraction: Double
                    if abs(db) <= 60 {
                        fraction = abs(actual - db) / 1e-4
                    } else {
                        func energyFraction(_ value: Double) -> Double {
                            1 / (1 + pow(10, (db > 0 ? value : -value) / 10))
                        }
                        let wanted = energyFraction(db)
                        fraction = abs(energyFraction(actual) - wanted) / (2e-14 + 1e-4 * wanted)
                    }
                    budgetFraction = fraction
                    #expect(
                        fraction <= 1,
                        "\(record.case.name), frame \(index), native \(actual), reference \(db), budget fraction \(fraction)"
                    )
                }
            }
        }
    }
    #expect(worker.executionStatistics.analyzedFrameCount == UInt64(layout.frameCount))
    return audits
}

@Test func hnrPreparedFramesConformToAllExternalCasesWithProvedDisagreements() throws {
    let directory = try hnrFixtureDirectory("HNR")
    struct Manifest: Decodable { let catalog: [HNRReferenceCase] }
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    var rows: [HNRNativeFrameAudit] = []
    for item in manifest.catalog {
        let record = try JSONDecoder().decode(
            HNRReferenceRecord.self,
            from: Data(contentsOf: directory.appending(path: item.name + ".json")))
        let samples = try hnrReferenceSamples(record, directory: directory)
        let counts: [HNRNativeFrameAudit]
        switch item.profile.inputPrecision {
        case .float32: counts = try hnrCompareFrames(record, samples: samples.map(Float.init))
        case .float64: counts = try hnrCompareFrames(record, samples: samples)
        }
        rows += counts
    }
    let disagreements = rows.filter { $0.proof != nil }.count
    #expect(rows.count == 4113 && disagreements == 6)
    if let path = ProcessInfo.processInfo.environment["HDXL_HNR_REFERENCE_REPORT"] {
        let report = HNRNativeAudit(
            cases: manifest.catalog.count, frames: rows.count,
            documentedReferenceDisagreements: disagreements, rows: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to: URL(filePath: path), options: .atomic)
    }
}

@Test func hnrPreparedFrameOwnershipValidationAndClockDependencies() throws {
    let directory = try hnrFixtureDirectory("HNR")
    let record = try JSONDecoder().decode(
        HNRReferenceRecord.self,
        from: Data(contentsOf: directory.appending(path: "noisy-0.05-cc-float64.json")))
    let samples = try hnrReferenceSamples(record, directory: directory)
    let c = try record.case.profile.native()
    let worker = try PreparedHNR<Double>(c)
    let layout = try HNRIntervalLayout(configuration: c, sampleCount: samples.count)
    let frame = try layout.frame(at: layout.frameCount / 2)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()),
        startSample: Int64.max - Int64(samples.count), sampleCount: Int64(samples.count),
        sampleRate: 16000)
    let timing = try AnalysisTiming(
        source: source, includedSampleCount: source.sampleCount,
        sourceStartSeconds: 500, hostStartNanoseconds: 1_000_000_000,
        completedHostNanoseconds: 2_000_000_000)
    let reference = try samples.withUnsafeBufferPointer {
        try HNRNormalization($0, timing: timing, definition: .wholeInterval)
    }
    var owned: [HNRPeakCandidate] = []
    var result: HNRFrameResult?
    try samples.withUnsafeBufferPointer { input in
        let slice = UnsafeBufferPointer(rebasing: input[frame.support])
        try worker.analyze(slice, layout: frame, normalization: reference) { output in
            result = output.result
            #expect(throws: HNRError.reentrantCall) {
                try worker.analyze(slice, layout: frame, normalization: reference) { _ in }
            }
            #expect(throws: ContractError.intermediateBudgetExceeded) {
                try output.exportCandidates(maximumCount: 0)
            }
            owned = (try? output.exportCandidates(maximumCount: 1000)) ?? []
        }
        let previous = owned
        try worker.analyze(slice, layout: frame, normalization: reference) { _ in }
        #expect(owned == previous && !owned.isEmpty)
        #expect(throws: HNRError.invalidBufferSize) {
            try worker.analyze(
                UnsafeBufferPointer(rebasing: slice.dropLast()), layout: frame,
                normalization: reference
            ) { _ in }
        }
    }
    let r = try #require(result)
    #expect(r.frameTiming.source.endSample <= Int64.max)
    #expect(r.dependencyTiming.source == source)
    #expect(r.dependencyTiming.effectiveDelaySeconds >= source.durationSeconds / 2)
    #expect(r.frameTiming.sourceStartSeconds == 500 + Double(frame.support.lowerBound) / 16000)
    #expect(
        r.frameTiming.hostStartNanoseconds == 1_000_000_000
            + UInt64((Double(frame.support.lowerBound) / 16000 * 1e9).rounded()))
    let measurement = try r.measurementResult()
    #expect(measurement.measurement.kind == .harmonicToNoiseRatio)
    #expect(measurement.timing == r.dependencyTiming && measurement.outcome.estimate != nil)
    #expect(throws: HNRError.precisionMismatch) { try PreparedHNR<Float>(c) }
    let invalid = Array(repeating: Double.nan, count: samples.count)
    #expect(throws: HNRError.invalidInput) {
        try invalid.withUnsafeBufferPointer {
            try HNRNormalization($0, timing: timing, definition: .wholeInterval)
        }
    }
}

@Test func hnrFiniteCausalWindowAndExtremeAmplitudeScalingAreExplicit() throws {
    for method in HNRMethod.allCases {
        let c = try HNRConfiguration(
            method: method, sampleRate: 4000, pitchFloorHz: 500,
            periodsPerWindow: 2, normalization: .causalWindow)
        let frame = try c.causalFrameLayout(frameIndex: 17)
        let source = try SourceInterval(
            epoch: StreamEpoch(streamID: UUID()), startSample: 900,
            sampleCount: Int64(c.causalWindowSampleCount), sampleRate: 4000)
        let timing = try AnalysisTiming(
            source: source, includedSampleCount: source.sampleCount,
            sourceStartSeconds: 9, hostStartNanoseconds: 1_000_000_000,
            completedHostNanoseconds: 2_000_000_000)
        let worker = try PreparedHNR<Double>(c)
        var baseline: Double?
        for amplitude in [
            1.0, pow(2.0, 900.0), pow(2.0, -900.0), Double.leastNonzeroMagnitude * 128,
        ] {
            let cycle = [amplitude, 0, -amplitude, 0]
            let samples = (0..<c.causalWindowSampleCount).map { cycle[$0 % 4] }
            try samples.withUnsafeBufferPointer { input in
                let reference = try HNRNormalization(
                    input, timing: timing, definition: .causalWindow)
                try worker.analyze(
                    UnsafeBufferPointer(rebasing: input[frame.support]), layout: frame,
                    normalization: reference
                ) { output in
                    #expect(output.result.frameIndex == 17)
                    #expect(output.result.dependencyTiming.source == source)
                    #expect(output.result.centerSourceSeconds == 9 + frame.centerSecondsFromOrigin)
                    #expect(output.result.relativeIntensity.isFinite)
                    #expect(output.result.selectedObservation != nil)
                    if let selected = output.result.selectedObservation {
                        #expect(selected.referenceReportingDecibels.isFinite)
                        if let baseline {
                            #expect(abs(selected.periodicity - baseline) <= 2e-14)
                        } else {
                            baseline = selected.periodicity
                        }
                    }
                }
            }
        }
        #expect(throws: HNRError.unexpectedContext) { try c.causalFrameLayout(frameIndex: -1) }
        #expect(throws: HNRError.unexpectedContext) {
            try HNRFrameLayout(
                configuration: c, count: c.causalWindowSampleCount, index: 0, center: .nan)
        }
        #expect(throws: HNRError.unexpectedContext) {
            try HNRFrameLayout(configuration: c, count: -1, index: 0, center: 0)
        }
        let partial = try AnalysisTiming(
            source: source, includedSampleCount: source.sampleCount - 1)
        #expect(throws: HNRError.unexpectedContext) {
            try Array(repeating: 0.0, count: c.causalWindowSampleCount).withUnsafeBufferPointer {
                try HNRNormalization($0, timing: partial, definition: .causalWindow)
            }
        }
    }
}
