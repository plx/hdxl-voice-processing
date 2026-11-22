import Foundation

/// A reproducible F0 recipe whose scalar places the estimate on its own PCM window.
/// A causal track's growing history is not a placement window. Use its raw estimator output.
public enum HarmonicPitchRecipe: Sendable, Hashable, Codable {
    case yin(YINConfiguration)
    case swipePrime(SWIPEPrimeConfiguration)
    case schedule(AnalysisScheduleProfile)
    /// A caller-defined, frame-local F0 estimator with complete numerical settings.
    case frameLocal(AnalysisProfile)

    private var archiveProfile: SessionArchiveProfile {
        switch self {
        case .yin(let recipe): .yin(recipe)
        case .swipePrime(let recipe): .swipePrime(recipe)
        case .schedule(let recipe): .schedule(recipe)
        case .frameLocal(let recipe): .analysis(recipe)
        }
    }

    func binding(rate: Int, algorithm: VersionedIdentifier?) throws -> (
        ProfileIdentity, VersionedIdentifier
    ) {
        let profile = archiveProfile
        guard profile.sourceSampleRate == Double(rate) else {
            throw ContractError.invalidConfiguration
        }
        let identity = try profile.identity()
        var algorithms: [VersionedIdentifier] = []
        switch self {
        case .schedule(let schedule):
            if let yin = schedule.pitch {
                algorithms.append(try yin.estimator.identity().identifier)
            }
            if let swipe = schedule.swipePrime {
                algorithms.append(try swipe.identity().identifier)
            }
        case .frameLocal(let external):
            guard external.measurement.kind == .fundamentalFrequency,
                external.measurement.unit == .hertz,
                external.measurement.algorithm.name != "yin-estimator-and-optional-tracker"
            else { throw ContractError.invalidConfiguration }
            algorithms = [external.measurement.algorithm]
        case .yin, .swipePrime:
            algorithms = [identity.identifier]
        }
        guard let selected = algorithm ?? (algorithms.count == 1 ? algorithms.first : nil),
            algorithms.contains(selected)
        else { throw ContractError.invalidConfiguration }
        return (identity, selected)
    }

    private enum Kind: String, Codable { case yin, swipePrime, schedule, analysis }
    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, recipe }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .yin: self = .yin(try c.decode(YINConfiguration.self, forKey: .recipe))
        case .swipePrime:
            self = .swipePrime(try c.decode(SWIPEPrimeConfiguration.self, forKey: .recipe))
        case .schedule:
            self = .schedule(try c.decode(AnalysisScheduleProfile.self, forKey: .recipe))
        case .analysis: self = .frameLocal(try c.decode(AnalysisProfile.self, forKey: .recipe))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try archiveProfile.encode(to: encoder)
    }
}
