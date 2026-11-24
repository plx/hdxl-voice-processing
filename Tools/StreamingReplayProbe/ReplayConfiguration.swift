import Foundation
import HDXLVoiceProcessing

struct ReplayFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

enum ReplayProfile: String, Codable {
    case cpps, core, full

    func schedule(rate: Int) throws -> AnalysisScheduleProfile {
        let format = try PCMFormat(
            sampleRate: Double(rate), channelCount: 1, encoding: .float32, layout: .interleaved)
        let hop = rate / 100
        return try AnalysisScheduleProfile(
            inputFormat: format, channels: .arithmeticMean,
            levels: self == .cpps
                ? nil
                : LevelConfiguration(
                    sampleRate: rate, inputPrecision: .float32, windowLength: 2 * hop,
                    hopLength: hop,
                    accumulation: .compensatedSliding,
                    weighting: .bs1770Revision5(warmupSampleCount: rate / 10)),
            pitch: self == .cpps
                ? nil
                : YINProfile(
                    estimator: YINConfiguration(
                        sampleRate: rate, inputPrecision: .float32, pitchFloorHz: 50,
                        pitchCeilingHz: 700, hopLength: hop), tracker: YINTrackerConfiguration()),
            cpps: CPPSProfile(
                cepstrogram: CepstrogramConfiguration(
                    sourceSampleRate: rate, inputPrecision: .float32, hopSeconds: 0.01,
                    declaredInputBandwidthHz: Double(rate) / 2,
                    conditioningMethod: .streamingPreview(lobes: 8, cutoffFraction: 0.9)),
                settings: CPPSConfiguration(
                    timeWindowSeconds: 0.02, prominence: CPPConfiguration(fitMethod: .leastSquares))
            ),
            hnr: self == .full
                ? HNRConfiguration(
                    method: .autocorrelation, sampleRate: rate, inputPrecision: .float32,
                    normalization: .causalWindow) : nil,
            swipePrime: self == .full
                ? SWIPEPrimeConfiguration(
                    sampleRate: rate, inputPrecision: .float32, hopLength: hop) : nil)
    }
}

enum ReplayLoad: String, Codable { case throughput, paced, burst }
enum ReplayOperation: String, Codable { case single, restart, concurrent, soak }

struct ReplayOptions {
    let profile: ReplayProfile
    let rate: Int
    let pattern: [Int]
    let load: ReplayLoad
    let mode: RuntimeDiagnosticMode
    let seconds: Int
    let seed: UInt32
    let operation: ReplayOperation
    let slots: Int
    let output: URL

    static let usage =
        "usage: StreamingReplayProbe {cpps|core|full} {44100|48000} {64|128|256|512|1024|mixed} {throughput|paced|burst} {disabled|sampled|detailed} SECONDS SEED {single|restart|concurrent|soak} OUTPUT.json [QUEUE_SLOTS]"

    init(arguments: [String]) throws {
        let mixed = [64, 128, 256, 512, 1024, 93, 711]
        guard [9, 10].contains(arguments.count) else { throw ReplayFailure(Self.usage) }
        let slots = arguments.count == 9 ? 32 : Int(arguments[9])
        guard let slots, (2...512).contains(slots), slots.nonzeroBitCount == 1,
            arguments.count == 9 || arguments[3] == "paced",
            let profile = ReplayProfile(rawValue: arguments[0]),
            let rate = Int(arguments[1]), [44_100, 48_000].contains(rate),
            arguments[2] == "mixed" || mixed.prefix(5).contains(Int(arguments[2]) ?? 0),
            let load = ReplayLoad(rawValue: arguments[3]),
            let mode = RuntimeDiagnosticMode(rawValue: arguments[4]),
            let seconds = Int(arguments[5]), (1...3600).contains(seconds),
            let seed = UInt32(arguments[6]),
            let operation = ReplayOperation(rawValue: arguments[7]),
            operation == .soak || seconds <= 30
        else {
            throw ReplayFailure(Self.usage)
        }
        self.slots = slots
        self.profile = profile
        self.rate = rate
        pattern = Int(arguments[2]).map { [$0] } ?? mixed
        self.load = load
        self.mode = mode
        self.seconds = seconds
        self.seed = seed
        self.operation = operation
        output = URL(fileURLWithPath: arguments[8])
    }
}

func replayClock() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// One second of periodic governed input. Source coordinates determine every sample,
/// independently of producer partition, timer jitter, acquisition loss and restart.
func replaySignal(rate: Int, seed: UInt32) -> [Float] {
    var state = seed
    return (0..<rate).map { index in
        state = state &* 1_664_525 &+ 1_013_904_223
        if (rate / 2..<3 * rate / 4).contains(index) { return 0 }
        if (7 * rate / 8..<9 * rate / 10).contains(index) {
            return index.isMultiple(of: 2) ? 1 : -1
        }
        let phase = Double(index) * 250 * Double.pi / Double(rate)
        let noise = (Double(state) / Double(UInt32.max) - 0.5) * 0.002
        return Float(0.34 * sin(phase) + 0.12 * sin(2 * phase) + 0.055 * sin(3 * phase) + noise)
    }
}
