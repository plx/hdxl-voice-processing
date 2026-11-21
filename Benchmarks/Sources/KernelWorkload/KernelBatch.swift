#if KernelBenchmarks
    import Dispatch
    import Foundation
    import HDXLVoiceProcessing

    public struct KernelRecord: Codable, Sendable {
        public let name: String
        public let workload: KernelCase
        public let operationsPerBatch: Int
        public let calibrationMedianNanoseconds: UInt64
        public let expectedSample: Double
        public let verifiedSample: Double
        public let generator: String
        public let fitPoints: Int?
        public let slopeEvaluations: Int?
        public let searchBins: Int?

        public init(_ item: KernelCase) throws {
            let trial = try item.makeTrial()
            if item.operation == .backgroundFit {
                let layout = try CPPLayout(profile: item.cppProfile())
                fitPoints = layout.fitPointCount
                slopeEvaluations = layout.slopeEvaluationCount
                searchBins = nil
            } else if item.operation == .peakDiscrete || item.operation == .peakParabolic {
                let layout = try CPPLayout(profile: item.cppProfile())
                let start = Int(ceil(layout.searchStartSeconds / layout.quefrencyStepSeconds))
                let end = min(
                    layout.binCount - 1,
                    Int(floor(layout.searchEndSeconds / layout.quefrencyStepSeconds)))
                searchBins = max(0, end - start + 1)
                fitPoints = nil
                slopeEvaluations = nil
            } else {
                fitPoints = nil
                slopeEvaluations = nil
                searchBins = nil
            }
            generator = "kernel-analytic-v1"
            name = item.name
            workload = item
            expectedSample = trial.expected
            var samples: [UInt64] = []
            var observed = Double.nan
            for repeatIndex in 0..<11 {
                trial.reset()
                let start = DispatchTime.now().uptimeNanoseconds
                observed = try trial.run()
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                if repeatIndex >= 2 { samples.append(elapsed) }
                try Self.check(observed, expected: trial.expected, item: item)
            }
            verifiedSample = observed
            calibrationMedianNanoseconds = samples.sorted()[samples.count / 2]
            var count = 1
            while count < 128 && UInt64(count) * calibrationMedianNanoseconds < 50_000 {
                count *= 2
            }
            operationsPerBatch = item.controlBatch ?? count
        }

        static func check(_ actual: Double, expected: Double, item: KernelCase) throws {
            // Binary32 spectral power can reach subnormal values in the near-floor cases.
            let tolerance =
                item.precision == .float32
                ? max(8 * Double(Float.leastNonzeroMagnitude), 2e-5 * abs(expected))
                : max(8 * Double.leastNonzeroMagnitude, 1e-10 * abs(expected))
            guard actual.isFinite, expected.isFinite, abs(actual - expected) <= tolerance else {
                throw KernelError.sample(item.name, actual: actual, expected: expected)
            }
        }
    }

    public enum KernelError: Error {
        case sample(String, actual: Double, expected: Double)
        case invalidPlan
    }

    public final class KernelBatch {
        private let trials: [KernelTrial]
        private let record: KernelRecord

        public init(_ record: KernelRecord) throws {
            guard (1...128).contains(record.operationsPerBatch),
                record.operationsPerBatch.nonzeroBitCount == 1,
                record.name == record.workload.name
            else { throw KernelError.invalidPlan }
            self.record = record
            let states = record.workload.operation.needsFreshInput ? record.operationsPerBatch : 1
            trials = try (0..<states).map { _ in try record.workload.makeTrial() }
        }
        public func reset() { for trial in trials { trial.reset() } }

        @inline(never) public func run() throws -> Double {
            var checksum = 0.0
            if trials.count == 1 {
                let trial = trials[0]
                for _ in 0..<record.operationsPerBatch { checksum += try trial.run() }
            } else {
                for trial in trials { checksum += try trial.run() }
            }
            return checksum
        }
        public func verify(_ checksum: Double) throws {
            try KernelRecord.check(
                checksum / Double(record.operationsPerBatch), expected: record.expectedSample,
                item: record.workload)
        }
    }
#endif
