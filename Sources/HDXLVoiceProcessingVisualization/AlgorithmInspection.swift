import Foundation
import HDXLVoiceProcessing

public enum InspectionOrigin: String, Sendable, Hashable {
    case recording, synthesizedDemonstration
}

/// The source clock identifies acquired samples. The configuration epoch identifies
/// the host's committed analysis configuration at a window boundary.
public struct InspectionContext: Sendable, Hashable {
    public let origin: InspectionOrigin
    public let configurationEpoch: UInt64

    public init(origin: InspectionOrigin, configurationEpoch: UInt64) {
        self.origin = origin
        self.configurationEpoch = configurationEpoch
    }
}

public struct InspectionField: Sendable, Hashable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct InspectionCurve: Sendable, Hashable {
    public let explanation: String
    public let samples: IntermediateSnapshot

    public init(_ samples: IntermediateSnapshot, explanation: String) {
        self.samples = samples
        self.explanation = explanation
    }
}

/// An immutable worker-side projection of one calculation. A new algorithm can
/// supply its own rows and uniformly spaced curves without extending an enum.
public struct AlgorithmInspection: Sendable {
    public let title: String
    public let explanation: String
    public let reference: URL
    public let context: InspectionContext
    public let window: SourceInterval
    public let dependency: SourceInterval
    public let profile: ProfileIdentity
    public let parameters: String
    public let status: String
    public let measurements: [MeasurementResult]
    public let fields: [InspectionField]
    public let curves: [InspectionCurve]
    public let scalarCount: Int
    public let metadataBytes: Int
    public var recordCount: Int { 1 + measurements.count + fields.count + curves.count }

    public init(
        title: String, explanation: String, reference: URL, context: InspectionContext,
        window: SourceInterval, dependency: SourceInterval, profile: ProfileIdentity,
        parameters: String, status: String, measurements: [MeasurementResult] = [],
        fields: [InspectionField] = [], curves: [InspectionCurve] = [],
        limits: VisualizationLimits = .standard
    ) throws {
        func contains(_ child: SourceInterval) -> Bool {
            VisualizationSource(dependency).contains(child)
                && dependency.startSample <= child.startSample
                && child.endSample <= dependency.endSample
        }
        guard contains(window) else { throw VisualizationError.incompatibleSource }
        guard reference.scheme == "https", reference.host != nil,
            !title.isEmpty, !explanation.isEmpty, !parameters.isEmpty, !status.isEmpty
        else { throw VisualizationError.invalidConfiguration }
        var records = limits.maximumSegments - 1
        for count in [measurements.count, fields.count, curves.count] {
            guard count <= records else { throw VisualizationError.capacityExceeded }
            records -= count
        }
        var budget = VisualizationMetadataBudget(limits)
        for text in [title, explanation, reference.absoluteString, parameters, status] {
            try budget.charge(text)
        }
        try budget.charge(profile)
        for field in fields {
            try budget.charge(field.name)
            try budget.charge(field.value)
        }
        for measurement in measurements {
            guard measurement.intermediates.isEmpty else {
                throw VisualizationError.invalidConfiguration
            }
            guard contains(measurement.timing.source) else {
                throw VisualizationError.incompatibleSource
            }
            try budget.charge(measurement)
        }
        var scalars = 0
        for curve in curves {
            guard contains(curve.samples.source) else {
                throw VisualizationError.incompatibleSource
            }
            guard curve.samples.values.count <= limits.maximumFrameScalars - scalars else {
                throw VisualizationError.capacityExceeded
            }
            scalars += curve.samples.values.count
            try budget.charge(curve.samples.stage)
            try budget.charge(curve.explanation)
        }
        self.title = title
        self.explanation = explanation
        self.reference = reference
        self.context = context
        self.window = window
        self.dependency = dependency
        self.profile = profile
        self.parameters = parameters
        self.status = status
        self.measurements = measurements
        self.fields = fields
        self.curves = curves
        scalarCount = scalars
        metadataBytes = limits.maximumMetadataBytes - budget.remaining
    }

    static func parameters(_ recipe: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(recipe), as: UTF8.self)
    }

    static func requireProfile(_ supplied: ProfileIdentity, _ actual: ProfileIdentity) throws {
        guard supplied == actual else { throw VisualizationError.incompatibleSeries }
    }

    static func availability(_ outcome: MeasurementOutcome) -> String {
        if case .unavailable(let reason) = outcome { return status(reason) }
        return "Available"
    }

    static func status(_ reason: UnavailabilityReason?) -> String {
        reason.map(VisualizationText.unavailability) ?? "Available"
    }
}

public enum InspectionSampling: Sendable, Hashable {
    case disabled
    case selected(frame: UInt64)
    case sampled(every: UInt64, maximumFrames: Int)
}

/// One worker and one immutable profile per epoch. A host creates a new history
/// after finishing or discarding a partial window when it reconfigures live DSP.
/// Limits apply to the entire retained history as well as each captured frame.
public struct InspectionHistory: Sendable {
    public let sampling: InspectionSampling
    public let context: InspectionContext
    public let source: VisualizationSource
    public let profile: ProfileIdentity
    public let limits: VisualizationLimits
    public private(set) var snapshots: [AlgorithmInspection] = []
    public private(set) var scalarCount = 0
    public private(set) var metadataBytes = 0
    private var records = 0
    private var lastFrame: UInt64?

    public init(
        sampling: InspectionSampling = .disabled, context: InspectionContext,
        source: VisualizationSource, profile: ProfileIdentity,
        limits: VisualizationLimits = .standard
    ) throws {
        if case .sampled(let stride, let count) = sampling {
            guard stride > 0, (1...limits.maximumMeasurements).contains(count) else {
                throw VisualizationError.invalidConfiguration
            }
        }
        self.sampling = sampling
        self.context = context
        self.source = source
        self.profile = profile
        self.limits = limits
    }

    /// Call on the analysis worker inside the synchronous production callback.
    /// Disabled and unsampled frames never invoke the allocating projection.
    @discardableResult public mutating func capture(
        frame: UInt64, make: (VisualizationLimits) throws -> AlgorithmInspection
    ) throws -> Bool {
        let capacity: Int
        switch sampling {
        case .disabled: return false
        case .selected(let index):
            guard frame == index else { return false }
            capacity = 1
        case .sampled(let stride, let count):
            guard frame.isMultiple(of: stride) else { return false }
            capacity = count
        }
        guard lastFrame.map({ frame > $0 }) ?? true else {
            throw VisualizationError.unorderedMeasurements
        }
        let next = try make(limits)
        guard next.context == context, source.contains(next.window) else {
            throw VisualizationError.incompatibleSource
        }
        try AlgorithmInspection.requireProfile(profile, next.profile)
        guard next.scalarCount <= limits.maximumFrameScalars,
            next.metadataBytes <= limits.maximumMetadataBytes,
            next.recordCount <= limits.maximumSegments
        else { throw VisualizationError.capacityExceeded }
        var dropped = 0
        while snapshots.count - dropped >= capacity
            || scalarCount > limits.maximumFrameScalars - next.scalarCount
            || metadataBytes > limits.maximumMetadataBytes - next.metadataBytes
            || records > limits.maximumSegments - next.recordCount
        {
            let oldest = snapshots[dropped]
            scalarCount -= oldest.scalarCount
            metadataBytes -= oldest.metadataBytes
            records -= oldest.recordCount
            dropped += 1
        }
        snapshots.removeFirst(dropped)
        snapshots.append(next)
        scalarCount += next.scalarCount
        metadataBytes += next.metadataBytes
        records += next.recordCount
        lastFrame = frame
        return true
    }
}
