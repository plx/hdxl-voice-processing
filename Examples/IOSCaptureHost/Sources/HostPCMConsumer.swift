import HDXLVoiceProcessingAudio

enum HostProbeError: Error { case failed, gap, concurrentConsumer }

/// Worker-side example: consumes borrowed PCM only within withNext, with no file
/// storage or network export. The capture callback only feeds the bounded transfer.
enum HostPCMConsumer {
    struct Counts: Sendable {
        var frames: UInt64 = 0
        var chunks: UInt64 = 0
    }

    static func drain(_ transfer: PCMTransfer) async throws -> Counts {
        var counts = Counts()
        while !Task.isCancelled {
            var failure: HostProbeError?
            let result = transfer.withNext { event in
                switch event {
                case .gap: failure = .gap
                case .block(let block):
                    counts.frames += UInt64(block.frameCount)
                    counts.chunks += 1
                }
            }
            if let failure { throw failure }
            switch result {
            case .finished: return counts
            case .concurrentConsumer: throw HostProbeError.concurrentConsumer
            case .empty: try await Task.sleep(for: .milliseconds(5))
            case .delivered: break
            }
        }
        throw CancellationError()
    }
}
