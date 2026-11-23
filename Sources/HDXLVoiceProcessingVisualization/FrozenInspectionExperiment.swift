import Foundation
import HDXLVoiceProcessing

/// Samples are a single, independently analyzed mono interval. The selection's
/// absolute start, sample rate and source epoch survive every rerun.
public struct FrozenInspectionInput: Sendable {
    public let samples: [Double]
    public let source: SourceInterval
    public let context: InspectionContext
    public let limits: VisualizationLimits

    public init(
        samples: [Double], source: SourceInterval, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws {
        guard samples.count <= limits.maximumFrameScalars else {
            throw VisualizationError.capacityExceeded
        }
        guard Int64(exactly: samples.count) == source.sampleCount, samples.allSatisfy(\.isFinite)
        else {
            throw VisualizationError.invalidConfiguration
        }
        self.samples = samples
        self.source = source
        self.context = context
        self.limits = limits
    }
}

public enum FrozenInspectionRecipe: Sendable, Hashable {
    case pitch(YINConfiguration)
    case cpp(cepstrogram: CepstrogramConfiguration, prominence: CPPConfiguration, frame: UInt64)
    case cpps(CPPSProfile, frame: UInt64)

    fileprivate func runsSameStage(as other: Self) -> Bool {
        switch (self, other) {
        case (.pitch, .pitch): true
        case (.cpp(_, _, let a), .cpp(_, _, let b)), (.cpps(_, let a), .cpps(_, let b)): a == b
        default: false
        }
    }

    fileprivate func evaluate(_ input: FrozenInspectionInput) throws -> AlgorithmInspection {
        let source = input.source
        var captured: Result<AlgorithmInspection, any Error>?
        switch self {
        case .pitch(let recipe):
            let analyzer = try PreparedYIN<Double>(recipe)
            try input.samples.withUnsafeBufferPointer {
                try analyzer.analyze(
                    $0, timing: .init(source: source, includedSampleCount: source.sampleCount)
                ) { out in
                    captured = Result {
                        try .pitch(
                            out, recipe: recipe, context: input.context, limits: input.limits)
                    }
                }
            }
        case .cpp(let upstream, let settings, let index):
            let recipe = CPPProfile(cepstrogram: upstream, settings: settings)
            let transform = try PreparedIntervalCepstrogram<Double>(
                configuration: upstream, source: source)
            let analyzer = try PreparedCPP(recipe)
            try input.samples.withUnsafeBufferPointer { try transform.append($0, interval: source) }
            _ = try transform.finish { column in
                guard column.context.frameIndex == index else { return }
                do {
                    try analyzer.analyze(column) { fit in
                        captured = Result {
                            try .cpp(
                                fit, recipe: recipe, upstream: column,
                                context: input.context, limits: input.limits)
                        }
                    }
                } catch { captured = .failure(error) }
            }
        case .cpps(let recipe, let index):
            let analyzer = try PreparedIntervalCPPS<Double>(profile: recipe, source: source)
            try input.samples.withUnsafeBufferPointer { try analyzer.append($0, interval: source) }
            _ = try analyzer.finish { out in
                guard out.result.context.frameIndex == index else { return }
                captured = Result {
                    try .cpps(out, recipe: recipe, context: input.context, limits: input.limits)
                }
            }
        }
        guard let captured else { throw VisualizationError.invalidSelection }
        return try captured.get()
    }
}

public struct InspectionSettingChange: Sendable, Hashable {
    public let path: String
    public let original: String?
    public let changed: String?
}

public struct FrozenInspectionComparison: Sendable {
    public let original: AlgorithmInspection
    public let changed: AlgorithmInspection
    public let settings: [InspectionSettingChange]
}

/// The immutable original and each alternative are evaluated by the production
/// processor on the same frozen input. Repeated experiments always compare to the original.
public struct FrozenInspectionExperiment: Sendable {
    public let input: FrozenInspectionInput
    public let recipe: FrozenInspectionRecipe
    public let original: AlgorithmInspection

    public init(input: FrozenInspectionInput, recipe: FrozenInspectionRecipe) throws {
        self.input = input
        self.recipe = recipe
        original = try recipe.evaluate(input)
    }

    public func compare(_ alternative: FrozenInspectionRecipe) throws -> FrozenInspectionComparison
    {
        guard recipe.runsSameStage(as: alternative) else {
            throw VisualizationError.incompatibleSeries
        }
        let changed = try alternative.evaluate(input)
        guard original.window == changed.window, original.dependency == changed.dependency else {
            throw VisualizationError.incompatibleSource
        }
        let before = try Self.leaves(original.parameters)
        let after = try Self.leaves(changed.parameters)
        let settings = Set(before.keys).union(after.keys).sorted().compactMap {
            path -> InspectionSettingChange? in
            guard before[path] != after[path] else { return nil }
            return .init(path: path, original: before[path], changed: after[path])
        }
        return .init(original: original, changed: changed, settings: settings)
    }

    /// JSON Pointer paths preserve nested settings, escaped keys, and array indices.
    private static func leaves(_ parameters: String) throws -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ value: Any, path: String) throws {
            if let object = value as? [String: Any], !object.isEmpty {
                for (key, child) in object {
                    let escaped = key.replacingOccurrences(of: "~", with: "~0")
                        .replacingOccurrences(of: "/", with: "~1")
                    try visit(child, path: path + "/" + escaped)
                }
            } else if let array = value as? [Any], !array.isEmpty {
                for (i, child) in array.enumerated() { try visit(child, path: path + "/\(i)") }
            } else if let number = value as? NSNumber,
                ["d", "f"].contains(String(cString: number.objCType))
            {
                // Use the same binary64 shortest round-trip spelling as the typed recipe encoder.
                result[path] = String(
                    decoding: try JSONEncoder().encode(number.doubleValue), as: UTF8.self)
            } else {
                let data = try JSONSerialization.data(
                    withJSONObject: value,
                    options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
                result[path] = String(decoding: data, as: UTF8.self)
            }
        }
        try visit(JSONSerialization.jsonObject(with: Data(parameters.utf8)), path: "")
        return result
    }
}
