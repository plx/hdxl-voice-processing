import Foundation
import HDXLVoiceProcessing

extension AlgorithmInspection {
    public static func jitter(
        _ r: JitterAnalysisResult, recipe: JitterConfiguration, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        try requireProfile(recipe.identity(), r.profile)
        let variants = JitterVariant.allCases.filter { r.estimate($0).status != .notRequested }
        let results = try variants.map { try r.measurementResult($0) }
        let coverage = r.coverage
        var fields = [
            InspectionField(
                "Query from dependency start", "\(r.query.startSeconds)…\(r.query.endSeconds) s"),
            .init(
                "Eligible periods",
                "\(coverage.acceptedPeriodCount) of \(coverage.selectedPeriodCount) selected"),
            .init("Normalization period count", String(coverage.meanPeriodCount)),
            .init(
                "Mean normalization period",
                coverage.meanPeriodSeconds.map { "\($0) s" } ?? "Unavailable"),
            .init(
                "Adjacent period pairs",
                "\(coverage.acceptedPairCount) of \(coverage.candidatePairCount)"),
            .init(
                "RAP neighborhoods",
                "\(coverage.acceptedRAPNeighborhoodCount) of \(coverage.candidateRAPNeighborhoodCount)"
            ),
            .init(
                "PPQ5 neighborhoods",
                "\(coverage.acceptedPPQ5NeighborhoodCount) of \(coverage.candidatePPQ5NeighborhoodCount)"
            ),
        ]
        fields += try rejectionFields(coverage.rejections)
        fields += AcousticPerturbationContext.jitter(
            r.query, coverage, r.applicability, r.inputProvenance
        ).provenanceText.map { .init("Input provenance", $0) }
        return try Self(
            title: "Period perturbation",
            explanation:
                "Jitter compares period lengths within eligible neighboring cycles. Each variant has its own required neighborhood and denominator.",
            reference: URL(string: "https://praat.org/manual/Voice_2__Jitter.html")!,
            context: context,
            window: r.sampleAlignedQuery ?? r.dependencyTiming.source,
            dependency: r.dependencyTiming.source,
            profile: r.profile, parameters: parameters(recipe),
            status: r.applicability == .sustainedPhonation
                ? "Sustained phonation" : "Exploratory rolling estimate",
            measurements: results, fields: fields,
            querySeconds: r.sampleAlignedQuery == nil
                ? r.query.startSeconds...r.query.endSeconds : nil, limits: limits)
    }

    public static func shimmer(
        _ r: ShimmerAnalysisResult, recipe: ShimmerConfiguration, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        try requireProfile(recipe.identity(), r.profile)
        let variants = ShimmerVariant.allCases.filter { r.estimate($0).status != .notRequested }
        let results = try variants.map { try r.measurementResult($0) }
        let coverage = r.coverage
        var fields = [
            InspectionField(
                "Query from dependency start", "\(r.query.startSeconds)…\(r.query.endSeconds) s"),
            .init(
                "Eligible cycle amplitudes",
                "\(coverage.acceptedAmplitudeCount) of \(coverage.selectedAmplitudeCount) selected"),
            .init("Normalization amplitude count", String(coverage.normalizationAmplitudeCount)),
            .init(
                "Mean normalization amplitude",
                coverage.meanAmplitude.map { "\($0) FS" } ?? "Unavailable"),
            .init(
                "Neighboring amplitude pairs",
                "\(coverage.acceptedPairCount) of \(coverage.candidatePairCount)"),
            .init(
                "APQ3 neighborhoods",
                "\(coverage.acceptedAPQ3NeighborhoodCount) of \(coverage.candidateAPQ3NeighborhoodCount)"
            ),
            .init(
                "APQ5 neighborhoods",
                "\(coverage.acceptedAPQ5NeighborhoodCount) of \(coverage.candidateAPQ5NeighborhoodCount)"
            ),
            .init(
                "APQ11 neighborhoods",
                "\(coverage.acceptedAPQ11NeighborhoodCount) of \(coverage.candidateAPQ11NeighborhoodCount)"
            ),
        ]
        fields += try rejectionFields(coverage.rejections)
        fields += AcousticPerturbationContext.shimmer(
            r.query, coverage, r.applicability, r.inputProvenance
        ).provenanceText.map { .init("Input provenance", $0) }
        return try Self(
            title: "Amplitude perturbation",
            explanation:
                "Shimmer compares cycle amplitudes. The available pairs and longer neighborhoods determine which amplitude differences contribute.",
            reference: URL(string: "https://praat.org/manual/Voice_3__Shimmer.html")!,
            context: context,
            window: r.sampleAlignedQuery ?? r.dependencyTiming.source,
            dependency: r.dependencyTiming.source,
            profile: r.profile, parameters: parameters(recipe),
            status: r.applicability == .sustainedPhonation
                ? "Sustained phonation" : "Exploratory rolling estimate",
            measurements: results, fields: fields,
            querySeconds: r.sampleAlignedQuery == nil
                ? r.query.startSeconds...r.query.endSeconds : nil, limits: limits)
    }

    private static func rejectionFields(_ record: some Encodable) throws -> [InspectionField] {
        let counts = try JSONDecoder().decode(
            [String: Int].self, from: JSONEncoder().encode(record))
        return counts.keys.sorted().compactMap { key in
            guard let count = counts[key], count > 0 else { return nil }
            let words = key.replacingOccurrences(
                of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression
            ).lowercased()
            return InspectionField("Rejection · " + words, String(count))
        }
    }
}
