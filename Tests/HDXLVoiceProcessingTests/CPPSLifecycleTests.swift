import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func cppsIsolatedGridRejectsOmissionsInvalidInputAndReentry() throws {
    let epoch = StreamEpoch(streamID: UUID())
    let origin = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 0, sampleRate: 10_000)
    let source = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 1240, sampleRate: 10_000)
    let upstream = try CepstrogramConfiguration(
        sourceSampleRate: 10_000, declaredInputBandwidthHz: 5000)
    let profile = try CPPSProfile(
        cepstrogram: upstream,
        settings: CPPSConfiguration(
            prominence: CPPConfiguration(fitEndSeconds: 0, fitMethod: .leastSquares)))
    let worker = try PreparedCPPS(profile: profile, origin: origin)
    func context(_ index: Int) throws -> CepstralFrameContext {
        try CepstralFrameContext(
            origin: origin,
            timing: AnalysisTiming(source: source, includedSampleCount: source.sampleCount),
            frameIndex: UInt64(index), firstAnalysisSampleIndex: Int64(index * 20),
            suppliedAnalysisSampleCount: 1000, centerSecondsFromOrigin: 0.05 + Double(index) * 0.002
        )
    }
    let power = Array(repeating: 1.0, count: 513)
    var outputs = 0
    let receive: (BorrowedCPPSOutput) -> Void = { output in
        outputs += 1
        #expect(output.result.observation != nil)
        let before = Array(output.values(.smoothedPower))
        #expect(throws: CPPSError.reentrantCall) { try worker.reset(origin: origin) }
        #expect(throws: CPPSError.reentrantCall) {
            try worker.finish(source: source, expectedFrameCount: 13) { _ in
                Issue.record("Reentrant output")
            }
        }
        #expect(Array(output.values(.smoothedPower)) == before)
    }
    try power.withUnsafeBufferPointer { values in
        try worker.appendPowerCepstrum(
            values, context: context(0), sourceProfile: worker.sourceIdentity, emit: receive)
        #expect(worker.receivedFrameCount == 1 && worker.emittedFrameCount == 0)
        #expect(throws: CPPSError.incompleteInput) {
            try worker.finish(source: source, expectedFrameCount: 13, emit: receive)
        }
        #expect(throws: CPPSError.profileMismatch) {
            try worker.appendPowerCepstrum(
                values, context: context(1), sourceProfile: upstream.frame.identity(), emit: receive
            )
        }
        #expect(throws: CPPSError.unexpectedFrame) {
            try worker.appendPowerCepstrum(
                values, context: context(2), sourceProfile: worker.sourceIdentity, emit: receive)
        }
        var invalid = power
        invalid[7] = .nan
        #expect(throws: CPPSError.invalidInput) {
            try invalid.withUnsafeBufferPointer {
                try worker.appendPowerCepstrum(
                    $0, context: context(1), sourceProfile: worker.sourceIdentity, emit: receive)
            }
        }
        #expect(worker.receivedFrameCount == 1)
        for index in 1..<13 {
            try worker.appendPowerCepstrum(
                values, context: context(index), sourceProfile: worker.sourceIdentity, emit: receive
            )
        }
    }
    let completed = try worker.finish(source: source, expectedFrameCount: 13, emit: receive)
    #expect(outputs == 13 && completed.availableFrameCount == 13)
    #expect(abs(try #require(completed.meanDB)) < 1e-10)
    #expect(
        try worker.finish(source: source, expectedFrameCount: 13) { _ in
            Issue.record("Repeated finish")
        } == completed)
    try worker.reset(origin: origin)
    let empty = try worker.finish(source: origin, expectedFrameCount: 0) { _ in
        Issue.record("Empty interval emitted")
    }
    #expect(
        empty.frameCount == 0 && empty.meanDB == nil && empty.unavailability == .insufficientData)
}

@Test func cppsOwnedExportsUnitsBudgetsAndUnsupportedFit() throws {
    let epoch = StreamEpoch(streamID: UUID())
    let origin = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 0, sampleRate: 10_000)
    let source = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 1000, sampleRate: 10_000)
    let upstream = try CepstrogramConfiguration(
        sourceSampleRate: 10_000, declaredInputBandwidthHz: 5000)
    let context = try CepstralFrameContext(
        origin: origin,
        timing: AnalysisTiming(source: source, includedSampleCount: source.sampleCount),
        frameIndex: 0, firstAnalysisSampleIndex: 0, suppliedAnalysisSampleCount: 1000,
        centerSecondsFromOrigin: 0.05)
    let power = (0..<513).map { 1 + 20 * exp(-pow((Double($0) - 80) / 3, 2)) }
    let stages = Set(CPPSIntermediate.allCases)
    for unsupported in [false, true] {
        for pretrend in [false, true] {
            let profile = try CPPSProfile(
                cepstrogram: upstream,
                settings: CPPSConfiguration(
                    timeWindowSeconds: 0, quefrencyWindowSeconds: 0,
                    subtractTrendBeforeSmoothing: pretrend,
                    prominence: CPPConfiguration(
                        pitchFloorHz: unsupported ? 1 : 60,
                        pitchCeilingHz: unsupported ? 2 : 330, fitEndSeconds: 0,
                        fitMethod: .leastSquares)))
            let worker = try PreparedCPPS(profile: profile, origin: origin)
            var snapshots: [IntermediateSnapshot] = []
            var callbackError: (any Error)?
            try power.withUnsafeBufferPointer { input in
                try worker.appendPowerCepstrum(
                    input, context: context, sourceProfile: worker.sourceIdentity
                ) { output in
                    #expect(output.result.unavailability == (unsupported ? .unsupportedRange : nil))
                    #expect(Array(output.values(.rawPower)) == power)
                    #expect(output.values(.smoothedPower).isEmpty == unsupported)
                    #expect(throws: ContractError.intermediateBudgetExceeded) {
                        try output.export(stages: stages, policy: .disabled)
                    }
                    do {
                        #expect(try output.export(stages: [], policy: .disabled).isEmpty)
                        let count = (unsupported ? 1 : 7) * 513
                        #expect(throws: ContractError.intermediateBudgetExceeded) {
                            try output.export(
                                stages: stages,
                                policy: IntermediateOutputPolicy(maximumScalarCount: count - 1))
                        }
                        snapshots = try output.export(
                            stages: stages,
                            policy: IntermediateOutputPolicy(maximumScalarCount: count))
                    } catch { callbackError = error }
                }
            }
            if let callbackError { throw callbackError }
            #expect(snapshots.count == (unsupported ? 1 : 7))
            for snapshot in snapshots {
                let stage = try #require(
                    CPPSIntermediate(rawValue: String(snapshot.stage.name.dropFirst(5))))
                let unit: MeasurementUnit =
                    pretrend && stage != .rawPower && stage.unit == .inverseSecondsSquared
                    ? .dimensionless : stage.unit
                #expect(snapshot.yUnit == unit && snapshot.source == source)
                #expect(snapshot.values.count == 513)
            }
            let original = snapshots
            try worker.finish(source: source, expectedFrameCount: 1) { _ in
                Issue.record("Unexpected second frame")
            }
            try worker.reset(origin: origin)
            try power.map { $0 * 2 }.withUnsafeBufferPointer {
                try worker.appendPowerCepstrum(
                    $0, context: context, sourceProfile: worker.sourceIdentity
                ) { _ in }
            }
            #expect(snapshots == original)
            #expect(snapshots.first?.values == power)
        }
    }
}
