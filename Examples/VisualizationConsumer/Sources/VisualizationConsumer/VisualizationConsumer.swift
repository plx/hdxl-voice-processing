import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization
import Observation
import Synchronization

/// Synthetic adapter/publication evidence only. No rendering, DSP, session or audio import.
@main struct VisualizationConsumer {
    struct Sample: Encodable {
        let phase: String
        let count: Int
        let iterations: Int
        let warmups: Int
        let minimumNanoseconds: UInt64
        let medianNanoseconds: UInt64
        let p95Nanoseconds: UInt64
        let maximumNanoseconds: UInt64
        let consumedCount: Int
        let observerInvalidations: Int
    }

    struct Report: Encodable {
        let schemaVersion = 1
        let syntheticOnly = true
        let dspCaptureOrRenderingExecuted = false
        let status = "passed"
        let profileSHA256: String
        let samples: [Sample]
    }

    static let epoch = StreamEpoch(
        streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!, sequence: 1)
    static let start: Int64 = (1 << 54) + 53

    static func source(_ offset: Int64, _ count: Int64) throws -> SourceInterval {
        try SourceInterval(
            epoch: epoch, startSample: start + offset, sampleCount: count, sampleRate: 16000)
    }

    static func profile() throws -> AnalysisProfile {
        try AnalysisProfile(
            identifier: VersionedIdentifier(name: "synthetic-visualization-evidence", version: 1),
            measurement: MeasurementDescriptor(
                kind: .rms, unit: .normalizedAmplitude,
                algorithm: VersionedIdentifier(name: "fixture-rms", version: 1)),
            inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1),
            channels: PCMChannelSelection(channelIndex: 0), precision: .float64,
            frameLength: 400, hopLength: 160, analysisSampleRate: 16000,
            window: VersionedIdentifier(name: "rectangular", version: 1), preprocessing: [:],
            algorithmSettings: ["syntheticOnly": .boolean(true)],
            partialWindowPolicy: .emitUnavailable)
    }

    static func records(_ count: Int, profile: AnalysisProfile) throws -> [VisualizationMeasurement]
    {
        let identity = try profile.identity()
        return try (0..<count).map { index in
            let missing = index.isMultiple(of: 257)
            return VisualizationMeasurement(
                try MeasurementResult(
                    measurement: profile.measurement, profile: identity,
                    timing: AnalysisTiming(
                        source: source(Int64(index) * 160, 400),
                        includedSampleCount: missing ? 0 : 400),
                    outcome: missing
                        ? .unavailable(.missingAcquisition)
                        : .available(ScalarEstimate(value: 0.25, confidence: 0.8))))
        }
    }

    /// Input preparation is excluded. The result count escapes every operation so
    /// validation/publication cannot be replaced by unused construction in the caller.
    @MainActor static func measure(
        phase: String, count: Int, iterations: Int = 100,
        observerCount: () -> Int = { 0 }, operation: () throws -> Int
    ) rethrows -> Sample {
        let warmups = 3
        for _ in 0..<warmups { _ = try operation() }
        let before = observerCount()
        var durations: [UInt64] = []
        durations.reserveCapacity(iterations)
        var consumed = 0
        for _ in 0..<iterations {
            let began = DispatchTime.now().uptimeNanoseconds
            consumed += try operation()
            durations.append(DispatchTime.now().uptimeNanoseconds - began)
        }
        durations.sort()
        precondition(consumed == count * iterations)
        return Sample(
            phase: phase, count: count, iterations: iterations, warmups: warmups,
            minimumNanoseconds: durations[0], medianNanoseconds: durations[iterations / 2],
            p95Nanoseconds: durations[(iterations * 95 + 99) / 100 - 1],
            maximumNanoseconds: durations[iterations - 1], consumedCount: consumed,
            observerInvalidations: observerCount() - before)
    }

    @MainActor static func run() throws -> Report {
        let profile = try profile()
        let identity = try profile.identity()
        var samples: [Sample] = []
        for count in [128, 4096] {
            let preparedRows = try records(count + 1, profile: profile)
            let rows = Array(preparedRows.prefix(count))
            let series = rows[0].id.series
            let missing = rows.filter { $0.numericValue == nil }.count
            precondition(missing == (count + 256) / 257)
            samples.append(
                try measure(phase: "metricConstruction", count: count) {
                    let snapshot = try VisualizationMetricSnapshot(
                        series: series, measurements: rows)
                    precondition(
                        snapshot.measurements.last?.result.timing.source.startSample
                            == start + Int64(count - 1) * 160)
                    return snapshot.measurements.count
                })

            let snapshot = try VisualizationMetricSnapshot(series: series, measurements: rows)
            let shifted = try VisualizationMetricSnapshot(
                series: series, measurements: Array(preparedRows.suffix(count)))
            let store = VisualizationMetricStore(snapshot: snapshot)
            try store.inspect(rows[count / 2].id)
            let invalidations = Mutex(0)
            var publishShifted = false
            samples.append(
                measure(
                    phase: "mainActorPublicationWithObserver", count: count, iterations: 1000,
                    observerCount: { invalidations.withLock { $0 } }
                ) {
                    withObservationTracking {
                        _ = store.snapshot.measurements.count
                    } onChange: {
                        invalidations.withLock { $0 += 1 }
                    }
                    publishShifted.toggle()
                    store.replace(publishShifted ? shifted : snapshot, state: .running)
                    precondition(store.inspectedMeasurement?.id == rows[count / 2].id)
                    return store.snapshot.measurements.count
                })
        }
        let stage = try VersionedIdentifier(name: "synthetic-mono-waveform", version: 1)
        for count in [4096, 262_144] {
            let values = (0..<count).map { Double($0 % 17) / 32 }
            let support = try source(0, Int64(count))
            samples.append(
                try measure(phase: "ownedWaveformConstruction", count: count) {
                    let snapshot = try VisualizationFrameSnapshot(
                        waveform: values, source: support, profile: identity, stage: stage)
                    precondition(snapshot.values.last == values.last)
                    return snapshot.values.count
                })
            let intermediate = try IntermediateSnapshot(
                stage: stage, source: support, xUnit: .seconds, yUnit: .normalizedAmplitude,
                xOrigin: 0, xStep: 1 / support.sampleRate, values: values)
            samples.append(
                try measure(phase: "validatedFrameAdaptation", count: count) {
                    let snapshot = try VisualizationFrameSnapshot(
                        intermediate: intermediate, profile: identity, domain: .waveform)
                    precondition(snapshot.source == support && snapshot.values.last == values.last)
                    return snapshot.values.count
                })
        }
        return Report(profileSHA256: identity.sha256, samples: samples)
    }

    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--output" else {
            throw CocoaError(.coderInvalidValue)
        }
        let report = try run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Verified eight synthetic visualization workloads; no capture, DSP or rendering.")
    }
}
