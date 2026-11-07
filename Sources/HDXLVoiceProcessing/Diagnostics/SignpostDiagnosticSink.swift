#if canImport(os) && !HDXL_DISABLE_SIGNPOSTS
    import os

    final class SignpostDiagnosticSink: DiagnosticSink {
        static let subsystem = "org.hdxl.voice-processing"
        private let lifecycle = OSSignposter(subsystem: subsystem, category: "lifecycle")
        private let flow = OSSignposter(subsystem: subsystem, category: "flow")
        private let worker = OSSignposter(subsystem: subsystem, category: "worker")
        private let delivery = OSSignposter(subsystem: subsystem, category: "delivery")
        private let rendering = OSSignposter(subsystem: subsystem, category: "rendering")

        private func poster(_ stage: DiagnosticStage) -> OSSignposter {
            switch stage.category {
            case "lifecycle": lifecycle
            case "flow": flow
            case "delivery": delivery
            case "rendering": rendering
            default: worker
            }
        }

        func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken? {
            let poster = poster(record.stage)
            guard poster.isEnabled else { return nil }
            // Allocate IDs and interval state only on the worker. Per-interval IDs
            // disambiguate nested and overlapping analyzers with the same names.
            let state = poster.beginInterval(
                record.stage.signpostName, id: poster.makeSignpostID(),
                "session=\(record.session) epoch=\(record.epoch) span=\(record.span) profile=\(record.metadata.profileToken) frame=\(record.metadata.frameSequence) samples=\(record.metadata.sampleCount) depth=\(record.metadata.queueDepth) validity=\(record.metadata.validity.rawValue) processed=\(record.metadata.elapsedProcessingCount) queue_ns=\(record.metadata.queueWaitNanoseconds ?? UInt64.max)"
            )
            return .signpost(state)
        }

        func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken) {
            guard case .signpost(let state) = token else { return }
            poster(record.stage).endInterval(record.stage.signpostName, state)
        }

        func event(_ record: DiagnosticRecord) -> Bool {
            let poster = poster(record.stage)
            guard poster.isEnabled else { return false }
            poster.emitEvent(
                record.stage.signpostName, id: poster.makeSignpostID(),
                "session=\(record.session) epoch=\(record.epoch) span=\(record.span) profile=\(record.metadata.profileToken) frame=\(record.metadata.frameSequence) samples=\(record.metadata.sampleCount) depth=\(record.metadata.queueDepth) validity=\(record.metadata.validity.rawValue) processed=\(record.metadata.elapsedProcessingCount) queue_ns=\(record.metadata.queueWaitNanoseconds ?? UInt64.max)"
            )
            return true
        }
    }
#endif
