import Foundation
import HDXLVoiceProcessing

public enum VisualizationComponentKind: String, Sendable, Hashable, CaseIterable {
    case metric, waveform, spectrum, cepstrum, segmentation, profile, diagnostics, custom
}

/// Data-driven extension point for host/component catalogs. Adding a supported
/// measurement or frame family does not require an audio engine or a core UI type.
/// A descriptor declares accepted inputs; it does not claim an algorithm is installed.
public struct VisualizationComponentDescriptor: Sendable, Hashable, Identifiable {
    public let id: VersionedIdentifier
    public let kind: VisualizationComponentKind
    public let title: String
    public let measurements: Set<MeasurementKind>
    public let frameDomains: Set<VisualizationFrameDomain>

    public init(
        id: VersionedIdentifier, kind: VisualizationComponentKind, title: String,
        measurements: Set<MeasurementKind> = [], frameDomains: Set<VisualizationFrameDomain> = []
    ) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            title.utf8.count <= 4096
        else { throw VisualizationError.invalidConfiguration }
        self.id = id
        self.kind = kind
        self.title = title
        self.measurements = measurements
        self.frameDomains = frameDomains
    }

    public static func standardInventory() throws -> [Self] {
        try [
            Self(
                id: VersionedIdentifier(name: "metric-inspection", version: 1), kind: .metric,
                title: "Metric inspection", measurements: Set(MeasurementKind.allCases)),
            Self(
                id: VersionedIdentifier(name: "waveform-frame", version: 1), kind: .waveform,
                title: "Waveform frames", frameDomains: [.waveform]),
            Self(
                id: VersionedIdentifier(name: "spectrum-frame", version: 1), kind: .spectrum,
                title: "Spectral frames", frameDomains: [.spectrum]),
            Self(
                id: VersionedIdentifier(name: "cepstrum-frame", version: 1), kind: .cepstrum,
                title: "Cepstral frames", frameDomains: [.cepstrum]),
            Self(
                id: VersionedIdentifier(name: "source-segmentation", version: 1),
                kind: .segmentation, title: "Source segmentation"),
            Self(
                id: VersionedIdentifier(name: "profile-inspection", version: 1), kind: .profile,
                title: "Profile inspection"),
            Self(
                id: VersionedIdentifier(name: "optional-diagnostics", version: 1),
                kind: .diagnostics, title: "Optional diagnostics", frameDomains: [.diagnostic]),
        ]
    }
}
