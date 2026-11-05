import Foundation

/// Absolute digital RMS eligibility, independent of speech activity or periodicity.
/// Disjoint rectangular windows use unit-peak PCM dBFS, with no de-meaning/filtering.
/// Consecutive-window confirmation and on/off thresholds define the state exactly.
public struct EnergyEligibilityConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let declaredInputBandwidthHz: Double
    public let windowSamples: Int
    public let activationDBFS: Double
    public let deactivationDBFS: Double
    public let activationConfirmationWindows: Int
    public let deactivationConfirmationWindows: Int
    public var effectiveDelaySeconds: Double { Double(windowSamples) / Double(sampleRate) }

    public init(
        sampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        declaredInputBandwidthHz: Double, windowSamples: Int,
        activationDBFS: Double = -40, deactivationDBFS: Double = -45,
        activationConfirmationWindows: Int = 2, deactivationConfirmationWindows: Int = 3
    ) throws {
        guard (1...192_000).contains(sampleRate), (1...sampleRate).contains(windowSamples),
            declaredInputBandwidthHz.isFinite, declaredInputBandwidthHz > 0,
            declaredInputBandwidthHz <= Double(sampleRate) / 2,
            activationDBFS.isFinite, (-6000...6000).contains(activationDBFS),
            deactivationDBFS.isFinite, (-6000...activationDBFS).contains(deactivationDBFS),
            (1...1000).contains(activationConfirmationWindows),
            (1...1000).contains(deactivationConfirmationWindows)
        else { throw MaskError.invalidConfiguration }
        schemaVersion = 1
        self.sampleRate = sampleRate
        self.inputPrecision = inputPrecision
        self.declaredInputBandwidthHz = declaredInputBandwidthHz
        self.windowSamples = windowSamples
        self.activationDBFS = activationDBFS == 0 ? 0 : activationDBFS
        self.deactivationDBFS = deactivationDBFS == 0 ? 0 : deactivationDBFS
        self.activationConfirmationWindows = activationConfirmationWindows
        self.deactivationConfirmationWindows = deactivationConfirmationWindows
    }

    public func provenance() throws -> MaskProvenance {
        try MaskProvenance(
            kind: .energyEligibility,
            identifier: VersionedIdentifier(
                name: "absolute-rms-eligibility-confirmed-windows", version: 1),
            parameters: [
                "sampleRateHz": .integer(Int64(sampleRate)),
                "inputPrecision": .text(inputPrecision.rawValue),
                "analysisPrecision": .text("float64-scaled-energy"),
                "declaredInputBandwidthHz": .real(declaredInputBandwidthHz),
                "windowSamples": .integer(Int64(windowSamples)),
                "hopSamples": .integer(Int64(windowSamples)),
                "window": .text("rectangular-no-demeaning-no-filtering"),
                "activationDBFS": .real(activationDBFS),
                "deactivationDBFS": .real(deactivationDBFS),
                "activationComparison": .text("greater-than-or-equal"),
                "deactivationComparison": .text("strictly-less-than"),
                "activationConfirmationWindows": .integer(Int64(activationConfirmationWindows)),
                "deactivationConfirmationWindows": .integer(Int64(deactivationConfirmationWindows)),
                "initialState": .text("ineligible"),
                "transition": .text("confirming-window-no-retroactive-relabeling"),
                "effectiveDelaySeconds": .real(effectiveDelaySeconds),
                "partialWindow": .text("unavailable-without-state-transition"),
            ])
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sampleRate, inputPrecision, declaredInputBandwidthHz, windowSamples
        case activationDBFS, deactivationDBFS, activationConfirmationWindows,
            deactivationConfirmationWindows
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            declaredInputBandwidthHz: c.decode(Double.self, forKey: .declaredInputBandwidthHz),
            windowSamples: c.decode(Int.self, forKey: .windowSamples),
            activationDBFS: c.decode(Double.self, forKey: .activationDBFS),
            deactivationDBFS: c.decode(Double.self, forKey: .deactivationDBFS),
            activationConfirmationWindows: c.decode(
                Int.self, forKey: .activationConfirmationWindows),
            deactivationConfirmationWindows: c.decode(
                Int.self, forKey: .deactivationConfirmationWindows))
    }
}

