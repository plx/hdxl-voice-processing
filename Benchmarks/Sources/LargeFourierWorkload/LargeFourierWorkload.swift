import Foundation
import HDXLVoiceProcessing

public enum LargeFourierOperation: String, Codable, Sendable, CaseIterable {
    case prepare = "Prepare"
    case forwardReal = "ForwardReal"
    case inverseReal = "InverseReal"
    case forwardComplex = "ForwardComplex"
    case inverseComplex = "InverseComplex"
}

public struct LargeFourierCase: Codable, Sendable {
    public let name: String
    public let configuration: FourierConfiguration
    public let identity: ProfileIdentity
    public let operationsPerIteration: Int
    public let scalarWorkspaceBytes: Int
    /// Caller-owned input plus output scalars, excluding the plan's separate 2N scalar workspace.
    public let operationBufferBytes: [String: Int]
    /// Length of the synthetic transform buffer divided by fs, not certified observed utterance duration.
    public let transformBufferSeconds: Double

    private init(length: Int, precision: AnalysisPrecision) throws {
        configuration = try FourierConfiguration(
            length: length, sampleRate: 48_000, precision: precision)
        identity = try configuration.identity()
        name = "\(precision.rawValue).48000Hz.N\(length)"
        operationsPerIteration = 1
        let stride = precision == .float32 ? 4 : 8
        scalarWorkspaceBytes = 2 * length * stride
        let realBuffers = (length + 2 * (length / 2 + 1)) * stride
        operationBufferBytes = [
            "Prepare": 0, "ForwardReal": realBuffers, "InverseReal": realBuffers,
            "ForwardComplex": 4 * length * stride, "InverseComplex": 4 * length * stride,
        ]
        transformBufferSeconds = Double(length) / 48_000
    }

    public static func matrix() throws -> [Self] {
        try [AnalysisPrecision.float32, .float64].flatMap { precision in
            try (17...22).map { try Self(length: 1 << $0, precision: precision) }
        }
    }
    public func makeWorkload(_ operation: LargeFourierOperation) throws -> any LargeFourierBatch {
        if configuration.precision == .float32 {
            return try LargeFourierWorkload<Float>(self, operation: operation)
        }
        return try LargeFourierWorkload<Double>(self, operation: operation)
    }
}

public struct LargeFourierOutput: Sendable {
    public let real: Double
    public let imaginary: Double
}

public protocol LargeFourierBatch: AnyObject {
    var ownedBufferBytes: Int { get }
    func prepare() throws -> AnyObject
    func run() throws -> LargeFourierOutput
    func verify() throws
}

/// Only the selected operation's input/output buffers are retained. No concurrent large plans.
private final class LargeFourierWorkload<S: BinaryFloatingPoint & Sendable>: LargeFourierBatch {
    let item: LargeFourierCase
    let operation: LargeFourierOperation
    let plan: PreparedFourierTransform<S>?
    let realInput: [S]
    let complexInput: [FourierBin<S>]
    let realOutput: UnsafeMutableBufferPointer<S>
    let complexOutput: UnsafeMutableBufferPointer<FourierBin<S>>
    let expected: LargeFourierOutput
    let errorBound: Double
    var ownedBufferBytes: Int {
        (realInput.count + realOutput.count) * MemoryLayout<S>.stride
            + (complexInput.count + complexOutput.count) * MemoryLayout<FourierBin<S>>.stride
    }

