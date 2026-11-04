import CryptoKit
import Foundation

/// Full observed window support M and transform support N are different quantities.
/// The input spectrum must come from this window applied to all M observed samples, padded to N.
/// A short/unavailable frame must retain its upstream status and cannot use these gains to certify a measurement.
public struct SpectrumConfiguration: Sendable, Hashable, Codable {
    public let transform: FourierConfiguration
    public let window: WindowSpecification

    public init(transform: FourierConfiguration, window: WindowSpecification) throws {
        guard window.sampleCount <= transform.length, window.sampleRate == transform.sampleRate,
            window.precision == transform.precision
        else { throw FourierError.invalidNormalization }
        self.transform = transform
        self.window = window
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: "one-sided-window-spectrum", version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case transform, window }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            transform: c.decode(FourierConfiguration.self, forKey: .transform),
            window: c.decode(WindowSpecification.self, forKey: .window))
    }
}

/// Single-owner conversion workspace; intentionally not Sendable. Prepared scalar factors are reused.
/// DC/Nyquist weight c=1, interior positive bins c=2. No logarithm, floor, or clipping is applied.
/// Floating-point underflow to zero remains possible at the selected output precision.
public final class PreparedSpectrum<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: SpectrumConfiguration
    public let identity: ProfileIdentity
    public let windowIdentity: ProfileIdentity
    public let coherentGain: Double
    public let energyGain: Double
    public var scalarWorkspaceBytes: Int {
        configuration.transform.realBinCount * MemoryLayout<Sample>.stride
    }
    private let scratch: UnsafeMutablePointer<Sample>
    private let amplitude: (Sample, Sample)?
    private let powerRoot: (Sample, Sample)?
    private let densityRoot: (Sample, Sample)?

    public init(_ configuration: SpectrumConfiguration) throws {
        let window = try PreparedWindow<Sample>(configuration.window)
        self.configuration = configuration
        self.identity = try configuration.identity()
        self.windowIdentity = window.identity
        self.coherentGain = window.coherentGain
        self.energyGain = window.energyGain
        let m = Double(configuration.window.sampleCount)
        let n = Double(configuration.transform.length)
        let rate = configuration.transform.sampleRate
        func factors(_ endpoint: Double, _ interior: Double) -> (Sample, Sample)? {
            let a = Sample(endpoint)
            let b = Sample(interior)
            guard a.isFinite, b.isFinite, a > 0, b > 0 else { return nil }
            return (a, b)
        }
        // Store square roots: scale before squaring to avoid avoidable intermediate overflow/underflow.
        amplitude = factors(1 / (m * window.coherentGain), 2 / (m * window.coherentGain))
        let energy = m * window.energyGain
        powerRoot = factors(sqrt(1 / n / energy), sqrt(2 / n / energy))
        densityRoot = factors(sqrt(1 / rate / energy), sqrt(2 / rate / energy))
        scratch = .allocate(capacity: configuration.transform.realBinCount)
        scratch.initialize(repeating: 0, count: configuration.transform.realBinCount)
    }

    deinit {
        scratch.deinitialize(count: configuration.transform.realBinCount)
        scratch.deallocate()
    }

    /// Raw |X[k]|, with no endpoint weighting or gain correction. Units: input amplitude times samples.
    public func writeMagnitude(
        _ bins: UnsafeBufferPointer<FourierBin<Sample>>,
        into output: UnsafeMutableBufferPointer<Sample>
    ) throws {
        try convert(bins, into: output, factors: (1, 1), squared: false)
    }

    /// c|X[k]| / (M * coherentGain): bin-centered sinusoidal peak amplitude convention.
    /// Off-bin leakage and overlapping window lobes are not corrected by this operation.
    public func writeAmplitude(
        _ bins: UnsafeBufferPointer<FourierBin<Sample>>,
        into output: UnsafeMutableBufferPointer<Sample>
    ) throws {
        guard let amplitude else { throw FourierError.invalidNormalization }
        try convert(bins, into: output, factors: amplitude, squared: false)
    }

    /// c|X[k]|² / (N * M * energyGain): each bin's contribution to energy-corrected mean square.
    /// Summing bins gives sum((x*w)²) / sum(w²), including when N > M.
    public func writePower(
        _ bins: UnsafeBufferPointer<FourierBin<Sample>>,
        into output: UnsafeMutableBufferPointer<Sample>
    ) throws {
        guard let powerRoot else { throw FourierError.invalidNormalization }
        try convert(bins, into: output, factors: powerRoot, squared: true)
    }

    /// c|X[k]|² / (fs * M * energyGain): periodogram density, input amplitude² per Hz.
    /// Sum(density) * fs/N equals sum(writePower(...)).
    public func writePowerDensity(
        _ bins: UnsafeBufferPointer<FourierBin<Sample>>,
        into output: UnsafeMutableBufferPointer<Sample>
    ) throws {
        guard let densityRoot else { throw FourierError.invalidNormalization }
        try convert(bins, into: output, factors: densityRoot, squared: true)
    }

    private func convert(
        _ bins: UnsafeBufferPointer<FourierBin<Sample>>,
        into output: UnsafeMutableBufferPointer<Sample>,
        factors: (Sample, Sample), squared: Bool
    ) throws {
        let count = configuration.transform.realBinCount
        guard bins.count == count, output.count == count else {
            throw FourierError.invalidBufferSize
        }
        for z in bins where !z.real.isFinite || !z.imaginary.isFinite {
            throw FourierError.nonfiniteInput
        }
        guard bins[0].imaginary == 0, bins[count - 1].imaginary == 0 else {
            throw FourierError.nonrealEndpoint
        }
        for k in 0..<count {
            let factor = k == 0 || k == count - 1 ? factors.0 : factors.1
            let a = abs(bins[k].real) * factor
            let b = abs(bins[k].imaginary) * factor
            let hi = max(a, b)
            let lo = min(a, b)
            let ratio = hi == 0 ? 0 : lo / hi
            let magnitude = hi * (1 + ratio * ratio).squareRoot()
            let result = squared ? magnitude * magnitude : magnitude
            guard result.isFinite else { throw FourierError.nonfiniteResult }
            scratch[k] = result
        }
        for k in 0..<count { output[k] = scratch[k] }
    }
}
