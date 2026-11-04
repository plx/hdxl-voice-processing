import Foundation

/// Denominator convention: 1 + a1 z^-1 + a2 z^-2. Processing subtracts feedback.
public struct LevelBiquadCoefficients: Sendable, Hashable, Codable {
    public let b0: Double
    public let b1: Double
    public let b2: Double
    public let a1: Double
    public let a2: Double

    fileprivate init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) throws {
        guard [b0, b1, b2, a1, a2].allSatisfy(\.isFinite),
            abs(a2) < 1, 1 + a1 + a2 > 0, 1 - a1 + a2 > 0
        else { throw ContractError.invalidConfiguration }
        self.b0 = b0 == 0 ? 0 : b0
        self.b1 = b1 == 0 ? 0 : b1
        self.b2 = b2 == 0 ? 0 : b2
        self.a1 = a1 == 0 ? 0 : a1
        self.a2 = a2 == 0 ? 0 : a2
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case b0, b1, b2, a1, a2 }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            b0: c.decode(Double.self, forKey: .b0), b1: c.decode(Double.self, forKey: .b1),
            b2: c.decode(Double.self, forKey: .b2), a1: c.decode(Double.self, forKey: .a1),
            a2: c.decode(Double.self, forKey: .a2))
    }

    /// Original inverse-bilinear reconstruction from the normative 48 kHz tables.
    /// Prewarp each stage at its recovered pole frequency, preserving its shelf gains.
    /// The RLB stage retains the specified [1, -2, 1] numerator at every rate.
    fileprivate func atRate(_ rate: Int, highpass: Bool) throws -> Self {
        if rate == 48_000 { return self }
        let d0 = 1 + a1 + a2
        let d1 = 2 * (1 - a2)
        let d2 = 1 - a1 + a2
        let referenceWarp = sqrt(d0 / d2)
        let poleFrequency = 48_000 / Double.pi * atan(referenceWarp)
        let ratio = referenceWarp / tan(Double.pi * poleFrequency / Double(rate))
        let squared = ratio * ratio
        let denominator = d2 * squared + d1 * ratio + d0
        let n0 = b0 + b1 + b2
        let n1 = 2 * (b0 - b2)
        let n2 = b0 - b1 + b2
        return try Self(
            b0: highpass ? 1 : (n2 * squared + n1 * ratio + n0) / denominator,
            b1: highpass ? -2 : 2 * (n0 - n2 * squared) / denominator,
            b2: highpass ? 1 : (n2 * squared - n1 * ratio + n0) / denominator,
            a1: 2 * (d0 - d2 * squared) / denominator,
            a2: (d2 * squared - d1 * ratio + d0) / denominator)
    }

    fileprivate func response(omega: Double) -> (gain: Double, phase: Double?, delay: Double?) {
        let c1 = cos(omega)
        let s1 = sin(omega)
        let c2 = cos(2 * omega)
        let s2 = sin(2 * omega)
        let nr = b0 + b1 * c1 + b2 * c2
        let ni = -b1 * s1 - b2 * s2
        let dr = 1 + a1 * c1 + a2 * c2
        let di = -a1 * s1 - a2 * s2
        let ddr = -a1 * s1 - 2 * a2 * s2
        let ddi = -a1 * c1 - 2 * a2 * c2
        let nPower = nr * nr + ni * ni
        let dPower = dr * dr + di * di
        if b0 == 1 && b1 == -2 && b2 == 1 {
            guard omega > 0 else { return (0, nil, nil) }
            // (1-z^-1)^2 = -4 exp(-i omega) sin(omega/2)^2. This form avoids
            // subtracting nearly equal values near DC. Its group delay is exactly one sample.
            let sine = sin(omega / 2)
            return (
                4 * sine * sine / sqrt(dPower),
                .pi - omega - atan2(di, dr),
                1 + (ddi * dr - ddr * di) / dPower
            )
        }
        guard nPower > 0 else { return (0, nil, nil) }
        // Im(H'/H) is the phase derivative with respect to angular frequency.
        let ndr = -b1 * s1 - 2 * b2 * s2
        let ndi = -b1 * c1 - 2 * b2 * c2
        let delay = (ddi * dr - ddr * di) / dPower - (ndi * nr - ndr * ni) / nPower
        return (sqrt(nPower / dPower), atan2(ni, nr) - atan2(di, dr), delay)
    }
}

/// An evaluation of the causal filter, not a constant timestamp correction or lookahead.
public struct KWeightingResponse: Sendable, Hashable {
    public let frequencyHz: Double
    public let magnitude: Double
    /// Undefined at a transfer-function zero; the combined phase is wrapped to [-pi, pi].
    public let phaseRadians: Double?
    /// Signed frequency-dependent group delay. Undefined at a transfer-function zero.
    public let groupDelaySeconds: Double?
}

/// ITU-R BS.1770-5 Annex 1, Tables 1/2; independently reconstructed for other rates.
/// This supplies K-weighting only: no channel loudness sum, gating, LUFS, or true peak.
public struct KWeightingCoefficients: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let method: VersionedIdentifier
    public let sampleRate: Int
    public let shelf: LevelBiquadCoefficients
    public let highpass: LevelBiquadCoefficients

    public init(sampleRate: Int) throws {
        guard (16_000...192_000).contains(sampleRate) else {
            throw ContractError.invalidConfiguration
        }
        self.schemaVersion = 1
        self.method = try VersionedIdentifier(name: "bs1770-5-prewarped-tables", version: 1)
        self.sampleRate = sampleRate
        self.shelf = try LevelBiquadCoefficients(
            b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
            a1: -1.69065929318241, a2: 0.73248077421585
        ).atRate(sampleRate, highpass: false)
        self.highpass = try LevelBiquadCoefficients(
            b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621
        ).atRate(sampleRate, highpass: true)
    }

    public func response(at frequencyHz: Double) throws -> KWeightingResponse {
        guard frequencyHz.isFinite, (0...Double(sampleRate) / 2).contains(frequencyHz) else {
            throw ContractError.invalidValue
        }
        let omega = 2 * Double.pi * frequencyHz / Double(sampleRate)
        let first = shelf.response(omega: omega)
        let second = highpass.response(omega: omega)
        let phase = first.phase.flatMap { p in second.phase.map { atan2(sin(p + $0), cos(p + $0)) }
        }
        let delay = first.delay.flatMap { d in second.delay.map { (d + $0) / Double(sampleRate) } }
        return KWeightingResponse(
            frequencyHz: frequencyHz == 0 ? 0 : frequencyHz,
            magnitude: first.gain * second.gain, phaseRadians: phase, groupDelaySeconds: delay)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, method, sampleRate, shelf, highpass
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(sampleRate: c.decode(Int.self, forKey: .sampleRate))
        guard try c.decode(VersionedIdentifier.self, forKey: .method) == method,
            try c.decode(LevelBiquadCoefficients.self, forKey: .shelf) == shelf,
            try c.decode(LevelBiquadCoefficients.self, forKey: .highpass) == highpass
        else { throw ContractError.invalidConfiguration }
    }
}
