/// Internal worker diagnostics. These values are not part of the stable public API.
package enum DiagnosticMode: String, CaseIterable, Sendable {
    case disabled, sampled, detailed
}

/// Numeric, non-audio metadata only. Profile tokens are ephemeral control-plane IDs.
package struct DiagnosticMetadata: Equatable, Sendable {
    package var profileToken: UInt64 = 0
    package var frameSequence: UInt64 = .max
    package var sampleCount: UInt32 = 0
    package var queueDepth: UInt32 = 0
    package var validity: DiagnosticValidity = .unspecified
    package var elapsedProcessingCount: UInt64 = 0
    package var queueWaitNanoseconds: UInt64? = nil
    package init() {}
}

package enum DiagnosticValidity: UInt8, Sendable {
    case unspecified, available, warmup, discontinuity, invalidInput, cancelled, failed
}

package enum DiagnosticStage: String, CaseIterable, Sendable {
    case initialize, reset, analysisFrame, captureHandoff, queueWait, dequeue, referenceValidation
    case resample, preEmphasis, frameAssembly, fft, cepstrum, cpp, cppsSmoothing, cppsFitting,
        cppsAggregation
    case pitch, pitchTracking, hnr, pulses, perturbation, resultPublication, levelEnergy, kWeighting
    case hnrNormalization, hnrWindow, hnrCorrelation, hnrPeriodSearch
    case fixtureLoad, fixtureDecode
    case speechActivity, maskIntervals, energyEligibility, maskResolution, maskRouting
    case overrun, drop, routeChange, configurationChange, error, cancelled
    case resultDelivery, rendering, feedbackStateChange

    var category: String {
        switch self {
        case .initialize, .reset, .routeChange, .configurationChange: "lifecycle"
        case .captureHandoff, .queueWait, .dequeue, .overrun, .drop: "flow"
        case .resultDelivery: "delivery"
        case .rendering: "rendering"
        default: "worker"
        }
    }

    // Explicit literals, never a dynamically formatted event name.
    var signpostName: StaticString {
        switch self {
        case .referenceValidation: "ReferenceValidation"
        case .initialize: "Initialize"
        case .reset: "Reset"
        case .analysisFrame: "AnalysisFrame"
        case .captureHandoff: "CaptureHandoff"
        case .queueWait: "QueueWait"
        case .dequeue: "Dequeue"
        case .resample: "Resample"
        case .preEmphasis: "PreEmphasis"
        case .frameAssembly: "FrameAssembly"
        case .fft: "FFT"
        case .cepstrum: "Cepstrum"
        case .cpp: "CPP"
        case .cppsSmoothing: "CPPSSmoothing"
        case .cppsFitting: "CPPSFitting"
        case .cppsAggregation: "CPPSAggregation"
        case .pitch: "Pitch"
        case .pitchTracking: "PitchTracking"
        case .hnr: "HNR"
        case .hnrNormalization: "HNRNormalization"
        case .hnrWindow: "HNRWindow"
        case .hnrCorrelation: "HNRCorrelation"
        case .hnrPeriodSearch: "HNRPeriodSearch"
        case .pulses: "Pulses"
        case .perturbation: "Perturbation"
        case .resultPublication: "ResultPublication"
        case .levelEnergy: "LevelEnergy"
        case .kWeighting: "KWeighting"
        case .fixtureLoad: "FixtureLoad"
        case .fixtureDecode: "FixtureDecode"
        case .speechActivity: "SpeechActivity"
        case .maskIntervals: "MaskIntervals"
        case .energyEligibility: "EnergyEligibility"
        case .maskResolution: "MaskResolution"
        case .maskRouting: "MaskRouting"
        case .overrun: "Overrun"
        case .drop: "Drop"
        case .routeChange: "RouteChange"
        case .configurationChange: "ConfigurationChange"
        case .error: "Error"
        case .cancelled: "Cancelled"
        case .resultDelivery: "ResultDelivery"
        case .rendering: "Rendering"
        case .feedbackStateChange: "FeedbackStateChange"
        }
    }
}

package struct DiagnosticRecord: Equatable, Sendable {
    package let session: UInt64
    package let epoch: UInt64
    package let span: UInt64
    package let stage: DiagnosticStage
    package let metadata: DiagnosticMetadata
}

package struct DiagnosticCounts: Equatable, Sendable {
    package internal(set) var intervals: UInt64 = 0
    package internal(set) var events: UInt64 = 0
    package internal(set) var suppressed: UInt64 = 0
    package internal(set) var unavailable: UInt64 = 0
}

@inline(__always)
func saturatingAdd(_ value: UInt64, _ increment: UInt64 = 1) -> UInt64 {
    let (sum, overflow) = value.addingReportingOverflow(increment)
    return overflow ? .max : sum
}
