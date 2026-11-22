import Foundation

/// A single worker's prepared descriptor kernels. Feed live PCM through a PreparedSpectrogram
/// and evaluate its borrowed columns synchronously, or replay owned columns with the same layout.
public final class PreparedSpectralShape {
    public let layout: SpectrogramLayout
    public let configuration: SpectralShapeProfile
    /// Profile for an unmasked source. A selected result binds its upstream selection as well.
    public let identity: ProfileIdentity
    let grid: SpectralShapeGrid
    let analysisBins: Range<Int>?
    let fitBins: Range<Int>?
    let numeratorCells: SpectralBandCells?
    let denominatorCells: SpectralBandCells?
    private let diagnostics: WorkerDiagnostics
    private let descriptors: [SpectralShapeDescriptor: MeasurementDescriptor]
    private var widened: [Double]
    let regression: SpectralShapeRegression

    private var lastSelection: (selection: ProfileIdentity, identity: ProfileIdentity)?
    private var nextAggregateSequence: UInt64 = 0

    public convenience init(
        layout: SpectrogramLayout, configuration: SpectralShapeProfile,
        diagnosticMode: RuntimeDiagnosticMode = .disabled
    ) throws {
        try self.init(
            layout: layout, configuration: configuration,
            diagnostics: WorkerDiagnostics(mode: diagnosticMode.facadeMode))
    }

    init(
        layout: SpectrogramLayout, configuration: SpectralShapeProfile,
        diagnostics: WorkerDiagnostics
    ) throws {
        self.layout = layout
        self.configuration = configuration
        let identity = try configuration.identity(for: layout)
        self.identity = identity
        let grid = SpectralShapeGrid(layout: layout, includeDC: configuration.includeDC)
        self.grid = grid
        analysisBins = grid.centers(in: configuration.analysisBand)
        let fit = grid.centers(in: configuration.fitBand).map { range in
            configuration.fitCoordinate == .octavesFromOneHertz && range.first == 0
                ? 1..<range.upperBound : range
        }
        fitBins = fit
        regression = SpectralShapeRegression(
            range: fit ?? 0..<0, configuration: configuration, step: grid.step)
        numeratorCells = grid.cells(in: configuration.bandRatio.numerator)
        denominatorCells = grid.cells(in: configuration.bandRatio.denominator)
        descriptors = try Dictionary(
            uniqueKeysWithValues: SpectralShapeDescriptor.allCases.map {
                (
                    $0,
                    try MeasurementDescriptor(
                        kind: $0.kind, unit: $0.unit(for: configuration.fitCoordinate),
                        algorithm: identity.identifier)
                )
            })
        widened =
            layout.framing.window.precision == .float32 && configuration.source == .frame
            ? Array(repeating: 0, count: grid.count) : []
        self.diagnostics = diagnostics
    }

    private func sourceIdentity(_ selection: ProfileIdentity?) throws -> ProfileIdentity {
        guard let selection else { return identity }
        if let lastSelection, lastSelection.selection == selection { return lastSelection.identity }
        let bound = try configuration.identity(for: layout, selectionProfile: selection)
        lastSelection = (selection, bound)
        return bound
    }

    public func evaluate(_ row: SpectrogramFrame, only: SpectralShapeDescriptor? = nil) throws
        -> SpectralShapeResult
    {
        try row.withBorrowedFrame { try evaluate($0, only: only) }
    }

    public func evaluate<Sample>(
        _ row: BorrowedSpectrogramFrame<Sample>, only: SpectralShapeDescriptor? = nil
    ) throws -> SpectralShapeResult {
        guard configuration.source == .frame else { throw ContractError.invalidConfiguration }
        guard layout == row.layout else { throw ContractError.invalidFingerprint }
        let timing = try AnalysisTiming(
            source: row.info.source,
            includedSampleCount: row.info.status.isMeasured ? row.info.source.sampleCount : 0)
        let result = SpectralShapeResult(
            configuration: configuration, profile: try sourceIdentity(row.info.selectionProfile),
            layout: layout,
            origin: .frame(row.info), timing: timing, aggregateSupport: nil, selectionCoverage: nil,
            warnings: [])
        return row.binPower.withSpectralScalars(
            doubles: {
                compute(
                    $0, result: result, status: row.info.status, sequence: row.info.frameIndex,
                    only: only)
            },
            floats: { values in
                // Empty unavailable frames still carry their source timing and exclusion reason.
                for i in values.indices { widened[i] = Double(values[i]) }
                return widened.withUnsafeBufferPointer {
                    compute(
                        $0, result: result, status: row.info.status, sequence: row.info.frameIndex,
                        only: only)
                }
            })
    }

