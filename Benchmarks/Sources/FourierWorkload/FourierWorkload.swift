import Foundation
import HDXLVoiceProcessing

public enum FourierOperation: String, Codable, Sendable, CaseIterable {
    case prepareFFT = "PrepareFFT"
    case prepareSpectrum = "PrepareSpectrum"
    case forwardReal = "ForwardReal"
    case inverseReal = "InverseReal"
    case forwardComplex = "ForwardComplex"
    case inverseComplex = "InverseComplex"
    case spectrum = "Spectrum"
    case cepstrum = "Cepstrum"
    case scalarDFT = "ScalarDFT"
}

public struct FourierCase: Codable, Sendable {
    public let name: String
    public let configuration: FourierConfiguration
    public let transformIdentity: ProfileIdentity
    public let spectrumConfiguration: SpectrumConfiguration
    public let spectrumIdentity: ProfileIdentity
    public let inputDurationSeconds: Double
    public let operationsPerIteration: Int
    public let comparisonWorkerCount: Int
    public let cepstrumPowerFloor: Double
    public var operations: [FourierOperation] {
        FourierOperation.allCases.filter { $0 != .scalarDFT || configuration.length <= 128 }
    }

    private init(length: Int, precision: AnalysisPrecision) throws {
        configuration = try FourierConfiguration(
            length: length, sampleRate: 48_000, precision: precision)
        transformIdentity = try configuration.identity()
        spectrumConfiguration = try SpectrumConfiguration(
            transform: configuration,
            window: WindowSpecification(
                definition: .rectangular, sampleCount: length, sampleRate: 48_000,
                precision: precision))
        spectrumIdentity = try spectrumConfiguration.identity()
        name = "\(precision.rawValue).48000Hz.N\(length)"
        inputDurationSeconds = Double(length) / 48_000
        operationsPerIteration = 10
        comparisonWorkerCount = 4
        cepstrumPowerFloor = 1e-30
    }

    public static func matrix() throws -> [Self] {
        try [AnalysisPrecision.float32, .float64].flatMap { precision in
            try [32, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536].map {
                try Self(length: $0, precision: precision)
            }
        }
    }
    public func makeWorkload() throws -> any FourierBatch {
        if configuration.precision == .float32 { return try FourierWorkload<Float>(self) }
        return try FourierWorkload<Double>(self)
    }
}

public protocol FourierBatch: AnyObject {
    func prepare(_ operation: FourierOperation) throws -> AnyObject
    func run(_ operation: FourierOperation, iterations: Int) throws -> Double
    func verify() throws
}

/// Actor-owned, separately prepared workspace. The timing comparison includes actor/task scheduling.
public actor FourierWorker {
    private let workload: any FourierBatch
    public init(_ item: FourierCase) throws { workload = try item.makeWorkload() }
    public func run(_ operation: FourierOperation, iterations: Int) throws -> Double {
        try workload.run(operation, iterations: iterations)
    }
}

private final class FourierWorkload<S: BinaryFloatingPoint & Sendable>: FourierBatch {
    let item: FourierCase
    let plan: PreparedFourierTransform<S>
    let conversion: PreparedSpectrum<S>
    let realInput: [S]
    let complexInput: [FourierBin<S>]
    let inverseRealInput: [FourierBin<S>]
    let inverseComplexInput: [FourierBin<S>]
    let realOutput: UnsafeMutableBufferPointer<S>
    let scalarOutput: UnsafeMutableBufferPointer<S>
    let halfOutput: UnsafeMutableBufferPointer<FourierBin<S>>
    let complexOutput: UnsafeMutableBufferPointer<FourierBin<S>>

    init(_ item: FourierCase) throws {
        self.item = item
        let preparedPlan = try PreparedFourierTransform<S>(item.configuration)
        plan = preparedPlan
        conversion = try PreparedSpectrum(item.spectrumConfiguration)
        let n = item.configuration.length
        var state: UInt32 = 30
        func sample() -> S {
            state = 1_664_525 &* state &+ 1_013_904_223
            return S((Double(state) - 2_147_483_648) / 2_147_483_648)
        }
        complexInput = (0..<n).map { _ in FourierBin(real: sample(), imaginary: sample()) }
        realInput = complexInput.map(\.real)
        var half = [FourierBin<S>](repeating: FourierBin(real: 0), count: n / 2 + 1)
        var full = [FourierBin<S>](repeating: FourierBin(real: 0), count: n)
        try realInput.withUnsafeBufferPointer { x in
            try half.withUnsafeMutableBufferPointer {
                _ = try preparedPlan.forwardReal(x, into: $0)
            }
        }
        try complexInput.withUnsafeBufferPointer { x in
            try full.withUnsafeMutableBufferPointer {
                _ = try preparedPlan.forwardComplex(x, into: $0)
            }
        }
        inverseRealInput = half
        inverseComplexInput = full
        realOutput = .allocate(capacity: n)
        realOutput.initialize(repeating: 0)
        scalarOutput = .allocate(capacity: n / 2 + 1)
        scalarOutput.initialize(repeating: 0)
        halfOutput = .allocate(capacity: n / 2 + 1)
        halfOutput.initialize(repeating: FourierBin(real: 0))
        complexOutput = .allocate(capacity: n)
        complexOutput.initialize(repeating: FourierBin(real: 0))
    }
    deinit {
        realOutput.deinitialize()
        realOutput.deallocate()
        scalarOutput.deinitialize()
        scalarOutput.deallocate()
        halfOutput.deinitialize()
        halfOutput.deallocate()
        complexOutput.deinitialize()
        complexOutput.deallocate()
    }

