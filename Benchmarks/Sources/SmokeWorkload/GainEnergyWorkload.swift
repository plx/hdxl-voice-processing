import HDXLVoiceProcessing

/// Original benchmark-only gain/energy kernel; not a production voice metric.
/// A single benchmark owns this state. Setup and checksum traversal are untimed.
public final class GainEnergyWorkload {
    public static let framesPerBatch = 1000
    public let format: PCMFormat
    public let input: [Double]
    public private(set) var output: [Double]
    public private(set) var energy = 0.0

    public init() throws {
        format = try PCMFormat(sampleRate: 48_000, channelCount: 1, encoding: .float64)
        input = (0..<1024).map { Double(($0 * 37) % 257 - 128) / 128.0 }
        output = Array(repeating: 0, count: input.count)
    }

    /// Non-inlined, bounded work over preallocated buffers, including output writes.
    @inline(never)
    public func run() -> Double {
        var sum = 0.0
        for index in input.indices {
            let value = input[index] * 0.5
            output[index] = value
            sum += value * value
        }
        energy = sum
        return sum
    }

    /// FNV-1a of output IEEE-754 bytes in explicit little-endian order.
    public var checksum: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for value in output {
            let bits = value.bitPattern
            for shift in stride(from: 0, to: 64, by: 8) {
                hash ^= (bits >> shift) & 0xFF
                hash &*= 1_099_511_628_211
            }
        }
        return String(hash, radix: 16)
    }

    // Independently computed with Python's struct.pack('<d', value) and integer FNV.
    public static let expectedChecksum = "b60cf45de1595748"
    public static let expectedEnergy = 86.15017700195312
}