    public func evaluate(_ spectrum: LongTermSpectrum, only: SpectralShapeDescriptor? = nil) throws
        -> SpectralShapeResult
    {
        guard configuration.source == .longTermSpectrum else {
            throw ContractError.invalidConfiguration
        }
        guard layout == spectrum.layout else { throw ContractError.invalidFingerprint }
        let result = SpectralShapeResult(
            configuration: configuration, profile: try sourceIdentity(spectrum.selectionProfile),
            layout: layout,
            origin: .longTerm(
                timing: spectrum.timing, selection: spectrum.selectionProfile,
                status: spectrum.status, totalWeight: spectrum.totalWeight),
            timing: spectrum.timing,
            aggregateSupport: .init(
                measuredFrames: spectrum.measuredFrames,
                unavailableFrames: spectrum.unavailableFrames),
            selectionCoverage: spectrum.selectionCoverage,
            warnings: spectrum.warnings)
        let sequence = nextAggregateSequence
        nextAggregateSequence = saturatingAdd(nextAggregateSequence)
        return spectrum.meanBinPower.withUnsafeBufferPointer {
            compute(
                $0, result: result, status: spectrum.status, sequence: sequence,
                only: only)
        }
    }

    private func compute(
        _ powers: UnsafeBufferPointer<Double>, result initial: SpectralShapeResult,
        status: SpectralFrameStatus, sequence: UInt64, only: SpectralShapeDescriptor?
    ) -> SpectralShapeResult {
        var metadata = DiagnosticMetadata()
        metadata.frameSequence = sequence
        metadata.elapsedProcessingCount = initial.aggregateSupport?.measuredFrames ?? 0
        metadata.profileToken = 4501
        metadata.sampleCount = UInt32(clamping: initial.timing.source.sampleCount)
        return diagnostics.withFrame(metadata, stage: .spectralShape) {
            var result = initial
            func wants(_ descriptor: SpectralShapeDescriptor) -> Bool {
                only == nil || only == descriptor
            }
            func scalar(_ descriptor: SpectralShapeDescriptor, _ value: MeasurementOutcome)
                -> SpectralShapeScalar
            {
                SpectralShapeScalar(measurement: descriptors[descriptor]!, outcome: value)
            }
            let unavailable: UnavailabilityReason?
            if case .unavailable(let reason) = status {
                unavailable = reason
            } else {
                unavailable = nil
            }
            if wants(.centroid) || wants(.spread) || wants(.flatness) || wants(.rollOff) {
                let moments = shapeMoments(powers, unavailable: unavailable, only: only)
                if wants(.centroid) { result.centroid = scalar(.centroid, moments.centroid) }
                if wants(.spread) { result.spread = scalar(.spread, moments.spread) }
                if wants(.flatness) { result.flatness = scalar(.flatness, moments.flatness) }
                if wants(.rollOff) { result.rollOff = scalar(.rollOff, moments.rollOff) }
            }
            if wants(.bandEnergyRatio) {
                let numerator = spectralBandEnergy(
                    powers, cells: numeratorCells, unavailable: unavailable)
                let denominator = spectralBandEnergy(
                    powers, cells: denominatorCells, unavailable: unavailable)
                result.bandEnergies = SpectralBandEnergies(
                    unit: .normalizedSquaredAmplitude, numerator: numerator.outcome,
                    denominator: denominator.outcome)
                result.bandEnergyRatio = scalar(.bandEnergyRatio, numerator.ratio(to: denominator))
            }
            if wants(.slope) {
                let (slope, fit) = regression.fit(
                    powers, unavailable: unavailable ?? (fitBins == nil ? .unsupportedRange : nil))
                result.fit = fit
                result.slope = scalar(.slope, slope)
            }
            return result
        }
    }
}
