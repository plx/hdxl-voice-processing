import HDXLVoiceProcessing

/// A whole-region finish receipt. Counts and means come from the native completion.
public struct SuiteCompletion: Encodable, Equatable, Sendable {
    let sourceOffset: Int64
    let source: SourceInterval
    let eligible, selected: Int64
    let emittedFrames: UInt64
    let framing: [String: Framing]
    let cpps: CepstralMean
    let hnrAvailableFrames, hnrUnavailableFrames: UInt64?

    struct Framing: Encodable, Equatable, Sendable {
        let source: SourceInterval
        let completeFrames: UInt64
        let tail: SourceInterval?
        let disposition: String
        let cancelled: Bool

        init(_ framing: FramingCompletion, cancelled: Bool) {
            source = framing.observedSource
            completeFrames = framing.completeFrameCount
            tail = framing.tailSource
            disposition = framing.disposition.rawValue
            self.cancelled = cancelled
        }

        init(_ levels: LevelCompletion) {
            source = levels.observedSource
            completeFrames = levels.completeWindowCount
            tail = levels.tailSource
            disposition = levels.disposition.rawValue
            cancelled = levels.isCancelled
        }
    }

    struct CepstralMean: Encodable, Equatable, Sendable {
        let source: SourceInterval
        let frames, available: Int
        let meanDB: Double?
        let reason: UnavailabilityReason?
    }

    init(
        _ completion: AnalysisScheduleCompletion, recipe: SuiteRecipe,
        origin: AnalysisScheduleOrigin,
        source: SourceInterval, offset: Int64
    ) throws {
        guard completion.origin == origin, completion.schedule == recipe.scheduleIdentity,
            !completion.isCancelled, completion.observedSource == source, completion.mask == nil,
            completion.coverage.source == source.sampleCount,
            let cepstral = completion.cpps,
            cepstral.profile == (try recipe.schedule.cpps?.identity()),
            completion.hnrInterval == nil,
            (completion.levels != nil) == (recipe.schedule.levels != nil),
            (completion.pitch != nil) == (recipe.schedule.pitch != nil),
            (completion.hnrStream != nil) == (recipe.schedule.hnr != nil),
            (completion.swipePrime != nil) == (recipe.schedule.swipePrime != nil)
        else {
            throw SuiteError.mismatch("Unexpected completion profile, region or finished stages")
        }
        self.source = source
        sourceOffset = offset
        eligible = completion.coverage.eligible
        selected = completion.coverage.selected
        emittedFrames = completion.emittedFrames
        cpps = CepstralMean(
            source: cepstral.source, frames: cepstral.frameCount,
            available: cepstral.availableFrameCount, meanDB: cepstral.meanDB,
            reason: cepstral.unavailability)
        var records: [String: Framing] = [:]
        if let levels = completion.levels { records["levels"] = Framing(levels) }
        if let pitch = completion.pitch {
            records["yin"] = Framing(pitch.framing, cancelled: pitch.isCancelled)
        }
        if let swipe = completion.swipePrime {
            records["swipePrime"] = Framing(swipe.framing, cancelled: swipe.isCancelled)
        }
        if let hnr = completion.hnrStream {
            records["hnr"] = Framing(hnr.framing, cancelled: hnr.isCancelled)
        }
        framing = records
        hnrAvailableFrames = completion.hnrStream?.availableFrameCount
        hnrUnavailableFrames = completion.hnrStream?.unavailableFrameCount
    }
}
