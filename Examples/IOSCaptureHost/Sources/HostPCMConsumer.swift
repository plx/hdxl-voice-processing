import HDXLVoiceProcessingAudio

enum HostProbeError: Error { case failed, concurrentConsumer }

/// Worker-side example: consumes borrowed PCM only within withNext, with no file
/// storage or network export. The capture callback only feeds the bounded transfer.
enum HostPCMConsumer {
    struct Counts: Sendable {
        var frames: UInt64 = 0
        var chunks: UInt64 = 0
        var knownGapFrames: UInt64 = 0
        var unknownGaps: UInt64 = 0
    }

    struct GapFailure: Error {
        let counts: Counts
    }

    static func drain(
        _ transfer: PCMTransfer, closeOnGap: @Sendable () async -> Void
    ) async throws -> Counts {
        var counts = Counts()
        var sawGap = false
        while !Task.isCancelled {
            var closeAdmission = false
            var extentOverflow = false
            let result = transfer.withNext { event in
                switch event {
                case .gap(let gap):
                    closeAdmission = !sawGap
                    sawGap = true
                    if let interval = gap.missingSource {
                        let sum = counts.knownGapFrames.addingReportingOverflow(
                            UInt64(interval.frameCount))
                        counts.knownGapFrames = sum.partialValue
                        extentOverflow = sum.overflow
                    } else {
                        counts.unknownGaps += 1
                    }
                case .block(let block):
                    counts.frames += UInt64(block.frameCount)
                    counts.chunks += 1
                }
            }
            if closeAdmission { await closeOnGap() }
            if extentOverflow { throw HostProbeError.failed }
            switch result {
            case .finished:
                if sawGap { throw GapFailure(counts: counts) }
                return counts
            case .concurrentConsumer: throw HostProbeError.concurrentConsumer
            case .empty: try await Task.sleep(for: .milliseconds(5))
            case .delivered: break
            }
        }
        throw CancellationError()
    }
}
