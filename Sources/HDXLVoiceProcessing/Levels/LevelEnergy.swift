import Foundation

public enum DigitalLevelStatus: String, Sendable, Hashable, Codable {
    case finite, zeroEnergy, unavailable
}

/// Digital level relative to unit peak PCM. Zero energy has a tagged logarithmic limit.
/// JSON contains neither an infinity nor a made-up finite silence floor.
public struct DigitalLevel: Sendable, Hashable, Codable {
    public let status: DigitalLevelStatus
    public let finiteDecibels: Double?
    public let unavailability: UnavailabilityReason?

    private init(status: DigitalLevelStatus, decibels: Double?, reason: UnavailabilityReason?) {
        self.status = status
        self.finiteDecibels = decibels
        self.unavailability = reason
    }
    public static func finite(_ decibels: Double) throws -> Self {
        guard decibels.isFinite else { throw ContractError.invalidValue }
        return Self(status: .finite, decibels: decibels == 0 ? 0 : decibels, reason: nil)
    }
    public static let zeroEnergy = Self(status: .zeroEnergy, decibels: nil, reason: nil)
    public static func unavailable(_ reason: UnavailabilityReason) -> Self {
        Self(status: .unavailable, decibels: nil, reason: reason)
    }
    /// Opt-in mathematical representation; do not serialize this property as a JSON number.
    public var mathematicalDecibels: Double? {
        switch status {
        case .finite: finiteDecibels
        case .zeroEnergy: -.infinity
        case .unavailable: nil
        }
    }
    /// The shared scalar contract permits finite estimates only. Silence remains explicit.
    public var scalarOutcome: MeasurementOutcome {
        switch status {
        case .finite: .available(try! ScalarEstimate(value: finiteDecibels!))
        case .zeroEnergy: .unavailable(.silence)
        case .unavailable: .unavailable(unavailability!)
        }
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case status, finiteDecibels, unavailability
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        switch try c.decode(DigitalLevelStatus.self, forKey: .status) {
        case .finite:
            guard Set(c.allKeys) == [.status, .finiteDecibels] else {
                throw ContractError.invalidValue
            }
            self = try .finite(c.decode(Double.self, forKey: .finiteDecibels))
        case .zeroEnergy:
            guard Set(c.allKeys) == [.status] else { throw ContractError.invalidValue }
            self = .zeroEnergy
        case .unavailable:
            guard Set(c.allKeys) == [.status, .unavailability] else {
                throw ContractError.invalidValue
            }
            self = .unavailable(try c.decode(UnavailabilityReason.self, forKey: .unavailability))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        switch status {
        case .finite: try c.encode(finiteDecibels!, forKey: .finiteDecibels)
        case .zeroEnergy: break
        case .unavailable: try c.encode(unavailability!, forKey: .unavailability)
        }
    }
}

/// Mean square = scale² × normalizedMeanSquare, in normalized squared PCM amplitude.
/// The representation stays meaningful when the product cannot be represented by Double.
public struct LevelEnergy: Sendable, Hashable, Codable {
    public let scale: Double
    public let normalizedMeanSquare: Double
    public var isZero: Bool { scale == 0 }

    public init(scale: Double, normalizedMeanSquare: Double) throws {
        guard scale.isFinite, scale >= 0, normalizedMeanSquare.isFinite,
            (0...1).contains(normalizedMeanSquare),
            (scale == 0) == (normalizedMeanSquare == 0)
        else { throw ContractError.invalidValue }
        self.scale = scale == 0 ? 0 : scale
        self.normalizedMeanSquare = normalizedMeanSquare == 0 ? 0 : normalizedMeanSquare
    }
    public static let zero = try! Self(scale: 0, normalizedMeanSquare: 0)

    public var meanSquare: MeasurementOutcome {
        finiteValue(scale * (scale * normalizedMeanSquare))
    }
    public var rms: MeasurementOutcome { finiteValue(scale * sqrt(normalizedMeanSquare)) }
    public var digitalLevel: DigitalLevel {
        isZero ? .zeroEnergy : try! .finite(20 * log10(scale) + 10 * log10(normalizedMeanSquare))
    }
    private func finiteValue(_ value: Double) -> MeasurementOutcome {
        guard value.isFinite, isZero || value > 0 else { return .unavailable(.unsupportedRange) }
        return .available(try! ScalarEstimate(value: value))
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case scale, normalizedMeanSquare }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            scale: c.decode(Double.self, forKey: .scale),
            normalizedMeanSquare: c.decode(Double.self, forKey: .normalizedMeanSquare))
    }
}

/// Direct scaled sum of squares. Small contributions may round away, but neither
/// squaring overflow nor squaring underflow can turn a nonzero window into silence.
struct LevelScaledSum {
    private var scale = 0.0
    private var sum = 0.0

    mutating func append(_ finiteSample: Double) {
        let magnitude = abs(finiteSample)
        if magnitude == 0 { return }
        if magnitude > scale {
            let ratio = scale / magnitude
            sum = 1 + sum * ratio * ratio
            scale = magnitude
        } else {
            let ratio = magnitude / scale
            sum += ratio * ratio
        }
    }
    func energy(sampleCount: Int) throws -> LevelEnergy {
        guard sampleCount > 0 else { throw ContractError.invalidConfiguration }
        return try LevelEnergy(
            scale: scale, normalizedMeanSquare: min(1, sum / Double(sampleCount)))
    }
}