    @inline(never)
    func prepare(_ operation: FourierOperation) throws -> AnyObject {
        if operation == .prepareFFT { return try PreparedFourierTransform<S>(item.configuration) }
        precondition(operation == .prepareSpectrum)
        return try PreparedSpectrum<S>(item.spectrumConfiguration)
    }

    @inline(never)
    func run(_ operation: FourierOperation, iterations: Int) throws -> Double {
        var checksum = 0.0
        for _ in 0..<iterations {
            switch operation {
            case .forwardReal, .spectrum, .cepstrum:
                try realInput.withUnsafeBufferPointer {
                    _ = try plan.forwardReal($0, into: halfOutput)
                }
                if operation == .spectrum {
                    try conversion.writePower(UnsafeBufferPointer(halfOutput), into: scalarOutput)
                    checksum += Double(scalarOutput[0])
                } else if operation == .cepstrum {
                    // Explicit benchmark consumer choice. This floor is not part of the FFT API.
                    for k in halfOutput.indices {
                        let r = Double(halfOutput[k].real)
                        let i = Double(halfOutput[k].imaginary)
                        halfOutput[k] = FourierBin(
                            real: S(log(max(r * r + i * i, item.cepstrumPowerFloor))))
                    }
                    try plan.inverseReal(UnsafeBufferPointer(halfOutput), into: realOutput)
                    checksum += Double(realOutput[0])
                } else {
                    checksum += Double(halfOutput[0].real)
                }
            case .inverseReal:
                try inverseRealInput.withUnsafeBufferPointer {
                    try plan.inverseReal($0, into: realOutput)
                }
                checksum += Double(realOutput[0])
            case .forwardComplex:
                try complexInput.withUnsafeBufferPointer {
                    _ = try plan.forwardComplex($0, into: complexOutput)
                }
                checksum += Double(complexOutput[0].real) + Double(complexOutput[0].imaginary)
            case .inverseComplex:
                try inverseComplexInput.withUnsafeBufferPointer {
                    try plan.inverseComplex($0, into: complexOutput)
                }
                checksum += Double(complexOutput[0].real) + Double(complexOutput[0].imaginary)
            case .scalarDFT:
                scalarDFT()
                checksum += Double(complexOutput[0].real) + Double(complexOutput[0].imaginary)
            case .prepareFFT, .prepareSpectrum: preconditionFailure("Setup uses prepare(_:)")
            }
        }
        return checksum
    }

    /// Bounded developer comparison, direct mathematical definition with binary64 accumulation.
    private func scalarDFT() {
        let n = complexInput.count
        precondition(n <= 128)
        for k in 0..<n {
            var real = 0.0
            var imaginary = 0.0
            for j in 0..<n {
                let phase = -2 * Double.pi * Double((j * k) % n) / Double(n)
                let c = cos(phase)
                let s = sin(phase)
                let a = Double(complexInput[j].real)
                let b = Double(complexInput[j].imaginary)
                real += a * c - b * s
                imaginary += a * s + b * c
            }
            complexOutput[k] = FourierBin(real: S(real), imaginary: S(imaginary))
        }
    }

    func verify() throws {
        let n = item.configuration.length
        let tolerance = item.configuration.precision == .float32 ? 1e-4 : 1e-11
        let realDC = realInput.reduce(0.0) { $0 + Double($1) }
        let complexDC = complexInput.reduce(0.0) { $0 + Double($1.real) + Double($1.imaginary) }
        for operation in item.operations
        where operation != .prepareFFT && operation != .prepareSpectrum {
            let checksum = try run(operation, iterations: 1)
            precondition(checksum.isFinite)
            let expected: Double
            switch operation {
            case .forwardReal: expected = realDC
            case .forwardComplex, .scalarDFT: expected = complexDC
            case .inverseReal: expected = Double(realInput[0])
            case .inverseComplex:
                expected = Double(complexInput[0].real) + Double(complexInput[0].imaginary)
            case .spectrum:
                expected = realDC * realDC / Double(n * n)
                let energy = realInput.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(n)
                precondition(abs(scalarOutput.reduce(0) { $0 + Double($1) } - energy) < tolerance)
            case .cepstrum:
                var total = 0.0
                for k in inverseRealInput.indices {
                    let z = inverseRealInput[k]
                    let power =
                        Double(z.real) * Double(z.real) + Double(z.imaginary) * Double(z.imaginary)
                    total +=
                        (k == 0 || k == n / 2 ? 1 : 2) * log(max(power, item.cepstrumPowerFloor))
                }
                expected = total / Double(n)
            default: preconditionFailure("Unexpected setup")
            }
            precondition(abs(checksum - expected) < tolerance * max(1, abs(expected)))
        }
    }
}
