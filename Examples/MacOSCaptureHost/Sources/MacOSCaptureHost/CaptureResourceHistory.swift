import Darwin
import Foundation
import HDXLVoiceProcessingAudio

/// Development-host observations, taken on the control side. Keep a bounded,
/// progressively coarser history and a separate final reading for a long trial.
struct CaptureResourceHistory {
    struct Sample: Encodable {
        let epoch: String
        let elapsedSeconds: Double
        let processCPUSeconds: Double?
        let residentBytes: UInt64?
        let queueDepthSlots: Int?
        let thermalState: String
    }

    private let startNS: UInt64
    private var interval = 1.0
    private(set) var samples: [Sample] = []
    private(set) var final: Sample?

    init(startNS: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.startNS = startNS
    }

    mutating func observe(_ transfer: PCMTransfer, finishing: Bool = false) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNS) / 1e9
        if let previous = samples.last, !finishing, elapsed - previous.elapsedSeconds < interval {
            return
        }
        let sample = Sample(
            epoch: transfer.configuration.epoch.streamID.uuidString, elapsedSeconds: elapsed,
            processCPUSeconds: Self.cpuSeconds(), residentBytes: Self.residentBytes(),
            queueDepthSlots: transfer.snapshot().depth, thermalState: Self.thermalState())
        if finishing {
            final = sample
            return
        }
        if samples.count >= 128 {
            samples = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
            interval *= 2
        }
        samples.append(sample)
    }

    var readings: [Sample] {
        guard let final, final.elapsedSeconds != samples.last?.elapsedSeconds else {
            return samples
        }
        return samples + [final]
    }

    private static func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = usage.ru_utime
        let system = usage.ru_stime
        return Double(user.tv_sec + system.tv_sec) + Double(user.tv_usec + system.tv_usec) / 1e6
    }

    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : nil
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unavailable"
        }
    }
}
