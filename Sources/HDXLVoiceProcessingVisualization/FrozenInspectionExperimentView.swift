import Foundation
import SwiftUI

/// A host can propose complete typed settings from its own editor or a list of presets.
public struct InspectionAlternative: Sendable, Hashable {
    public let title: String
    public let recipe: FrozenInspectionRecipe
    public init(_ title: String, recipe: FrozenInspectionRecipe) {
        self.title = title
        self.recipe = recipe
    }
}

/// Replays a selected alternative on a background executor only after the user
/// requests it. Both outputs stay available while exploring the frozen interval.
public struct FrozenInspectionExperimentView: View {
    public let experiment: FrozenInspectionExperiment
    public let alternatives: [InspectionAlternative]

    public init(
        _ experiment: FrozenInspectionExperiment, alternatives: [InspectionAlternative],
        limits: VisualizationLimits = .standard
    ) throws {
        guard !alternatives.isEmpty, alternatives.count <= limits.maximumMeasurements else {
            throw VisualizationError.invalidConfiguration
        }
        var budget = VisualizationMetadataBudget(limits)
        for alternative in alternatives {
            guard !alternative.title.isEmpty,
                experiment.recipe.runsSameStage(as: alternative.recipe)
            else {
                throw VisualizationError.incompatibleSeries
            }
            try budget.charge(alternative.title)
        }
        self.experiment = experiment
        self.alternatives = alternatives
    }

    public var body: some View {
        FrozenControls(experiment: experiment, alternatives: alternatives)
            .id(ExperimentControlsIdentity(experiment: experiment.id, alternatives: alternatives))
    }
}

private struct ExperimentControlsIdentity: Hashable {
    let experiment: UUID
    let alternatives: [InspectionAlternative]
}

private struct FrozenControls: View {
    let experiment: FrozenInspectionExperiment
    let alternatives: [InspectionAlternative]
    @State private var candidate = 0
    @State private var request: Int?
    @State private var completed: Int?
    @State private var comparison: FrozenInspectionComparison?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AlgorithmInspectorView(experiment.original)
            Text("Experiment on this frozen window").font(.headline)
            Picker("Alternative settings", selection: $candidate) {
                ForEach(alternatives.indices, id: \.self) { index in
                    Text(alternatives[index].title).tag(index)
                }
            }
            Button("Compare with baseline") { request = candidate }
                .disabled(request != nil || completed == candidate)
            if request != nil { ProgressView("Calculating alternative") }
            if let failure { Text(failure) }
            if let comparison, let completed {
                Text(alternatives[completed].title).font(.subheadline.weight(.semibold))
                FrozenInspectionComparisonView(comparison)
            }
        }.task(id: request) {
            guard let request else { return }
            do {
                let outcome = try await rerun(experiment, alternative: alternatives[request].recipe)
                try Task.checkCancellation()
                comparison = outcome
                completed = request
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                failure = "Unable to compare this alternative on the selected window (\(error))."
            }
            self.request = nil
        }
    }

    @concurrent private func rerun(
        _ original: FrozenInspectionExperiment, alternative: FrozenInspectionRecipe
    )
        async throws -> FrozenInspectionComparison
    {
        try Task.checkCancellation()
        return try original.compare(alternative)
    }
}
