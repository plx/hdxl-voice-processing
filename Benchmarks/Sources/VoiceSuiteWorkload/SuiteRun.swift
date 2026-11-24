import Foundation
import HDXLVoiceProcessing

/// Only immutable input and profiles are shared. Every run constructs its own mutable analysis plans.
struct TypedSuiteInput<S: BinaryFloatingPoint & Sendable>: SuiteInput {
    let fixture: SuiteFixture
    let recipe: SuiteRecipe
    let samples: [S]

    init(_ fixture: SuiteFixture, _ composition: SuiteComposition, _ samples: [S]) throws {
        self.fixture = fixture
        recipe = try SuiteRecipe(fixture, composition)
        self.samples = samples
    }

    func run(chunk: Int, diagnostics: RuntimeDiagnosticMode) throws -> SuiteResult {
        guard chunk > 0 else { throw SuiteError.invalidInput("chunk") }
        var result = SuiteResult()
        var epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000055")!)
        try samples.withUnsafeBufferPointer { input in
            for repetition in 0..<fixture.repeats {
                for region in fixture.regions {
                    let part = UnsafeBufferPointer(
                        rebasing: input[region.start..<(region.start + region.count)])
                    let base = Int64(repetition * fixture.sampleCount + region.start)
                    let source = try SourceInterval(
                        epoch: epoch, startSample: 0, sampleCount: Int64(part.count),
                        sampleRate: Double(fixture.sampleRate))
                    try runRegion(
                        part, source: source, base: base, chunk: chunk, diagnostics: diagnostics,
                        result: &result)
                    result.epochs += 1
                    result.analyzedSamples += part.count
                    epoch = try epoch.successor()
                }
            }
        }
        return result
    }

    private func runRegion(
        _ pcm: UnsafeBufferPointer<S>, source: SourceInterval, base: Int64,
        chunk: Int, diagnostics: RuntimeDiagnosticMode, result: inout SuiteResult
    ) throws {
        let origin = try AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: source.epoch, startSample: 0,
                sampleCount: 0, sampleRate: source.sampleRate), continuityEpoch: source.epoch)
        let worker = try PreparedAnalysisSchedule<S>(
            profile: recipe.schedule, origin: origin,
            mode: .finite, expectedSampleCount: source.sampleCount, diagnosticMode: diagnostics)
        let extras = try recipe.extensions.map {
            try SuiteRegionExtensions<S>(
                $0, source: source, separateSpectra: recipe.composition == .separateSpectra,
                diagnostics: diagnostics)
        }
        let rolling = try PreparedRollingCPPS(
            profile: recipe.rollingCPPS, origin: origin.source, diagnosticMode: diagnostics)
        let mask = try MaskTimeline(
            MaskPlan(
                source: source, provenances: [], policy: recipe.rollingCPPS.selection,
                observations: []))
        var callbackError: (any Error)?
        var pitches: [YINFrameResult] = []
        func consume(_ frame: ScheduledFrame) {
            guard callbackError == nil else { return }
            switch frame.value {
            case .cpps(let value):
                let at = base + value.context.timing.source.startSample
                result.record("cpp", value.rawCPP.observation?.prominenceDB, at: at)
                result.record("cpps", value.observation?.prominenceDB, at: at)
                result.robustFitSlopesPerFit = max(
                    result.robustFitSlopesPerFit, value.rawCPP.layout.slopeEvaluationCount)
                let center = Int64(floor(value.context.centerSecondsFromOrigin * source.sampleRate))
                let clock = max(value.context.timing.source.endSample, center + 1)
                do {
                    try rolling.append(value)
                    let estimate = try rolling.result(atSourceSample: clock, mask: mask)
                    result.record("rollingCPPS", estimate.meanDB, at: base + clock)
                } catch { callbackError = error }
            case .levels(let value):
                let at = base + value.source.startSample
                result.record("peak", value.peakAmplitude.estimate?.value, at: at)
                result.record("rms", value.unweighted.rms.estimate?.value, at: at)
                result.record("meanSquare", value.unweighted.meanSquare.estimate?.value, at: at)
                result.record(
                    "kWeightedMeanSquare", value.weighted?.meanSquare.estimate?.value, at: at)
                result.record("levelDBFS", value.unweighted.digitalLevel.finiteDecibels, at: at)
                result.record("samplePeakDBFS", value.samplePeakDBFS.finiteDecibels, at: at)
                result.record("clippingFraction", value.possibleClippingFraction, at: at)
                result.record("crest", value.crestFactor.estimate?.value, at: at)
            case .pitch(let raw, let tracked):
                let at = base + raw.timing.source.startSample
                result.record("yin", raw.observation?.frequencyHz, at: at)
                result.record("trackedYin", tracked?.observation?.frequencyHz, at: at)
                if extras != nil { pitches.append(raw) }
            case .hnr(let value):
                let at = base + value.dependencyTiming.source.startSample
                switch value {
                case .frame(let output):
                    result.record("hnrPeriodicity", output.selectedObservation?.periodicity, at: at)
                    result.record("hnrDB", output.selectedObservation?.finiteDecibels, at: at)
                case .unavailable:
                    result.record("hnrPeriodicity", nil, at: at)
                    result.record("hnrDB", nil, at: at)
                }
            case .swipePrime(let value):
                result.record(
                    "swipePrime", value.observation?.frequencyHz,
                    at: base + value.timing.source.startSample)
            }
        }
        var start = 0
        while start < pcm.count {
            let count = min(chunk, pcm.count - start)
            let interval = try SourceInterval(
                epoch: source.epoch, startSample: Int64(start),
                sampleCount: Int64(count), sampleRate: source.sampleRate)
            let part = UnsafeBufferPointer(rebasing: pcm[start..<(start + count)])
            _ = try worker.processInterleaved(part, interval: interval, emit: consume)
            if let callbackError { throw callbackError }
            try extras?.process(part, interval: interval, base: base, result: &result)
            start += count
        }
        _ = try worker.finish(emit: consume)
        if let callbackError { throw callbackError }
        try extras?.finish(pcm, source: source, pitches: pitches, base: base, result: &result)
    }
}
