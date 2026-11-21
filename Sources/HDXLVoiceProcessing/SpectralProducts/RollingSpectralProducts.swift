import Foundation

public enum SpectralProductColumn: Sendable, Hashable, Encodable {
    case spectrum(SpectrogramFrame)
    case powerCepstrum(PowerCepstrumFrame)

    public var frameIndex: UInt64 {
        switch self {
        case .spectrum(let row): row.info.frameIndex
        case .powerCepstrum(let row): row.context.frameIndex
        }
    }
    public var source: SourceInterval {
        switch self {
        case .spectrum(let row): row.info.source
        case .powerCepstrum(let row): row.context.timing.source
        }
    }
    public var powers: [Double] {
        switch self {
        case .spectrum(let row): row.binPower
        case .powerCepstrum(let row): row.values
        }
    }
    public var unavailability: UnavailabilityReason? {
        switch self {
        case .spectrum(let row):
            if case .unavailable(let reason) = row.info.status { return reason }
            return nil
        case .powerCepstrum(let row): return row.unavailability
        }
    }

    var originSample: Int64 {
        switch self {
        case .spectrum(let row): row.info.epochStartSample
        case .powerCepstrum(let row): row.context.origin.startSample
        }
    }
    var centerSecondsFromOrigin: Double {
        switch self {
        case .spectrum(let row):
            (Double(row.info.source.startSample - row.info.epochStartSample) + Double(
                row.layout.framing.window.sampleCount) / 2) / row.info.source.sampleRate
        case .powerCepstrum(let row): row.context.centerSecondsFromOrigin
        }
    }
    var selectionProfile: ProfileIdentity? {
        if case .spectrum(let row) = self { return row.info.selectionProfile }
        return nil
    }

    func canFollow(_ previous: Self) -> Bool {
        guard frameIndex > previous.frameIndex else { return false }
        switch (previous, self) {
        case (.spectrum(let a), .spectrum(let b)):
            return b.info.source.endSample >= a.info.source.endSample
                && a.info.status != .unavailable(.insufficientData)
                && a.info.epochStartSample == b.info.epochStartSample
                && a.info.source.epoch == b.info.source.epoch
                && a.info.selectionProfile == b.info.selectionProfile
        case (.powerCepstrum(let a), .powerCepstrum(let b)):
            return a.context.origin == b.context.origin
                && a.context.centerSecondsFromOrigin < b.context.centerSecondsFromOrigin
        default: return false
        }
    }
}

public enum SpectralDisplayAggregation: String, Sendable, Codable { case maximum, arithmeticMean }

/// A time-reduced display column. Every bin uses the same complete input columns.
public struct SpectralDisplayColumn: Sendable, Hashable, Encodable {
    public let originSample: Int64
    public let firstCenterSecondsFromOrigin: Double
    public let lastCenterSecondsFromOrigin: Double
    public let selectionProfile: ProfileIdentity?
    public let profile: ProfileIdentity
    public let firstFrameIndex: UInt64
    public let lastFrameIndex: UInt64
    public let sourceEnvelope: SourceInterval
    public let availableFrameCount: Int
    public let unavailableFrames: [UnavailabilityReason: Int]
    public let aggregation: SpectralDisplayAggregation
    public let axis: SpectralProductAxis
    public let powerUnit: MeasurementUnit
    public let linearPower: [Double]
}

public enum SpectralProductConfiguration: Sendable, Hashable, Encodable {
    case spectrogram(SpectrogramLayout)
    case powerCepstrogram(CepstrogramConfiguration)
}

public struct SpectralProductSnapshot: Sendable, Hashable, Encodable {
    public let configuration: SpectralProductConfiguration
    public let profile: ProfileIdentity
    public let axis: SpectralProductAxis
    public let powerUnit: MeasurementUnit
    public let capacity: Int
    public let evictedCount: UInt64
    /// Chronological rows include their individual actual support, including gaps between rows.
    public let columns: [SpectralProductColumn]

    public func displayColumns(framesPerColumn: Int, aggregation: SpectralDisplayAggregation) throws
        -> [SpectralDisplayColumn]
    {
        guard framesPerColumn > 0 else { throw ContractError.invalidConfiguration }
        var result: [SpectralDisplayColumn] = []
        var offset = 0
        while offset < columns.count {
            let end = offset + min(framesPerColumn, columns.count - offset)
            let group = columns[offset..<end]
            let first = columns[offset]
            var startSample = first.source.startSample
            var endSample = first.source.endSample
            var missing: [UnavailabilityReason: Int] = [:]
            var powers: [Double] = []
            var included = 0
            for column in group {
                startSample = min(startSample, column.source.startSample)
                endSample = max(endSample, column.source.endSample)
                if let reason = column.unavailability {
                    missing[reason, default: 0] += 1
                    continue
                }
                included += 1
                let values = column.powers
                if included == 1 {
                    powers = values
                    continue
                }
                for i in powers.indices {
                    switch aggregation {
                    case .maximum: powers[i] = max(powers[i], values[i])
                    case .arithmeticMean: powers[i] += (values[i] - powers[i]) / Double(included)
                    }
                }
            }
            let source = try SourceInterval(
                epoch: first.source.epoch, startSample: startSample,
                sampleCount: endSample - startSample,
                sampleRate: first.source.sampleRate)
            result.append(
                SpectralDisplayColumn(
                    originSample: first.originSample,
                    firstCenterSecondsFromOrigin: first.centerSecondsFromOrigin,
                    lastCenterSecondsFromOrigin: columns[end - 1].centerSecondsFromOrigin,
                    selectionProfile: first.selectionProfile,
                    profile: profile, firstFrameIndex: first.frameIndex,
                    lastFrameIndex: columns[end - 1].frameIndex,
                    sourceEnvelope: source, availableFrameCount: included,
                    unavailableFrames: missing, aggregation: aggregation,
                    axis: axis, powerUnit: powerUnit, linearPower: powers))
            offset = end
        }
        return result
    }
}

