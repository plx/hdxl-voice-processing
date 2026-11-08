import Foundation
import HDXLVoiceProcessing
import SwiftUI

public enum VisualizationPreviewScenario: String, Sendable, Hashable, CaseIterable {
    case valid, noData, gap, unsupported, failure, longLabel, loading, paused, interrupted
}

/// Explicit synthetic contract data. These values are not analysis of a voice or
/// a calibrated target. Fixture generation is deterministic and has no live services.
public struct VisualizationPreviewFixture: Sendable {
    public let scenario: VisualizationPreviewScenario
    public let title: String
    public let snapshot: VisualizationMetricSnapshot
    public let state: VisualizationState

    public static func make(_ scenario: VisualizationPreviewScenario) throws -> Self {
        let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
        let kind: MeasurementKind = scenario == .unsupported ? .harmonicToNoiseRatio : .cpps
        let profile = try AnalysisProfile(
            identifier: VersionedIdentifier(name: "synthetic-preview-only", version: 1),
            measurement: MeasurementDescriptor(
                kind: kind, unit: .decibelsRatio,
                algorithm: VersionedIdentifier(
                    name: scenario == .unsupported ? "fixture-hnr" : "fixture-cpps", version: 1)),
            inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1),
            channels: PCMChannelSelection(channelIndex: 0), precision: .float64,
            frameLength: 160, hopLength: 160, analysisSampleRate: 16000,
            window: VersionedIdentifier(name: "fixture-window", version: 1),
            preprocessing: [:],
            algorithmSettings: ["origin": .text("synthetic fixture; no algorithm execution")],
            partialWindowPolicy: .emitUnavailable)
        let identity = try profile.identity()
        func source(_ start: Int64, _ count: Int64) throws -> SourceInterval {
            try SourceInterval(
                epoch: epoch, startSample: start, sampleCount: count, sampleRate: 16000)
        }
        let key = try VisualizationSeriesKey(
            measurement: profile.measurement, profile: identity,
            source: VisualizationSource(source(3200, 0)))
        let state: VisualizationState
        switch scenario {
        case .valid, .longLabel: state = .running
        case .noData: state = .insufficientData
        case .gap: state = .interrupted(.droppedAudio)
        case .unsupported: state = .unsupportedMetric(.harmonicToNoiseRatio)
        case .failure:
            state = .failure(try VersionedIdentifier(name: "fixture-analysis-failure", version: 1))
        case .loading: state = .loading
        case .paused: state = .paused
        case .interrupted: state = .interrupted(.routeChange)
        }
        let hasValues = [.valid, .gap, .longLabel, .paused, .interrupted].contains(scenario)
        var rows: [VisualizationMeasurement] = []
        if hasValues {
            for index in 0..<3 {
                let missing = scenario == .gap && index == 2
                let timing = try AnalysisTiming(
                    source: source(3200 + Int64(index * 160), 160),
                    includedSampleCount: missing ? 0 : 160,
                    sourceStartSeconds: 1 + Double(index) * 0.01,
                    hostStartNanoseconds: 1_000_000_000 + UInt64(index * 10_000_000),
                    effectiveDelaySeconds: 0.02)
                let outcome: MeasurementOutcome =
                    missing
                    ? .unavailable(.missingAcquisition)
                    : .available(
                        try ScalarEstimate(value: 8.25 + Double(index) / 10, confidence: 0.8))
                rows.append(
                    VisualizationMeasurement(
                        try MeasurementResult(
                            measurement: profile.measurement, profile: identity, timing: timing,
                            outcome: outcome)))
            }
        }
        let boundaries =
            scenario == .gap
            ? [
                try SourceDiscontinuity(
                    previousEpoch: epoch, nextEpoch: epoch.successor(), reason: .droppedAudio,
                    missingSource: source(3520, 160))
            ] : []
        let title =
            scenario == .longLabel
            ? "CPPS — preferred sustained-phonation comparison with a deliberately long personal annotation that must wrap without hiding the value, source interval, units, profile identity, or inspection controls"
            : "\(VisualizationText.measurement(kind)) inspection"
        return Self(
            scenario: scenario, title: title,
            snapshot: try VisualizationMetricSnapshot(
                series: key, measurements: rows, boundaries: boundaries), state: state)
    }
}

/// Root ownership is local to this explicit preview surface. The data/store is
/// prepared once in init, not rebuilt in body or obtained from a microphone.
public struct VisualizationFixtureView: View {
    public let fixture: VisualizationPreviewFixture
    @State private var store: VisualizationMetricStore

    public init(fixture: VisualizationPreviewFixture) {
        self.fixture = fixture
        _store = State(
            initialValue: VisualizationMetricStore(snapshot: fixture.snapshot, state: fixture.state)
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Synthetic preview · no audio capture")
                .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .top])
            VisualizationMetricPanel(store: store, title: fixture.title)
        }
    }
}

#Preview("Valid") { VisualizationFixtureView(fixture: try! .make(.valid)) }
#Preview("No data") { VisualizationFixtureView(fixture: try! .make(.noData)) }
#Preview("Acquisition gap") { VisualizationFixtureView(fixture: try! .make(.gap)) }
#Preview("Unsupported") { VisualizationFixtureView(fixture: try! .make(.unsupported)) }
#Preview("Failure") { VisualizationFixtureView(fixture: try! .make(.failure)) }
#Preview("Long label") {
    VisualizationFixtureView(fixture: try! .make(.longLabel)).frame(width: 350)
}
#Preview("Loading") { VisualizationFixtureView(fixture: try! .make(.loading)) }
#Preview("Paused") { VisualizationFixtureView(fixture: try! .make(.paused)) }
#Preview("Interrupted") { VisualizationFixtureView(fixture: try! .make(.interrupted)) }
