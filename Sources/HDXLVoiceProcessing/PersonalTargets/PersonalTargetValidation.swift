import Foundation

/// Provenance for actual reference and partition/boundary checks. Counts refer
/// to checked cases, not fitting examples. A ratio is observed error / declared
/// budget, so zero is an exact match and values above one do not pass.
public struct PersonalTargetMetricValidation: Sendable, Hashable, Encodable {
    public let metric: ScheduledMetric
    public let referenceIdentity: CalibrationDigest
    public let reportIdentity: CalibrationDigest
    public let referenceCases: Int
    public let chunkComparisons: Int
    public let boundaryCases: Int
    public let maximumReferenceErrorToBudget: Double
    public let maximumChunkErrorToBudget: Double
    public let maximumBoundaryErrorToBudget: Double

    public init(
        metric: ScheduledMetric, referenceIdentity: CalibrationDigest,
        reportIdentity: CalibrationDigest, referenceCases: Int, chunkComparisons: Int,
        boundaryCases: Int, maximumReferenceErrorToBudget: Double,
        maximumChunkErrorToBudget: Double, maximumBoundaryErrorToBudget: Double
    ) throws {
        guard [.cpps, .fundamentalFrequency, .levelDBFS].contains(metric),
            [referenceCases, chunkComparisons, boundaryCases].allSatisfy({
                (1...10_000_000).contains($0)
            }),
            [
                maximumReferenceErrorToBudget, maximumChunkErrorToBudget,
                maximumBoundaryErrorToBudget,
            ].allSatisfy({
                $0.isFinite && (0...1).contains($0)
            })
        else { throw PersonalTargetError.invalidValidationEvidence }
        self.metric = metric
        self.referenceIdentity = referenceIdentity
        self.reportIdentity = reportIdentity
        self.referenceCases = referenceCases
        self.chunkComparisons = chunkComparisons
        self.boundaryCases = boundaryCases
        self.maximumReferenceErrorToBudget =
            maximumReferenceErrorToBudget == 0 ? 0 : maximumReferenceErrorToBudget
        self.maximumChunkErrorToBudget =
            maximumChunkErrorToBudget == 0 ? 0 : maximumChunkErrorToBudget
        self.maximumBoundaryErrorToBudget =
            maximumBoundaryErrorToBudget == 0 ? 0 : maximumBoundaryErrorToBudget
    }
}

/// The host retains and verifies the referenced artifacts. This value enforces
/// complete, passing evidence for the exact executable profile and implementation;
/// it cannot prove an arbitrary caller's claims or authenticate imported numbers.
public struct PersonalTargetValidationEvidence: Sendable, Hashable, Encodable {
    public let schemaVersion: Int
    public let profile: ProfileIdentity
    public let analysisImplementation: VersionedIdentifier
    public let sourceIdentity: CalibrationDigest
    public let components: [PersonalTargetMetricValidation]

    public init(
        profile: AnalysisScheduleProfile,
        analysisImplementation: VersionedIdentifier = CalibrationAnalysisKey.currentImplementation,
        sourceIdentity: CalibrationDigest, components: [PersonalTargetMetricValidation]
    ) throws {
        guard profile.cpps != nil, profile.pitch != nil, profile.levels != nil,
            analysisImplementation == CalibrationAnalysisKey.currentImplementation,
            components.count == 3,
            Set(components.map(\.metric)) == Set([.cpps, .fundamentalFrequency, .levelDBFS])
        else { throw PersonalTargetError.invalidValidationEvidence }
        schemaVersion = 1
        self.profile = try profile.identity()
        self.analysisImplementation = analysisImplementation
        self.sourceIdentity = sourceIdentity
        self.components = components.sorted { $0.metric.rawValue < $1.metric.rawValue }
    }

    public func identity() throws -> CalibrationDigest { try calibrationDigest(self) }
}
