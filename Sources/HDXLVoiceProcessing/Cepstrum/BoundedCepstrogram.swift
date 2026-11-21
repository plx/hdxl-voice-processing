import Foundation

/// An explicit owned row. Finite values are a prefix when arithmetic fails; a complete
/// zero-valued row is never substituted for an unavailable result.
public struct PowerCepstrumFrame: Sendable, Hashable, Codable {
    public let configuration: CepstrogramConfiguration
    public let profile: ProfileIdentity
    public let context: CepstralFrameContext
    public let values: [Double]
    public let unavailability: UnavailabilityReason?
    public var quefrencyStepSeconds: Double { configuration.frame.quefrencyStepSeconds }
    public var unit: MeasurementUnit { .inverseSecondsSquared }

    public init(
        configuration: CepstrogramConfiguration, context: CepstralFrameContext,
        values: [Double], unavailability: UnavailabilityReason?
    ) throws {
        try self.init(
            configuration: configuration, profile: configuration.identity(),
            context: context, values: values, unavailability: unavailability)
    }
    // Collectors in this file may reuse their prepared identity. Public
    // construction and decoding always recompute it from validated configuration.
    fileprivate init(
        configuration: CepstrogramConfiguration, profile: ProfileIdentity,
        context: CepstralFrameContext, values: [Double],
        unavailability: UnavailabilityReason?
    ) throws {
        guard context.origin.sampleRate == Double(configuration.conditioning.sourceSampleRate),
            context.suppliedAnalysisSampleCount <= configuration.frame.frameLength,
            values.count <= configuration.frame.binCount,
            values.allSatisfy({ $0.isFinite && $0 >= 0 }),
            unavailability == nil
                ? values.count == configuration.frame.binCount
                    && context.suppliedAnalysisSampleCount == configuration.frame.frameLength
                    && context.timing.includedSampleCount > 0
                : values.count < configuration.frame.binCount
        else { throw ContractError.invalidValue }
        self.configuration = configuration
        self.profile = profile
        self.context = context
        self.values = values.map { $0 == 0 ? 0 : $0 }
        self.unavailability = unavailability
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case configuration, profile, context, values, unavailability
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard c.contains(.unavailability) else { throw ContractError.invalidValue }
        try self.init(
            configuration: c.decode(CepstrogramConfiguration.self, forKey: .configuration),
            context: c.decode(CepstralFrameContext.self, forKey: .context),
            values: c.decode([Double].self, forKey: .values),
            unavailability: c.decodeIfPresent(UnavailabilityReason.self, forKey: .unavailability))
        guard try c.decode(ProfileIdentity.self, forKey: .profile) == profile else {
            throw ContractError.invalidFingerprint
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configuration, forKey: .configuration)
        try c.encode(profile, forKey: .profile)
        try c.encode(context, forKey: .context)
        try c.encode(values, forKey: .values)
        try c.encode(unavailability, forKey: .unavailability)
    }
}

/// Opt-in matrix retention. Capacity exhaustion throws before appending; it neither
/// drops old rows nor silently stops retaining. A new epoch/interval needs a new collector.
/// Row copies and serialization are outside the allocation-free processing contract.
public final class BoundedCepstrogram {
    public let configuration: CepstrogramConfiguration
    public let identity: ProfileIdentity
    public let maximumFrames: Int
    public let maximumScalarCount: Int
    public private(set) var frames: [PowerCepstrumFrame] = []
    public private(set) var scalarCount = 0
    public init(
        configuration: CepstrogramConfiguration, maximumFrames: Int, maximumScalarCount: Int
    ) throws {
        guard (1...30_000).contains(maximumFrames), (0...16_777_216).contains(maximumScalarCount)
        else {
            throw CepstrumError.capacityExceeded
        }
        self.configuration = configuration
        self.identity = try configuration.identity()
        self.maximumFrames = maximumFrames
        self.maximumScalarCount = maximumScalarCount
        frames.reserveCapacity(maximumFrames)
    }
    public func append(_ output: BorrowedPowerCepstrum<Double>) throws {
        guard output.configuration == configuration.frame, output.profile == identity else {
            throw ContractError.invalidFingerprint
        }
        let stage = output.stage(.powerCepstrum)
        guard frames.count < maximumFrames, stage.values.count <= maximumScalarCount - scalarCount
        else {
            throw CepstrumError.capacityExceeded
        }
        if let previous = frames.last {
            guard output.context.origin == previous.context.origin,
                previous.context.frameIndex < UInt64.max,
                output.context.frameIndex == previous.context.frameIndex + 1,
                output.context.centerSecondsFromOrigin > previous.context.centerSecondsFromOrigin
            else {
                throw CepstrumError.unexpectedInterval
            }
        }
        let row = try PowerCepstrumFrame(
            configuration: configuration, profile: identity, context: output.context,
            values: Array(stage.values), unavailability: stage.unavailability)
        frames.append(row)
        scalarCount += row.values.count
    }
}

/// Copies canonical #33 output one row at a time. Preparing once avoids hashing a configuration per row.
public struct PowerCepstrogramExporter: Sendable {
    public let configuration: CepstrogramConfiguration
    public let profile: ProfileIdentity
    public let quefrency: SpectralProductAxis
    public let unit: MeasurementUnit = .inverseSecondsSquared

    public init(configuration: CepstrogramConfiguration) throws {
        self.configuration = configuration
        profile = try configuration.identity()
        quefrency = try SpectralProductAxis(
            count: configuration.frame.binCount,
            step: configuration.frame.quefrencyStepSeconds, unit: .seconds)
    }

    public func owned(_ output: BorrowedPowerCepstrum<Double>) throws -> PowerCepstrumFrame {
        guard output.configuration == configuration.frame, output.profile == profile else {
            throw ContractError.invalidFingerprint
        }
        let stage = output.stage(.powerCepstrum)
        return try PowerCepstrumFrame(
            configuration: configuration, profile: profile, context: output.context,
            values: Array(stage.values), unavailability: stage.unavailability)
    }
}

/// Self-describing offline export of one canonical column and its quefrency grid.
public struct CepstrogramSlice: Sendable, Hashable, Encodable {
    public let frame: PowerCepstrumFrame
    public let quefrency: SpectralProductAxis
    public let powerUnit: MeasurementUnit
}

extension PowerCepstrogramExporter {
    public func slice(_ output: BorrowedPowerCepstrum<Double>) throws -> CepstrogramSlice {
        try CepstrogramSlice(frame: owned(output), quefrency: quefrency, powerUnit: unit)
    }
}
