import Synchronization
import Testing

@testable import HDXLVoiceProcessing

@Test func runtimeLatencyKeepsMissingZeroAndSaturationDistinct() {
    var summary = RuntimeLatencySummary()
    summary.record(nil)
    summary.record(10)
    summary.record(0)
    summary.record(20)
    #expect(summary.samples == 3 && summary.unavailableSamples == 1)
    #expect(summary.minimumNanoseconds == 0 && summary.maximumNanoseconds == 20)
    #expect(summary.meanNanoseconds == 10)
    summary.record(nil)
    #expect(summary.lastNanoseconds == nil && summary.meanNanoseconds == 10)
    summary.record(.max)
    #expect(summary.saturated && summary.totalNanoseconds == .max)
    #expect(summary.meanNanoseconds == nil)
}

private enum RenderingTestError: Error { case expected }

@Test func runtimeRenderingModesPreserveWorkAndBalanceThrowingScopes() throws {
    for mode in RuntimeDiagnosticMode.allCases {
        let clock = Mutex<UInt64>(0)
        let sink = RecordingSink()
        let renderer = ResultRenderingDiagnostics(
            mode: mode, sink: sink,
            clock: {
                clock.withLock {
                    $0 += 10
                    return $0
                }
            })
        for index in 0..<32 { #expect(renderer.measure { index * 2 } == index * 2) }
        #expect(throws: RenderingTestError.expected) {
            try renderer.measure { throw RenderingTestError.expected }
        }
        #expect(renderer.duration.samples == (mode == .disabled ? 0 : 33))
        #expect(renderer.duration.meanNanoseconds == (mode == .disabled ? nil : 10))
        #expect(clock.withLock { $0 } == (mode == .disabled ? 0 : 660))
        var begins: [DiagnosticRecord] = []
        var ends: [DiagnosticRecord] = []
        for entry in sink.entries {
            switch entry {
            case .begin(let record): begins.append(record)
            case .end(let record): ends.append(record)
            default: break
            }
        }
        #expect(begins == ends)
        #expect(begins.count == (mode == .disabled ? 0 : mode == .sampled ? 3 : 33))
        #expect(begins.allSatisfy { $0.stage == .rendering && $0.stage.category == "rendering" })
    }
}

@Test func runtimePublicationAndDeliveryUseSeparatePairedCategories() async throws {
    for mode in RuntimeDiagnosticMode.allCases {
        let sink = RecordingSink()
        let clock = Mutex<UInt64>(0)
        let publisher = try BoundedResultPublisher<Int>(
            maximumSubscribers: 2, replayLatest: false, diagnostics: mode,
            diagnosticSink: sink,
            clock: {
                clock.withLock {
                    $0 += 1
                    return $0
                }
            })
        let subscriber = try publisher.subscribe(.failOnOverflow(capacity: 32))
        for value in 0..<32 { publisher.publish(value) }
        publisher.finish()
        var values: [Int] = []
        for try await receipt in subscriber {
            values.append(receipt.value)
            #expect(receipt.statistics.lastSubscriberLagNanoseconds != nil)
        }
        #expect(values == Array(0..<32))
        var begins: [DiagnosticRecord] = []
        var ends: [DiagnosticRecord] = []
        for entry in sink.entries {
            switch entry {
            case .begin(let record): begins.append(record)
            case .end(let record): ends.append(record)
            default: break
            }
        }
        #expect(begins == ends)
        let expected = mode == .disabled ? 0 : mode == .sampled ? 2 : 32
        let publication = begins.filter { $0.stage == .resultPublication }
        let delivery = begins.filter { $0.stage == .resultDelivery }
        #expect(publication.count == expected && delivery.count == expected)
        #expect(
            delivery.allSatisfy {
                $0.stage.category == "delivery" && $0.metadata.queueWaitNanoseconds != nil
            })
        #expect(publication.allSatisfy { $0.metadata.profileToken == 5401 })
        #expect(delivery.allSatisfy { $0.metadata.profileToken == 5402 })
        if mode != .disabled { #expect(publication.first?.session != delivery.first?.session) }
    }
}
