import CryptoKit
import Foundation

public enum FourierError: Error, Sendable, Equatable {
    case unsupportedLength, precisionMismatch, setupFailed, invalidBufferSize
    case nonfiniteInput, nonfiniteResult, nonrealEndpoint, invalidNormalization
}

/// Ordinary complex value. Real-transform public output has N/2+1 of these, including both endpoints.
/// This is not vDSP's packed split-complex representation.
public struct FourierBin<Sample: BinaryFloatingPoint & Sendable>: Sendable, Hashable {
    public var real: Sample
    public var imaginary: Sample
    public init(real: Sample, imaginary: Sample = 0) {
        self.real = real
        self.imaginary = imaginary
    }
}

/// Negative-exponent, unnormalized forward DFT; positive-exponent inverse divided by N.
/// Version 1 supports exactly the powers of two from 2 through 65536, in Float or Double.
public struct FourierConfiguration: Sendable, Hashable, Codable {
    public static let maximumLength = 65_536
    public let length: Int
    public let sampleRate: Double
    public let precision: AnalysisPrecision
    public var realBinCount: Int { length / 2 + 1 }
    public var frequencySpacingHz: Double { sampleRate / Double(length) }

    public init(length: Int, sampleRate: Double, precision: AnalysisPrecision = .float64) throws {
        guard (2...Self.maximumLength).contains(length), length.nonzeroBitCount == 1 else {
            throw FourierError.unsupportedLength
        }
        guard sampleRate.isFinite, sampleRate > 0,
            sampleRate / Double(length) > 0, (Double(length) / sampleRate).isFinite
        else { throw ContractError.invalidConfiguration }
        self.length = length
        self.sampleRate = sampleRate
        self.precision = precision
    }

    /// One-sided real-transform bin frequency, including DC and Nyquist.
    public func realFrequencyHz(at bin: Int) throws -> Double {
        guard (0..<realBinCount).contains(bin) else { throw ContractError.invalidValue }
        return sampleRate * (Double(bin) / Double(length))
    }

    /// Complex storage order is 0,...,N/2-1,-N/2,...,-1 times fs/N.
    public func complexFrequencyHz(at bin: Int) throws -> Double {
        guard (0..<length).contains(bin) else { throw ContractError.invalidValue }
        return sampleRate * (Double(bin < length / 2 ? bin : bin - length) / Double(length))
    }

    /// Explicit helper; preparation never silently rounds a requested transform length.
    public static func lengthPadding(_ sampleCount: Int) throws -> Int {
        guard (1...maximumLength).contains(sampleCount) else {
            throw FourierError.unsupportedLength
        }
        var result = 2
        while result < sampleCount { result *= 2 }
        return result
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(
                name: "fourier-negative-forward-inverse-over-n", version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case length, sampleRate, precision }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            length: c.decode(Int.self, forKey: .length),
            sampleRate: c.decode(Double.self, forKey: .sampleRate),
            precision: c.decode(AnalysisPrecision.self, forKey: .precision))
    }
}

/// Describes numerical padding only. The caller retains the original frame's support and status.
/// Supplied samples may themselves include window padding; this does not certify observed duration.
public struct FourierApplication: Sendable, Hashable {
    public let suppliedSampleCount: Int
    public let zeroPaddingSampleCount: Int
}
