import HDXLVoiceProcessing

extension AlgorithmInspection {
    /// Project the borrowed intermediates that produced this scheduled frame.
    /// Every public support interval and scalar result uses acquisition coordinates.
    public static func scheduled(
        _ inspection: BorrowedScheduledInspection, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        let frame = inspection.frame
        let native: Self
        let metrics: [ScheduledMetric]
        switch inspection.output {
        case .pitch(let output):
            guard let recipe = inspection.profile.pitch else {
                throw VisualizationError.incompatibleSeries
            }
            native = try pitch(output, recipe: recipe, context: context, limits: limits)
            metrics =
                output.tracked == nil
                ? [.fundamentalFrequency] : [.fundamentalFrequency, .trackedFundamentalFrequency]
        case .cpps(let output):
            guard let recipe = inspection.profile.cpps else {
                throw VisualizationError.incompatibleSeries
            }
            native = try cpps(output, recipe: recipe, context: context, limits: limits)
            metrics = [.cpp, .cpps]
        case .harmonicity(let output):
            guard let recipe = inspection.profile.hnr else {
                throw VisualizationError.incompatibleSeries
            }
            native = try harmonicity(output, recipe: recipe, context: context, limits: limits)
            metrics = [.harmonicToNoiseRatio]
        }
        let origin = frame.origin
        let curves = try native.curves.map {
            InspectionCurve(try $0.samples.mapped(to: origin), explanation: $0.explanation)
        }
        var fields = native.fields
        fields.append(
            .init(
                "Kernel profile",
                "\(native.profile.identifier.name) v\(native.profile.identifier.version) · \(native.profile.sha256)"
            ))
        fields.append(
            .init(
                "Analysis continuity",
                "\(origin.continuityEpoch.streamID.uuidString) · \(origin.continuityEpoch.sequence)"
            ))
        if let mask = frame.mask {
            fields.append(.init("Mask", "\(mask.planIdentity.sha256) · \(mask.scope.rawValue)"))
            fields.append(
                .init(
                    "Dependency coverage",
                    "\(frame.coverage.eligible) eligible · \(frame.coverage.selected) selected · \(frame.coverage.missing) missing samples"
                ))
        }
        return try Self(
            title: native.title, explanation: native.explanation, reference: native.reference,
            context: context,
            window: origin.sourceInterval(for: native.window), dependency: frame.timing.source,
            profile: frame.schedule, parameters: parameters(inspection.profile),
            status: native.status,
            measurements: metrics.map(frame.measurementResult),
            measurementLabels: native.measurementLabels,
            fields: fields, curves: curves, unavailability: native.unavailability, limits: limits)
    }
}
