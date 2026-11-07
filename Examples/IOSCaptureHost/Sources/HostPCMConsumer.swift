import HDXLVoiceProcessingAudio

enum HostProbeError: Error { case failed, gap, concurrentConsumer }

/// Worker-side example: consumes borrowed PCM only within withNext, with no file
/// storage or network export. The capture callback only feeds the bounded transfer.
enum HostPCMConsumer {
    static func drain(_ transfer: PCMTransfer) async throws -> UInt64 {
        var frames: UInt64 = 0
        while !Task.isCancelled {
            var failure: HostProbeError?
            let result = transfer.withNext { event in
                switch event {
                case .gap: failure = .gap
                case .block(let block): frames += UInt64(block.frameCount)
                }
            }
            if let failure { throw failure }
            switch result {
            case .finished: return frames
            case .concurrentConsumer: throw HostProbeError.concurrentConsumer
            case .empty: try await Task.sleep(for: .milliseconds(5))
            case .delivered: break
            }
        }
        throw CancellationError()
    }
}
