import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func swipePrimeMaximumPreparedGeometryAndExtremeFiniteScaleRemainBounded() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 192000, pitchFloorHz: 20, pitchCeilingHz: 48000,
        hopLength: 960, candidatesPerOctave: 192, silenceRMSThreshold: 0)
    let worker = try PreparedSWIPEPrime<Double>(c)
    #expect(c.requiredSampleCount == 131072)
    #expect(worker.layout.candidateFrequenciesHz.count <= 2304)
    #expect(worker.executionStatistics.preparedBufferBytes < 64 * 1024 * 1024)
    let timing = try AnalysisTiming(
        source: SourceInterval(
            epoch: StreamEpoch(streamID: UUID()), startSample: 0,
            sampleCount: Int64(c.requiredSampleCount), sampleRate: 192000),
        includedSampleCount: Int64(c.requiredSampleCount))
    let signal = (0..<c.requiredSampleCount).map {
        0.5 * sin(2 * .pi * 200 * Double($0) / 192000)
            + 0.1 * sin(2 * .pi * 400 * Double($0) / 192000)
    }
    var baseline: SWIPEPrimeObservation?
    let bytes = worker.executionStatistics.preparedBufferBytes
    for scale in [1.0, 1e300, 1e-300] {
        let samples = signal.map { $0 * scale }
        try samples.withUnsafeBufferPointer { input in
            try worker.analyze(input, timing: timing) { output in
                #expect(output.result.status == .voiced)
                #expect(output.candidateStrengths.allSatisfy { $0?.isFinite == true })
                #expect(output.windows.allSatisfy { $0.magnitude.allSatisfy { $0.isFinite } })
                if let result = output.result.observation {
                    if let baseline {
                        #expect(result.candidateIndex == baseline.candidateIndex)
                        #expect(abs(result.frequencyHz - baseline.frequencyHz) < 1e-6)
                        #expect(abs(result.pitchStrength - baseline.pitchStrength) < 1e-8)
                    } else {
                        baseline = result
                    }
                } else {
                    Issue.record("Finite harmonic signal lost its observation")
                }
            }
        }
        #expect(worker.executionStatistics.preparedBufferBytes == bytes)
    }
    #expect(worker.executionStatistics.analyzedFrameCount == 3)
}

@Test func swipePrimeGridEndpointsAndNearCoincidentRefinementStayInsideNeighbors() throws {
    let floor = 100.0
    let ceiling = floor * pow(2, 2.0 / 192) * (1 + 2e-12)
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: floor, pitchCeilingHz: ceiling,
        hopLength: 40, candidatesPerOctave: 192)
    let layout = SWIPEPrimeLayout(configuration: c)
    #expect(layout.candidateFrequenciesHz.count == 4)
    #expect(layout.candidateFrequenciesHz.last == ceiling)
    let frequencies = layout.candidateFrequenciesHz
    let target = frequencies[2] + (frequencies[3] - frequencies[2]) / 4
    let strengths: [Double?] = frequencies.map { 0.8 - pow(target / $0 - 1, 2) }
    strengths.withUnsafeBufferPointer {
        let result = SWIPEPrimeNumerics.refine(
            frequencies: frequencies, strengths: $0, selected: 2, threshold: 0.2)
        #expect(result.frequencyHz.isFinite && result.pitchStrength.isFinite)
        #expect((frequencies[1]...frequencies[3]).contains(result.frequencyHz))
    }
    for (index, values) in [(0, [0.9, 0.8, 0.7, 0.6]), (3, [0.6, 0.7, 0.8, 0.9])] {
        let strengths = values.map(Optional.some)
        strengths.withUnsafeBufferPointer {
            let result = SWIPEPrimeNumerics.refine(
                frequencies: frequencies, strengths: $0, selected: index, threshold: 0.2)
            #expect(!result.isRefined && result.frequencyHz == frequencies[index])
        }
    }
}