    init(_ item: LargeFourierCase, operation: LargeFourierOperation) throws {
        self.item = item
        self.operation = operation
        let n = item.configuration.length
        plan = operation == .prepare ? nil : try PreparedFourierTransform(item.configuration)
        var state: UInt32 = 95
        func sample() -> S {
            state = 1_664_525 &* state &+ 1_013_904_223
            return S((Double(state) - 2_147_483_648) / 2_147_483_648)
        }
        var real: [S] = []
        var complex: [FourierBin<S>] = []
        var realCount = 0
        var complexCount = 0
        switch operation {
        case .prepare: break
        case .forwardReal:
            real = (0..<n).map { _ in sample() }
            complexCount = n / 2 + 1
        case .inverseReal:
            complex = (0...n / 2).map { _ in FourierBin(real: sample(), imaginary: sample()) }
            complex[0].imaginary = 0
            complex[n / 2].imaginary = 0
            realCount = n
        case .forwardComplex, .inverseComplex:
            complex = (0..<n).map { _ in FourierBin(real: sample(), imaginary: sample()) }
            complexCount = n
        }
        realInput = real
        complexInput = complex
        if realCount > 0 {
            realOutput = .allocate(capacity: realCount)
            realOutput.initialize(repeating: 0)
        } else {
            realOutput = UnsafeMutableBufferPointer(start: nil, count: 0)
        }
        if complexCount > 0 {
            complexOutput = .allocate(capacity: complexCount)
            complexOutput.initialize(repeating: FourierBin(real: 0))
        } else {
            complexOutput = UnsafeMutableBufferPointer(start: nil, count: 0)
        }
        var sumReal = real.reduce(0.0) { $0 + Double($1) }
        var sumImaginary = 0.0
        var energy = real.reduce(0.0) { $0 + Double($1) * Double($1) }
        for (k, z) in complex.enumerated() {
            let weight = operation == .inverseReal && k != 0 && k != n / 2 ? 2.0 : 1.0
            sumReal += weight * Double(z.real)
            if operation != .inverseReal { sumImaginary += Double(z.imaginary) }
            energy +=
                weight
                * (Double(z.real) * Double(z.real) + Double(z.imaginary) * Double(z.imaginary))
        }
        let inverse = operation == .inverseReal || operation == .inverseComplex
        let divisor = inverse ? Double(n) : 1
        expected = LargeFourierOutput(real: sumReal / divisor, imaginary: sumImaginary / divisor)
        let coefficient = item.configuration.precision == .float32 ? 8.0 : 64.0
        errorBound =
            coefficient * Double(S.ulpOfOne) / 2 * Double(n.trailingZeroBitCount) * sqrt(energy)
            / divisor
    }
    deinit {
        realOutput.baseAddress?.deinitialize(count: realOutput.count)
        realOutput.baseAddress?.deallocate()
        complexOutput.baseAddress?.deinitialize(count: complexOutput.count)
        complexOutput.baseAddress?.deallocate()
    }
    @inline(never) func prepare() throws -> AnyObject {
        try PreparedFourierTransform<S>(item.configuration)
    }
    @inline(never) func run() throws -> LargeFourierOutput {
        let plan = plan!
        switch operation {
        case .forwardReal:
            try realInput.withUnsafeBufferPointer {
                _ = try plan.forwardReal($0, into: complexOutput)
            }
        case .inverseReal:
            try complexInput.withUnsafeBufferPointer { try plan.inverseReal($0, into: realOutput) }
            return LargeFourierOutput(real: Double(realOutput[0]), imaginary: 0)
        case .forwardComplex:
            try complexInput.withUnsafeBufferPointer {
                _ = try plan.forwardComplex($0, into: complexOutput)
            }
        case .inverseComplex:
            try complexInput.withUnsafeBufferPointer {
                try plan.inverseComplex($0, into: complexOutput)
            }
        case .prepare: preconditionFailure("Use prepare() for setup")
        }
        return LargeFourierOutput(
            real: Double(complexOutput[0].real), imaginary: Double(complexOutput[0].imaginary))
    }
    func verify() throws {
        precondition(ownedBufferBytes == item.operationBufferBytes[operation.rawValue])
        if operation == .prepare {
            let plan = try PreparedFourierTransform<S>(item.configuration)
            precondition(plan.scalarWorkspaceBytes == item.scalarWorkspaceBytes)
        } else {
            precondition(plan!.scalarWorkspaceBytes == item.scalarWorkspaceBytes)
            let value = try run()
            precondition(value.real.isFinite && value.imaginary.isFinite)
            precondition(abs(value.real - expected.real) <= errorBound)
            precondition(abs(value.imaginary - expected.imaginary) <= errorBound)
        }
    }
}
