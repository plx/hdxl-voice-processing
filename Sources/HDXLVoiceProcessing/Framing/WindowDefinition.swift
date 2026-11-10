import CryptoKit
import Foundation

/// Numerical definitions are versioned independently of package releases.
/// All singleton windows are defined as [1]. No gain normalization is applied.
public enum WindowDefinition: String, Sendable, Hashable, Codable, CaseIterable {
    case rectangular
    case hannPeriodic = "hann-periodic"
    case hannSymmetric = "hann-symmetric"
    case hammingPeriodic = "hamming-periodic"
    case hammingSymmetric = "hamming-symmetric"
    case praatGaussian2 = "praat-gaussian-2-physical"

    public var effectiveDurationFraction: Double { self == .praatGaussian2 ? 0.5 : 1 }

    /// Original implementation of the declared mathematical definitions, not reference code.
    fileprivate func coefficient(at index: Int, count: Int) -> Double {
        if count == 1 || self == .rectangular { return 1 }
        switch self {
        case .rectangular: return 1
        case .hannPeriodic, .hannSymmetric, .hammingPeriodic, .hammingSymmetric:
            let symmetric = self == .hannSymmetric || self == .hammingSymmetric
            let phase = Double(index) / Double(symmetric ? count - 1 : count)
            let isHann = self == .hannPeriodic || self == .hannSymmetric
            return (isHann ? 0.5 : 0.54) - (isHann ? 0.5 : 0.46) * cos(2 * .pi * phase)
        case .praatGaussian2:
            let distance = Double(2 * index + 1 - count) / Double(count)
            let edge = exp(-12.0)
            return (exp(-12 * distance * distance) - edge) / (1 - edge)
        }
    }
}

/// Nominal sample support (including zero-valued endpoints) is distinct from effective duration.
public struct WindowSpecification: Sendable, Hashable, Codable {
    /// Bounded to support the widest SWIPE-prime window at 192 kHz / 20 Hz.
    /// Three Double sample buffers occupy at most 3 MiB; all supported platforms use 64-bit Int.
    public static let maximumSampleCount = 131_072
    public let definition: WindowDefinition
    public let sampleCount: Int
    public let sampleRate: Double
    public let precision: AnalysisPrecision
    public var fullDurationSeconds: Double { Double(sampleCount) / sampleRate }
    public var effectiveDurationSeconds: Double {
        fullDurationSeconds * definition.effectiveDurationFraction
    }

    public init(
        definition: WindowDefinition, sampleCount: Int, sampleRate: Double,
        precision: AnalysisPrecision = .float64
    ) throws {
        guard (1...Self.maximumSampleCount).contains(sampleCount), sampleRate.isFinite,
            sampleRate > 0, (Double(sampleCount) / sampleRate).isFinite
        else { throw ContractError.invalidConfiguration }
        self.definition = definition
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
        self.precision = precision
    }

    /// Projects the window fields only; it does not validate an executable algorithm profile.
    public init(windowFieldsOf profile: AnalysisProfile) throws {
        guard profile.window.version == 1,
            let definition = WindowDefinition(rawValue: profile.window.name)
        else { throw ContractError.invalidConfiguration }
        try self.init(
            definition: definition, sampleCount: profile.frameLength,
            sampleRate: profile.analysisSampleRate, precision: profile.precision)
    }

    public func identity() throws -> ProfileIdentity {
        let bytes = try canonicalContractJSON(self)
        return try ProfileIdentity(
            identifier: VersionedIdentifier(name: definition.rawValue, version: 1),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case definition, sampleCount, sampleRate, precision
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            definition: c.decode(WindowDefinition.self, forKey: .definition),
            sampleCount: c.decode(Int.self, forKey: .sampleCount),
            sampleRate: c.decode(Double.self, forKey: .sampleRate),
            precision: c.decode(AnalysisPrecision.self, forKey: .precision))
    }
}

public enum FramingError: Error, Sendable, Equatable {
    case precisionMismatch, invalidBufferSize, nonfiniteSample, overlappingBuffers
    case unexpectedInterval, invalidState, reentrantCall
}

/// Padding is numerical workspace, never observed source support or a successful estimate.
public struct WindowApplication: Sendable, Hashable {
    public let observedSampleCount: Int
    public let missingWindowSampleCount: Int
    public let transformPaddingSampleCount: Int
    public var unavailability: UnavailabilityReason? {
        missingWindowSampleCount == 0 ? nil : .insufficientData
    }
}

/// Immutable coefficients prepared once. Float32 gains describe the rounded Float coefficients.
/// Sharing this immutable object is safe; output buffers remain caller-owned and exclusive.
public final class PreparedWindow<Sample: BinaryFloatingPoint & Sendable>: Sendable {
    public let specification: WindowSpecification
    public let identity: ProfileIdentity
    public let coherentGain: Double
    /// Mean squared coefficient, not its square root and not an amplitude correction.
    public let energyGain: Double
    private let coefficients: [Sample]

    public init(_ specification: WindowSpecification) throws {
        guard
            (Sample.self == Float.self && specification.precision == .float32)
                || (Sample.self == Double.self && specification.precision == .float64)
        else { throw FramingError.precisionMismatch }
        self.specification = specification
        self.identity = try specification.identity()
        let values = (0..<specification.sampleCount).map {
            Sample(specification.definition.coefficient(at: $0, count: specification.sampleCount))
        }
        self.coefficients = values
        self.coherentGain = values.reduce(0) { $0 + Double($1) } / Double(values.count)
        self.energyGain = values.reduce(0) { $0 + Double($1) * Double($1) } / Double(values.count)
    }

    /// Explicit owned debug output. Calling this is outside the allocation-free processing claim.
    public func coefficientSnapshot() -> [Sample] { coefficients }

    /// Window observed samples, then zero-fill missing window support and transform padding.
    /// A short input returns insufficientData; its zeros must not become observed duration.
    /// Exact in-place operation is supported. Other overlapping ranges are rejected.
    /// Validation precedes every output write. Finite preprocessed amplitudes may exceed ±1.
    @discardableResult
    public func write(
        _ samples: UnsafeBufferPointer<Sample>, into output: UnsafeMutableBufferPointer<Sample>
    ) throws -> WindowApplication {
        let length = specification.sampleCount
        guard samples.count <= length, output.count >= length else {
            throw FramingError.invalidBufferSize
        }
        let outputBytes = output.count.multipliedReportingOverflow(by: MemoryLayout<Sample>.stride)
        guard !outputBytes.overflow else { throw ContractError.arithmeticOverflow }
        if let source = samples.baseAddress, let target = output.baseAddress, !samples.isEmpty {
            let sourceStart = UInt(bitPattern: source)
            let targetStart = UInt(bitPattern: target)
            let sourceEnd = sourceStart.addingReportingOverflow(
                UInt(samples.count * MemoryLayout<Sample>.stride))
            let targetEnd = targetStart.addingReportingOverflow(UInt(outputBytes.partialValue))
            guard !sourceEnd.overflow && !targetEnd.overflow else {
                throw ContractError.arithmeticOverflow
            }
            if sourceStart != targetStart && sourceStart < targetEnd.partialValue
                && targetStart < sourceEnd.partialValue
            {
                throw FramingError.overlappingBuffers
            }
        }
        for value in samples where !value.isFinite { throw FramingError.nonfiniteSample }
        for index in samples.indices { output[index] = samples[index] * coefficients[index] }
        for index in samples.count..<output.count { output[index] = 0 }
        return WindowApplication(
            observedSampleCount: samples.count, missingWindowSampleCount: length - samples.count,
            transformPaddingSampleCount: output.count - length)
    }
}
