import HDXLVoiceProcessing

/// Counts arbitrary text before retaining it; fixed-size fields are bounded by
/// record counts. Profile documents additionally check their canonical byte count.
struct VisualizationMetadataBudget {
    private var remaining: Int

    init(_ limits: VisualizationLimits) { remaining = limits.maximumMetadataBytes }

    mutating func charge(_ value: String) throws {
        let count = value.utf8.count
        guard count <= remaining else { throw VisualizationError.capacityExceeded }
        remaining -= count
    }

    mutating func charge(_ value: VersionedIdentifier) throws { try charge(value.name) }

    mutating func charge(_ value: ProfileIdentity) throws {
        try charge(value.identifier)
        try charge(value.sha256)
    }

    mutating func charge(_ values: [String: ProfileSetting]) throws {
        for (key, value) in values {
            try charge(key)
            if case .text(let text) = value { try charge(text) }
        }
    }

    mutating func charge(_ value: MaskProvenance) throws {
        try charge(value.identifier)
        try charge(value.parameters)
        if let name = value.modelName { try charge(name) }
        if let version = value.modelVersion { try charge(version) }
    }

    mutating func charge(_ value: MeasurementResult) throws {
        try charge(value.profile)
        try charge(value.measurement.algorithm)
        for frame in value.intermediates { try charge(frame.stage) }
    }

    mutating func charge(_ value: AnalysisMaskProvenance) throws {
        try charge(value.planIdentity)
        for source in value.sources { try charge(source) }
    }
}