/// A nil decision means insufficient support, not false/zero energy.
public struct EnergyEligibilityFrame: Sendable, Hashable, Encodable {
    public let source: SourceInterval
    public let profile: ProfileIdentity
    public let level: DigitalLevel
    public let isEligible: Bool?
    public let changedState: Bool
    public let pendingConfirmationWindows: Int
    public let effectiveDelaySeconds: Double

    /// Explicit owned metadata export, outside the prepared processing budget.
    public func observation(provenanceIndex: Int) throws -> MaskObservation {
        guard let isEligible else {
            return try MaskObservation(
                source: source, provenanceIndex: provenanceIndex, tags: [.algorithmInsufficiency])
        }
        return try MaskObservation(
            source: source, provenanceIndex: provenanceIndex,
            selection: isEligible ? .selected : .rejected,
            tags: isEligible ? [.energyEligible] : [.energyIneligible])
    }
}

public struct EnergyEligibilityCompletion: Sendable, Hashable {
    public let source: SourceInterval
    public let completeWindowCount: UInt64
    public let unavailableTailSamples: Int
    public let isCancelled: Bool
}

/// Single-owner causal worker with constant-size state and no retained PCM.
/// Activation/deactivation occurs on the confirming window; earlier labels remain
/// unchanged. At least deactivationConfirmationWindows selected windows follow
/// activation, and the inverse holds after deactivation. The initial prefix and
/// final truncated region are not silently extended to meet a minimum duration.
public final class PreparedEnergyEligibility<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: EnergyEligibilityConfiguration
    public let provenance: MaskProvenance
    public let identity: ProfileIdentity
    public private(set) var epoch: StreamEpoch
    public private(set) var nextInputSample: Int64
    public private(set) var isEligible = false
    public private(set) var pendingConfirmationWindows = 0
    private var origin: Int64
    private var energy = LevelScaledSum()
    private var windowCount = 0
    private var completeWindows: UInt64 = 0
    private var completion: EnergyEligibilityCompletion?
    private enum State { case prepared, finished, cancelled }
    private var state = State.prepared
    private var busy = false
    private let diagnostics: WorkerDiagnostics
    private var diagnosticSequence: UInt64 = 0
    public var isCancelled: Bool { state == .cancelled }

    public convenience init(
        configuration: EnergyEligibilityConfiguration, epoch: StreamEpoch, startSample: Int64 = 0
    ) throws {
        try self.init(
            configuration: configuration, epoch: epoch, startSample: startSample,
            diagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: EnergyEligibilityConfiguration, epoch: StreamEpoch,
        startSample: Int64 = 0, diagnostics: WorkerDiagnostics
    ) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else { throw MaskError.invalidConfiguration }
        _ = try SourceInterval(
            epoch: epoch, startSample: startSample, sampleCount: 0,
            sampleRate: Double(configuration.sampleRate))
        self.configuration = configuration
        self.diagnostics = diagnostics
        provenance = try configuration.provenance()
        identity = try provenance.identity()
        self.epoch = epoch
        origin = startSample
        nextInputSample = startSample
    }

    @discardableResult
    public func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (EnergyEligibilityFrame) -> Void
    ) throws -> MaskProcessReport {
        guard !busy else { throw MaskError.reentrantCall }
        guard state == .prepared else { throw MaskError.invalidState }
        guard interval.epoch == epoch, interval.sampleRate == Double(configuration.sampleRate),
            interval.startSample == nextInputSample, interval.sampleCount == Int64(samples.count)
        else { throw MaskError.unexpectedInterval }
        for sample in samples where !sample.isFinite { throw MaskError.nonfiniteInput }
        busy = true
        defer { busy = false }
        var consumed = 0
        var emittedSamples = 0
        var emittedWindows = 0
        while consumed < samples.count && state == .prepared {
            let count = min(samples.count - consumed, configuration.windowSamples - windowCount)
            var metadata = DiagnosticMetadata()
            metadata.profileToken = 3401
            metadata.frameSequence = diagnosticSequence
            metadata.sampleCount = UInt32(count)
            diagnosticSequence = saturatingAdd(diagnosticSequence)
            let output: EnergyEligibilityFrame? = try diagnostics.withFrame(metadata) {
                try diagnostics.withInterval(.energyEligibility) {
                    for index in consumed..<(consumed + count) {
                        energy.append(Double(samples[index]))
                    }
                    consumed += count
                    windowCount += count
                    nextInputSample += Int64(count)
                    if windowCount == configuration.windowSamples {
                        let level = try energy.energy(sampleCount: windowCount).digitalLevel
                        let decibels = level.mathematicalDecibels!
                        let candidate =
                            isEligible
                            ? decibels < configuration.deactivationDBFS
                            : decibels >= configuration.activationDBFS
                        pendingConfirmationWindows = candidate ? pendingConfirmationWindows + 1 : 0
                        let confirmation =
                            isEligible
                            ? configuration.deactivationConfirmationWindows
                            : configuration.activationConfirmationWindows
                        let changed = pendingConfirmationWindows == confirmation
                        if changed {
                            isEligible.toggle()
                            pendingConfirmationWindows = 0
                        }
                        let source = try SourceInterval(
                            epoch: epoch, startSample: nextInputSample - Int64(windowCount),
                            sampleCount: Int64(windowCount),
                            sampleRate: Double(configuration.sampleRate))
                        let frame = EnergyEligibilityFrame(
                            source: source, profile: identity, level: level, isEligible: isEligible,
                            changedState: changed,
                            pendingConfirmationWindows: pendingConfirmationWindows,
                            effectiveDelaySeconds: configuration.effectiveDelaySeconds)
                        emittedSamples += windowCount
                        emittedWindows += 1
                        completeWindows += 1
                        energy = LevelScaledSum()
                        windowCount = 0
                        return frame
                    }
                    return nil
                }
            }
            if let output { emit(output) }
        }
        return MaskProcessReport(
            consumedSampleCount: consumed, emittedSampleCount: emittedSamples,
            emittedChunkCount: emittedWindows, isCancelled: isCancelled)
    }

    @discardableResult
    public func finish(emit: (EnergyEligibilityFrame) -> Void) throws -> EnergyEligibilityCompletion
    {
        guard !busy else { throw MaskError.reentrantCall }
        guard state != .cancelled else { throw MaskError.invalidState }
        if let completion { return completion }
        busy = true
        defer { busy = false }
        let source = try SourceInterval(
            epoch: epoch, startSample: origin,
            sampleCount: nextInputSample - origin, sampleRate: Double(configuration.sampleRate))
        let tail = windowCount
        state = .finished
        if tail > 0 {
            let partial = try SourceInterval(
                epoch: epoch, startSample: nextInputSample - Int64(tail),
                sampleCount: Int64(tail), sampleRate: Double(configuration.sampleRate))
            windowCount = 0
            energy = LevelScaledSum()
            emit(
                EnergyEligibilityFrame(
                    source: partial, profile: identity,
                    level: .unavailable(.insufficientData), isEligible: nil, changedState: false,
                    pendingConfirmationWindows: pendingConfirmationWindows,
                    effectiveDelaySeconds: configuration.effectiveDelaySeconds))
        }
        let report = EnergyEligibilityCompletion(
            source: source, completeWindowCount: completeWindows,
            unavailableTailSamples: tail, isCancelled: isCancelled)
        completion = report
        return report
    }

    public func reset(for discontinuity: SourceDiscontinuity) throws {
        guard !busy else { throw MaskError.reentrantCall }
        guard discontinuity.previousEpoch == epoch else { throw MaskError.unexpectedInterval }
        if let missing = discontinuity.missingSource {
            guard missing.sampleRate == Double(configuration.sampleRate),
                missing.startSample == nextInputSample
            else {
                throw MaskError.unexpectedInterval
            }
        }
        epoch = discontinuity.nextEpoch
        origin = 0
        nextInputSample = 0
        isEligible = false
        pendingConfirmationWindows = 0
        energy = LevelScaledSum()
        windowCount = 0
        completeWindows = 0
        completion = nil
        state = .prepared
        diagnosticSequence = 0
        diagnostics.reset()
    }

    public func cancel() {
        guard state != .cancelled else { return }
        state = .cancelled
        energy = LevelScaledSum()
        windowCount = 0
        pendingConfirmationWindows = 0
        completion = nil
        diagnostics.event(.cancelled, validity: .cancelled)
    }
}
