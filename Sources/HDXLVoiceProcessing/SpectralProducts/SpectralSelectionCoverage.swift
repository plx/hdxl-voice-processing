import CryptoKit
import Foundation

/// Sample counts on the observed source grid. Missing, excluded, and selected partition known
/// mask support. Samples outside a supplied plan are reported separately.
public struct SpectralSelectionCoverage: Sendable, Hashable, Encodable {
    public let selectedSamples: Int64
    public let measuredSelectedSamples: Int64
    public let excludedSamples: Int64
    public let missingSamples: Int64
    public let outsidePlanSamples: Int64
    public let selectedCoverage: Double

    init(observed: SourceInterval, measured: Int64, selection: MaskTimeline?) throws {
        var selected = observed.sampleCount
        var excluded: Int64 = 0
        var missing: Int64 = 0
        if let selection {
            guard selection.plan.source.epoch == observed.epoch,
                selection.plan.source.sampleRate == observed.sampleRate
            else {
                throw MaskError.unexpectedInterval
            }
            selected = 0
            for segment in selection.segments {
                let overlap = max(
                    0,
                    min(segment.source.endSample, observed.endSample)
                        - max(segment.source.startSample, observed.startSample))
                if segment.isSelected {
                    selected += overlap
                } else if segment.isEligible {
                    excluded += overlap
                } else {
                    missing += overlap
                }
            }
        }
        guard measured <= selected else { throw ContractError.invalidCoverage }
        selectedSamples = selected
        measuredSelectedSamples = measured
        excludedSamples = excluded
        missingSamples = missing
        outsidePlanSamples = observed.sampleCount - selected - excluded - missing
        selectedCoverage = selected == 0 ? 0 : Double(measured) / Double(selected)
    }
}

extension MaskPlan {
    func spectralSelectionIdentity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: "resolved-spectral-selection", version: 1),
            sha256: SHA256.hash(data: canonicalJSON()).map { String(format: "%02x", $0) }.joined())
    }
}

extension MaskTimeline {
    func spectralExclusion(for source: SourceInterval) throws -> UnavailabilityReason? {
        guard source.epoch == plan.source.epoch, source.sampleRate == plan.source.sampleRate else {
            throw MaskError.unexpectedInterval
        }
        guard source.startSample >= plan.source.startSample,
            source.endSample <= plan.source.endSample
        else { return .excluded }
        guard try eligibleRegion(containing: source) != nil else { return .missingAcquisition }
        return try selectedRegion(containing: source) == nil ? .excluded : nil
    }
}
