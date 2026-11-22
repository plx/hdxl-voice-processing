#if KernelBenchmarks
    import Foundation
    import HDXLVoiceProcessing

    public enum FormantOperation: String, CaseIterable {
        case resample = "Resample"
        case burg = "Burg"
        case roots = "Roots"
        case closeRoots = "CloseRoots"
        case boundedExit = "BoundedExit"
        case analyze = "Analyze"
    }

    public struct FormantCase: Encodable {
        public let name: String
        public let profile: BurgFormantProfile
        public let profileIdentity: ProfileIdentity
        public let source: SourceInterval
        public let durationSeconds: Double
        public let windowSamples, expectedFrames: Int
        public static func matrix() throws -> [Self] {
            let epoch = StreamEpoch(
                streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000046")!)
            var cases: [Self] = []
            for rate in [16000, 44100, 48000] {
                for ceiling in [5000, 5500, 6000] {
                    for hop in [5, 10] {
                        for order in [8, 10, 12, 16] {
                            let profile = try BurgFormantProfile(
                                sourceSampleRate: rate, ceilingHz: ceiling, order: order,
                                hopMilliseconds: hop)
                            let source = try SourceInterval(
                                epoch: epoch, startSample: 0, sampleCount: Int64(rate / 10),
                                sampleRate: Double(rate))
                            let worker = try PreparedBurgFormants<Double>(
                                configuration: profile, source: source)
                            cases.append(
                                .init(
                                    name: "r\(rate)-c\(ceiling)-o\(order)-h\(hop)",
                                    profile: profile,
                                    profileIdentity: worker.identity, source: source,
                                    durationSeconds: source.durationSeconds,
                                    windowSamples: profile.windowSamples,
                                    expectedFrames: worker.frameCount))
                        }
                    }
                }
            }
            return cases
        }
    }

    public final class FormantTrial {
        let item: FormantCase
        private let pcm, window, normalPolynomial, closePolynomial: [Double]
        private let analyzer: PreparedBurgFormants<Double>
        private let stages: FormantBenchmarkStages
        private let resampler: KernelBenchmarkConditioner<Double>
        private var sum = 0.0
        private var count = 0
        private var succeeded = false

        public init(_ item: FormantCase) throws {
            self.item = item
            let profile = item.profile
            analyzer = try .init(configuration: profile, source: item.source)
            resampler = try .init(analyzer.layout)
            stages = try .init(profile: profile)
            var state: UInt32 = 46
            func excitation(_ count: Int) -> [Double] {
                (0..<count).map { i in
                    state = state &* 1_664_525 &+ 1_013_904_223
                    return Double(state) / Double(UInt32.max) - 0.5 + 0.25
                        * sin(2 * .pi * Double(i % 31) / 31)
                }
            }
            pcm = excitation(Int(item.source.sampleCount))
            window = excitation(profile.windowSamples)
            func polynomial(close: Bool) -> [Double] {
                var a = [1.0]
                for j in 0..<profile.maximumFormants {
                    var frequency =
                        (Double(j) + 0.6) * Double(profile.ceilingHz)
                        / Double(profile.maximumFormants)
                    if close && j == 1 {
                        frequency =
                            0.6 * Double(profile.ceilingHz) / Double(profile.maximumFormants) + 12
                    }
                    let radius = exp(
                        -Double.pi * (close ? 35 : 120) / Double(profile.analysisSampleRate))
                    let section = [
                        1.0, -2 * radius * cos(.pi * frequency / Double(profile.ceilingHz)),
                        radius * radius,
                    ]
                    var next = Array(repeating: 0.0, count: a.count + 2)
                    for i in a.indices {
                        for k in section.indices { next[i + k] += a[i] * section[k] }
                    }
                    a = next
                }
                return a
            }
            normalPolynomial = polynomial(close: false)
            closePolynomial = polynomial(close: true)
            pcm.withUnsafeBufferPointer { resampler.loadInput($0) }
        }
        public func prepare(_ op: FormantOperation) {
            sum = 0
            count = 0
            succeeded = false
        }
        public func run(_ op: FormantOperation) throws {
            switch op {
            case .resample:
                try resampler.resample()
                sum = resampler.output(at: analyzer.layout.outputSampleCount / 2)
                count = 1
                succeeded = true
            case .burg:
                sum = try window.withUnsafeBufferPointer { try stages.predictionGain($0) }
                count = 1
                succeeded = sum >= 0
            case .roots, .closeRoots, .boundedExit:
                let result = stages.solve(
                    op == .roots ? normalPolynomial : closePolynomial,
                    exerciseLimit: op == .boundedExit)
                sum = Double(result.sweeps)
                count = 1
                succeeded =
                    op == .boundedExit
                    ? !result.converged && result.secondStart && result.sweeps == 2
                    : result.converged && (result.residual ?? .infinity) <= 1e-10
            case .analyze:
                try pcm.withUnsafeBufferPointer { input in
                    try analyzer.analyze(input, source: item.source) { frame in
                        if frame.failure == nil, let gain = frame.diagnostics.predictionGainDB {
                            count += 1
                            sum += gain
                        }
                    }
                }
                succeeded = count == item.expectedFrames
            }
        }
        public func verify() {
            precondition(
                count > 0 && sum.isFinite && succeeded,
                "The measured formant stage did not consume its declared work")
        }
    }
#endif
