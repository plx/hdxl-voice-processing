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

    func runsSameStage(as other: Self) -> Bool {
        switch (self, other) {
        case (.pitch, .pitch): true
        case (.cpp(_, _, let a), .cpp(_, _, let b)), (.cpps(_, let a), .cpps(_, let b)): a == b
        default: false
        }
    }

    fileprivate func evaluate(_ input: FrozenInspectionInput) throws -> AlgorithmInspection {
        let precision: AnalysisPrecision
        switch self {
        case .pitch(let recipe): precision = recipe.inputPrecision
        case .cpp(let cepstrogram, _, _): precision = cepstrogram.inputPrecision
        case .cpps(let recipe, _): precision = recipe.cepstrogram.inputPrecision
        }
        try Task.checkCancellation()
        switch precision {
        case .float64:
            return try input.samples.withUnsafeBufferPointer { try evaluate(input, samples: $0) }
        case .float32:
            let converted = input.samples.map(Float.init)
            guard converted.allSatisfy(\.isFinite) else {
                throw VisualizationError.nonfiniteDisplayValue
            }
            return try converted.withUnsafeBufferPointer { try evaluate(input, samples: $0) }
        }
    }

    private func evaluate<Sample: BinaryFloatingPoint & Sendable>(
        _ input: FrozenInspectionInput,
        samples: UnsafeBufferPointer<Sample>
    ) throws -> AlgorithmInspection {
        let source = input.source
        var captured: Result<AlgorithmInspection, any Error>?
        switch self {
        case .pitch(let recipe):
            let analyzer = try PreparedYIN<Sample>(recipe)
            try analyzer.analyze(
                samples, timing: .init(source: source, includedSampleCount: source.sampleCount)
            ) { out in
                captured = Result {
                    try .pitch(out, recipe: recipe, context: input.context, limits: input.limits)
                }
            }
        case .cpp(let upstream, let settings, let index):
            let recipe = CPPProfile(cepstrogram: upstream, settings: settings)
            let analyzer = try PreparedCPP(recipe)
            _ = try replayCepstrogram(upstream, samples: samples, source: source) { column in
                guard column.context.frameIndex == index else { return false }
                try analyzer.analyze(column) { fit in
                    captured = Result {
                        try .cpp(
                            fit, recipe: recipe, upstream: column, context: input.context,
                            limits: input.limits)
                    }
                }
                return true
            }
        case .cpps(let recipe, let index):
            let origin = try SourceInterval(
                epoch: source.epoch, startSample: source.startSample,
                sampleCount: 0, sampleRate: source.sampleRate)
            let smoother = try PreparedCPPS(profile: recipe, origin: origin)
            func receive(_ out: BorrowedCPPSOutput) {
                if out.result.context.frameIndex == index {
                    captured = Result {
                        try .cpps(out, recipe: recipe, context: input.context, limits: input.limits)
                    }
                }
            }
            let completion = try replayCepstrogram(
                recipe.cepstrogram, samples: samples, source: source
            ) { column in
                try smoother.append(column, emit: receive)
                return captured != nil
            }
            if captured == nil, let completion {
                _ = try smoother.finish(
                    source: completion.source,
                    expectedFrameCount: Int(completion.emittedFrameCount),
                    whileEmitting: { captured == nil && !Task.isCancelled }, emit: receive)
            }
        }
        try Task.checkCancellation()
        guard let captured else { throw VisualizationError.invalidSelection }
        return try captured.get()
    }

    private func replayCepstrogram<Sample: BinaryFloatingPoint & Sendable>(
        _ recipe: CepstrogramConfiguration, samples: UnsafeBufferPointer<Sample>,
        source: SourceInterval,
        receive: (BorrowedPowerCepstrum<Double>) throws -> Bool
    ) throws -> CepstrogramCompletion? {
        var failure: (any Error)?
        func deliver(_ column: BorrowedPowerCepstrum<Double>, cancel: () -> Void) {
            do {
                try Task.checkCancellation()
                if try receive(column) { cancel() }
            } catch {
                failure = error
                cancel()
            }
        }
        let completion: CepstrogramCompletion?
        if recipe.previewHopLength != nil {
            let transform = try PreparedPreviewCepstrogram<Sample>(
                configuration: recipe, epoch: source.epoch, startSample: source.startSample)
            _ = try transform.process(samples, interval: source) {
                deliver($0, cancel: transform.cancel)
            }
            completion =
                transform.isCancelled
                ? nil : try transform.finish { deliver($0, cancel: transform.cancel) }
        } else {
            let transform = try PreparedIntervalCepstrogram<Sample>(
                configuration: recipe, source: source)
            try transform.append(samples, interval: source)
            completion = try transform.finish { deliver($0, cancel: transform.cancel) }
        }
        if let failure { throw failure }
        return completion
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
/// processor on the same frozen input. Preview delivery timing reflects this replay’s input chunks.
/// Repeated experiments always compare to the original. Each result retains its own dependency.
public struct FrozenInspectionExperiment: Sendable {
    public let id = UUID()
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
        guard original.window == changed.window else {
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
        try JSONDecoder().decode(RecipeNode.self, from: Data(parameters.utf8)).leaves
    }
}

/// Recipe values come from typed production encoders. Decode their numbers
/// directly with Foundation's Swift JSON decoder to preserve binary64 precision.
private struct RecipeNode: Decodable {
    let leaves: [String: String]

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let object = try? c.decode([String: RecipeNode].self) {
            var fields: [String: String] = [:]
            for (key, value) in object {
                let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(
                    of: "/", with: "~1")
                for (path, leaf) in value.leaves { fields["/" + escaped + path] = leaf }
            }
            leaves = fields.isEmpty ? ["": "{}"] : fields
        } else if let array = try? c.decode([RecipeNode].self) {
            var fields: [String: String] = [:]
            for (i, value) in array.enumerated() {
                for (path, leaf) in value.leaves { fields["/\(i)" + path] = leaf }
            }
            leaves = fields.isEmpty ? ["": "[]"] : fields
        } else {
            let data: Data
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            if c.decodeNil() {
                data = Data("null".utf8)
            } else if let value = try? c.decode(Bool.self) {
                data = try encoder.encode(value)
            } else if let value = try? c.decode(String.self) {
                data = try encoder.encode(value)
            } else if let value = try? c.decode(Int64.self) {
                data = try encoder.encode(value)
            } else {
                data = try encoder.encode(c.decode(Double.self))
            }
            leaves = ["": String(decoding: data, as: UTF8.self)]
        }
    }
}