/// Evicts the oldest owned column at capacity. Snapshotting copies the chronological list;
/// its immutable rows can outlive the ring. Allocation occurs on the analysis worker.
public final class RollingSpectralProducts {
    public let configuration: SpectralProductConfiguration
    public let capacity: Int
    public let axis: SpectralProductAxis
    public let powerUnit: MeasurementUnit
    public let profile: ProfileIdentity
    public private(set) var count = 0
    public private(set) var evictedCount: UInt64 = 0
    private let cepstrum: PowerCepstrogramExporter?
    private let diagnostics: WorkerDiagnostics
    private var slots: [SpectralProductColumn?]
    private var next = 0

    public convenience init(
        layout: SpectrogramLayout, capacity: Int, diagnosticMode: RuntimeDiagnosticMode = .disabled
    ) throws {
        try self.init(
            configuration: .spectrogram(layout), axis: layout.frequency,
            powerUnit: layout.powerUnit, profile: layout.profile,
            cepstrum: nil, capacity: capacity, diagnosticMode: diagnosticMode)
    }
    public convenience init(
        configuration: CepstrogramConfiguration, capacity: Int,
        diagnosticMode: RuntimeDiagnosticMode = .disabled
    ) throws {
        let exporter = try PowerCepstrogramExporter(configuration: configuration)
        try self.init(
            configuration: .powerCepstrogram(configuration), axis: exporter.quefrency,
            powerUnit: exporter.unit, profile: exporter.profile,
            cepstrum: exporter, capacity: capacity, diagnosticMode: diagnosticMode)
    }
    private init(
        configuration: SpectralProductConfiguration, axis: SpectralProductAxis,
        powerUnit: MeasurementUnit, profile: ProfileIdentity,
        cepstrum: PowerCepstrogramExporter?,
        capacity: Int, diagnosticMode: RuntimeDiagnosticMode
    ) throws {
        guard (1...30_000).contains(capacity), capacity <= 16_777_216 / axis.count else {
            throw ContractError.intermediateBudgetExceeded
        }
        self.configuration = configuration
        self.axis = axis
        self.powerUnit = powerUnit
        self.profile = profile
        self.cepstrum = cepstrum
        self.capacity = capacity
        diagnostics = WorkerDiagnostics(mode: diagnosticMode.facadeMode)
        slots = .init(repeating: nil, count: capacity)
    }

    public func append<Sample>(_ row: BorrowedSpectrogramFrame<Sample>) throws {
        try append(frameIndex: row.info.frameIndex, rowProfile: row.layout.profile) {
            .spectrum(row.owned())
        }
    }
    public func append(_ row: SpectrogramFrame) throws {
        try append(frameIndex: row.info.frameIndex, rowProfile: row.layout.profile) {
            .spectrum(row)
        }
    }
    public func append(_ row: BorrowedPowerCepstrum<Double>) throws {
        guard let cepstrum else { throw ContractError.invalidFingerprint }
        try append(frameIndex: row.context.frameIndex, rowProfile: row.profile) {
            try .powerCepstrum(cepstrum.owned(row))
        }
    }
    public func append(_ row: PowerCepstrumFrame) throws {
        try append(frameIndex: row.context.frameIndex, rowProfile: row.profile) {
            .powerCepstrum(row)
        }
    }

    private func append(
        frameIndex: UInt64, rowProfile: ProfileIdentity, make: () throws -> SpectralProductColumn
    ) throws {
        guard rowProfile == profile else { throw ContractError.invalidFingerprint }
        var metadata = DiagnosticMetadata()
        metadata.frameSequence = frameIndex
        try diagnostics.withFrame(metadata, stage: .spectralRetention) {
            let column = try make()
            if count > 0, let previous = slots[(next + capacity - 1) % capacity],
                !column.canFollow(previous)
            {
                throw FramingError.unexpectedInterval
            }
            slots[next] = column
            next = (next + 1) % capacity
            if count == capacity { evictedCount = saturatingAdd(evictedCount) } else { count += 1 }
        }
    }

    public func snapshot() -> SpectralProductSnapshot {
        var metadata = DiagnosticMetadata()
        metadata.frameSequence =
            count == 0 ? 0 : slots[(next + capacity - 1) % capacity]!.frameIndex
        return diagnostics.withFrame(metadata, stage: .spectralExport) {
            let oldest = count < capacity ? 0 : next
            let columns = (0..<count).map { slots[(oldest + $0) % capacity]! }
            return SpectralProductSnapshot(
                configuration: configuration, profile: profile, axis: axis, powerUnit: powerUnit,
                capacity: capacity, evictedCount: evictedCount, columns: columns)
        }
    }
}
