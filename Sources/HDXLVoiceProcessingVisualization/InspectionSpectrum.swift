import Foundation
import HDXLVoiceProcessing

extension AlgorithmInspection {
    public static func spectrum(
        _ frame: SpectrogramFrame, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        let layout = frame.layout
        guard frame.binPower.count <= limits.maximumFrameScalars else {
            throw VisualizationError.capacityExceeded
        }
        var curves: [InspectionCurve] = []
        if !frame.binPower.isEmpty {
            let data = try IntermediateSnapshot(
                stage: .init(name: "spectrum-bin-power", version: 1),
                source: frame.info.source, xUnit: .hertz, yUnit: layout.powerUnit,
                xOrigin: layout.frequency.origin, xStep: layout.frequency.step,
                values: frame.binPower)
            curves.append(
                .init(
                    data,
                    explanation:
                        "Each bin contains the power assigned to that frequency by this window and transform."
                ))
        }
        let state: String
        switch frame.info.status {
        case .measured: state = "Measured"
        case .noEnergy: state = "No energy in window"
        case .unavailable(let reason): state = status(reason)
        }
        var fields: [InspectionField] = [
            .init("Frequency spacing", "\(layout.frequency.step) Hz"),
            .init("Equivalent noise bandwidth", "\(layout.equivalentNoiseBandwidthHz) Hz"),
        ]
        if let selection = frame.info.selectionProfile {
            fields.append(.init("Selection profile", selection.sha256))
        }
        return try Self(
            title: "Frequency spectrum",
            explanation:
                "The windowed Fourier transform separates the selected samples into frequency bins. Inspect the linear power used by downstream spectral measures.",
            reference: URL(string: "https://praat.org/manual/Sound__To_Spectrum___.html")!,
            context: context,
            window: frame.info.source, dependency: frame.info.source, profile: layout.profile,
            parameters: parameters(layout), status: state, fields: fields, curves: curves,
            limits: limits)
    }

    public static func spectralShape(
        _ r: SpectralShapeResult, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        let results = try SpectralShapeDescriptor.allCases.compactMap { try r.measurement($0) }
        let config = r.configuration
        var fields: [InspectionField] = [
            .init("Power-spectrum profile", r.layout.profile.sha256),
            .init(
                "Analysis band", "\(config.analysisBand.lowerHz)…\(config.analysisBand.upperHz) Hz"),
            .init("Weighting", config.weighting.rawValue),
        ]
        func energy(_ name: String, _ outcome: MeasurementOutcome, unit: MeasurementUnit) {
            let value =
                outcome.estimate.map { "\($0.value) \(VisualizationUnitLabel.native(unit).symbol)" }
                ?? availability(outcome)
            fields.append(.init(name, value))
        }
        if let energies = r.bandEnergies {
            energy("Numerator band energy", energies.numerator, unit: energies.unit)
            energy("Denominator band energy", energies.denominator, unit: energies.unit)
        }
        if let fit = r.fit {
            fields.append(
                .init(
                    "Regression bins",
                    "\(fit.usedBins) of \(fit.candidateBins) · \(fit.flooredBins) floored"))
            if let low = fit.firstFrequencyHz, let high = fit.lastFrequencyHz {
                fields.append(.init("Fit support", "\(low)…\(high) Hz"))
            }
            if let residual = fit.residualRMSDB {
                fields.append(.init("Fit RMS residual", "\(residual) dB"))
            }
        }
        return try Self(
            title: "Spectral measures and bands",
            explanation:
                "The configured frequency bands, weights and floor determine the moments, band energy ratio, roll-off and fitted slope. Each requested descriptor retains its own outcome.",
            reference: URL(
                string: "https://praat.org/manual/Spectrum__Get_centre_of_gravity___.html")!,
            context: context,
            window: r.timing.source, dependency: r.timing.source, profile: r.profile,
            parameters: parameters(config),
            status:
                "\(results.filter { $0.outcome.estimate != nil }.count) of \(results.count) requested measures available",
            measurements: results, fields: fields, limits: limits)
    }

