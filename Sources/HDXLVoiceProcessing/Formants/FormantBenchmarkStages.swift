#if KernelBenchmarkAccess
    /// The benchmark package invokes the same bounded kernels as the analyzer.
    public final class FormantBenchmarkStages {
        private let burg: FormantBurgWorkspace
        public init(profile: BurgFormantProfile) throws {
            let window = try PreparedWindow<Double>(
                WindowSpecification(
                    definition: profile.window,
                    sampleCount: profile.windowSamples,
                    sampleRate: Double(profile.analysisSampleRate)))
            burg = FormantBurgWorkspace(weights: window.coefficientSnapshot(), order: profile.order)
        }
        public func predictionGain(_ samples: UnsafeBufferPointer<Double>) throws -> Double {
            try burg.fit(samples).get().predictionGainDB
        }
        public func solve(_ coefficients: [Double], exerciseLimit: Bool = false) -> (
            converged: Bool, sweeps: Int, secondStart: Bool, residual: Double?
        ) {
            let result = FormantPolynomial(coefficients: coefficients).solve(
                sweepLimit: exerciseLimit ? 1 : FormantPolynomial.sweepLimit)
            return (
                result.converged, result.sweeps, result.triedSecondStart,
                result.maximumRelativeResidual
            )
        }
    }
#endif