    public static func formants(
        _ r: BurgFormantFrame, context: InspectionContext, limits: VisualizationLimits = .standard
    ) throws -> Self {
        guard r.candidates.count <= limits.maximumSegments else {
            throw VisualizationError.capacityExceeded
        }
        var fields: [InspectionField] = [.init("LPC order", String(r.configuration.order))]
        if let gain = r.diagnostics.predictionGainDB {
            fields.append(.init("Prediction gain", "\(gain) dB"))
        }
        for (index, pole) in r.candidates.enumerated() {
            var values = ["Radius \(pole.radius)"]
            if let hz = pole.frequencyHz { values.append("\(hz) Hz") }
            if let bw = pole.bandwidthHz { values.append("bandwidth \(bw) Hz") }
            values += pole.rejections.map(\.rawValue)
            let rank = pole.number.map { "F\($0)" } ?? "unranked"
            fields.append(
                .init(
                    "Pole \(index) · \(rank) · " + (pole.isCredible ? "accepted" : "rejected"),
                    values.joined(separator: " · ")))
        }
        for caution in r.cautions { fields.append(.init("Caution", caution.rawValue)) }
        var curves: [InspectionCurve] = []
        if let coefficients = r.diagnostics.coefficients, !coefficients.isEmpty {
            guard coefficients.count <= limits.maximumFrameScalars else {
                throw VisualizationError.capacityExceeded
            }
            let data = try IntermediateSnapshot(
                stage: .init(name: "burg-lpc-coefficients", version: 1),
                source: r.timing.source, xUnit: .dimensionless, yUnit: .dimensionless, xOrigin: 0,
                xStep: 1, values: coefficients)
            curves.append(
                .init(
                    data,
                    explanation: "Burg prediction coefficients in the order returned by this fit."))
        }
        let measurements = try (1...r.configuration.maximumFormants).map {
            try r.measurement(number: $0, kind: .formantFrequency).result
        }
        return try Self(
            title: "Burg LPC and formants",
            explanation:
                "Fit a linear predictor to the conditioned waveform. Complex poles supply candidate frequencies and bandwidths. Only credible poles receive a formant number.",
            reference: URL(string: "https://praat.org/manual/Sound__To_Formant__burg____.html")!,
            context: context,
            window: r.timing.source, dependency: r.conditioningSupport, profile: r.profile,
            parameters: parameters(r.configuration), status: r.failure?.rawValue ?? "Fit completed",
            measurements: measurements, fields: fields, curves: curves, limits: limits)
    }

    public static func harmonics(
        _ r: RawHarmonicFrame, context: InspectionContext, limits: VisualizationLimits = .standard
    ) throws -> Self {
        var fields: [InspectionField] = []
        for (name, amplitude) in [("H1", r.first), ("H2", r.second)] {
            if let amplitude {
                fields.append(
                    .init(
                        name,
                        "\(amplitude.frequencyHz) Hz · \(amplitude.peakFS) FS peak · \(amplitude.peakDBFS) dBFS"
                    ))
            }
        }
        if let pitch = r.pitch { fields.append(.init("Pitch profile", pitch.profile.sha256)) }
        if let residual = r.relativeResidualRMS {
            fields.append(.init("Relative residual RMS", String(residual)))
        }
        return try Self(
            title: "Raw H1–H2",
            explanation:
                "Fit the first two harmonics using the supplied pitch. Subtract their fitted peak levels in decibels to obtain H1–H2.",
            reference: URL(
                string: "https://www.phonetics.ucla.edu/voicesauce/documentation/parameters.html")!,
            context: context, window: r.measurement.timing.source, dependency: r.dependencySupport,
            profile: r.measurement.profile, parameters: parameters(r.configuration),
            status: r.failure?.rawValue ?? availability(r.measurement.outcome),
            measurements: [r.measurement], fields: fields, limits: limits)
    }

    public static func correctedHarmonics(
        _ r: CorrectedHarmonicFrame, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        guard r.contributions.count <= limits.maximumSegments else {
            throw VisualizationError.capacityExceeded
        }
        var fields = r.contributions.map { c in
            InspectionField(
                "F\(c.number) · \(c.frequencyHz) Hz · bandwidth \(c.bandwidthHz) Hz",
                "H1 gain \(c.firstGainDB) dB · H2 gain \(c.secondGainDB) dB"
                    + (c.nearResonance ? " · near resonance" : ""))
        }
        if let f = r.formantProfile { fields.append(.init("Formant profile", f.sha256)) }
        if let level = r.correctedFirstDBFS {
            fields.append(.init("Corrected H1", "\(level) dBFS"))
        }
        if let level = r.correctedSecondDBFS {
            fields.append(.init("Corrected H2", "\(level) dBFS"))
        }
        if let pole = r.unusableFormant {
            fields.append(
                .init("Unusable formant", pole.rejections.map(\.rawValue).joined(separator: ", ")))
        }
        return try Self(
            title: "Formant-corrected H1–H2",
            explanation:
                "Use credible formant frequencies and bandwidths to estimate each resonance’s gain at H1 and H2. Compare the corrected difference with the original estimate.",
            reference: URL(string: "https://www.ee.ucla.edu/~spapl/paper/Iseli_JASA_07.pdf")!,
            context: context, window: r.raw.measurement.timing.source,
            dependency: r.dependencySupport,
            profile: r.measurement.profile, parameters: parameters(r.configuration),
            status: r.failure?.rawValue ?? availability(r.measurement.outcome),
            measurements: [r.raw.measurement, r.measurement], fields: fields, limits: limits)
    }
}
