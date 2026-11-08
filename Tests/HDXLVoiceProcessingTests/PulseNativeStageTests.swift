import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func pulseProfilesSeparateSupportAndRejectChangedNumericalDefinitions() throws {
    let full = try PulseConfiguration(sampleRate: 16000, pitchCeilingHz: 1500)
    let block = try PulseConfiguration(
        sampleRate: 16000, pitchCeilingHz: 1500, support: .independentlyAnchoredBlock)
    #expect(try full.identity() != block.identity())
    #expect(
        try JSONDecoder().decode(PulseConfiguration.self, from: canonicalContractJSON(full)) == full
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: canonicalContractJSON(full)) as? [String: Any])
    for (key, value): (String, Any) in [
        ("unknown", 1), ("arithmeticPrecision", "float32"),
        ("correlationDefinition", "meanRemoved"), ("minimumReliableCurvature", 0),
        ("minimumRelativeVariation", 0), ("maximumAdjacentPeriodFactor", 0.5),
    ] {
        var changed = object
        changed[key] = value
        let data = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PulseConfiguration.self, from: data)
        }
    }
    #expect(throws: PulseError.invalidConfiguration) { try PulseConfiguration(sampleRate: 0) }
    #expect(throws: PulseError.invalidConfiguration) {
        try PulseConfiguration(sampleRate: 4000, pitchCeilingHz: 1001)
    }
    #expect(throws: PulseError.invalidConfiguration) {
        try PulseConfiguration(sampleRate: 16000, minimumPeriodSeconds: 0.02)
    }
}

@Test func pulseF0QueriesPreserveVoicingAndBinaryBoundarySupport() throws {
    let pitch = try PulseF0Contour(
        sampleRate: 4000, sampleCount: 400, firstCenterSeconds: 0.025, stepSeconds: 0.025,
        ceilingHz: 900, frequenciesHz: [100, 200, 0])
    for (time, frequency) in [
        (0.0125, 100.0), (0.025, 100), (0.03125, 125),
        (0.0375, 150), (0.05, 200), (0.05625, 200),
    ] {
        let result = try pitch.observation(atRelativeSeconds: time)
        #expect(result.frequencyHz == frequency && result.unavailability == nil)
    }
    #expect(try pitch.observation(atRelativeSeconds: 0.0124).unavailability == .outsideContour)
    #expect(try pitch.observation(atRelativeSeconds: 0.0625).unavailability == .unvoiced)
    #expect(try pitch.observation(atRelativeSeconds: 0.101).unavailability == .outsideDomain)
    let decimal = try PulseF0Contour(
        sampleRate: 4000, sampleCount: 400, firstCenterSeconds: 0.025, stepSeconds: 0.025,
        ceilingHz: 900, frequenciesHz: [100, 200, 300])
    #expect(try decimal.observation(atRelativeSeconds: 0.0875).frequencyHz == 300)
    #expect(
        try decimal.observation(atRelativeSeconds: 0.0875.nextUp).unavailability == .outsideContour)
    let binary = try PulseF0Contour(
        sampleRate: 4000, sampleCount: 500, firstCenterSeconds: 0.03125, stepSeconds: 0.03125,
        ceilingHz: 900, frequenciesHz: [100, 200, 300])
    #expect(try binary.observation(atRelativeSeconds: 0.109375.nextDown).frequencyHz == 300)
    #expect(try binary.observation(atRelativeSeconds: 0.109375).unavailability == .outsideContour)
    #expect(throws: PulseError.invalidInput) { try pitch.observation(atRelativeSeconds: .nan) }
}

@Test func pulseF0IdentityAndValidationRetainExactPreparationInputs() throws {
    let pitch = try PulseF0Contour(
        sampleRate: 4000, sampleCount: 400, firstCenterSeconds: 0.025, stepSeconds: 0.025,
        ceilingHz: 900, frequenciesHz: [100, -0.0, 300])
    let decoded = try JSONDecoder().decode(PulseF0Contour.self, from: canonicalContractJSON(pitch))
    #expect(decoded == pitch)
    #expect(pitch.frequenciesHz[1].sign == .plus)
    let source = try PulseConfiguration(sampleRate: 4000).identity()
    let identified = try PulseF0Contour(
        sampleRate: 4000, sampleCount: 400, firstCenterSeconds: 0.025, stepSeconds: 0.025,
        ceilingHz: 900, frequenciesHz: [100, 0, 300], sourceProfile: source)
    #expect(try pitch.identity() != identified.identity())
    for values in [[], [900.0], [Double.nan], [-1.0], [19.0]] {
        #expect(throws: PulseError.invalidContour) {
            try PulseF0Contour(
                sampleRate: 4000, sampleCount: 400, firstCenterSeconds: 0.025, stepSeconds: 0.025,
                ceilingHz: 900, frequenciesHz: values)
        }
    }
    #expect(throws: PulseError.invalidContour) {
        try PulseF0Contour(
            sampleRate: 4000, sampleCount: 400, firstCenterSeconds: 0.025,
            stepSeconds: .leastNonzeroMagnitude, ceilingHz: 900, frequenciesHz: [100, 200])
    }
    let tinyStep = try PulseF0Contour(
        sampleRate: 4000, sampleCount: 400, firstCenterSeconds: 0.025,
        stepSeconds: .leastNonzeroMagnitude, ceilingHz: 900, frequenciesHz: [100])
    #expect(try tinyStep.observation(atRelativeSeconds: 0.05).unavailability == .outsideContour)
}

@Test func pulseNativeObservedPairCorrelationsHaveClosedFormAnswers() throws {
    let values: [Double] = [1, 0, -1, 0, 1, 0, -1, 0]
    values.withUnsafeBufferPointer { samples in
        for (start, expected) in [(4, 1.0), (2, -1.0), (1, 0.0)] {
            let r = PulseSearchKernel.correlation(
                samples, anchorFirst: 0, anchorLast: 3, candidateFirst: start,
                minimumRelativeVariation: 64 * Double.ulpOfOne)
            #expect(r.coefficient == expected && r.pairCount == 4 && r.support == .observed)
            #expect(r.varyingAnchor && r.varyingCandidate)
        }
        let partial = PulseSearchKernel.correlation(
            samples, anchorFirst: -2, anchorLast: 1, candidateFirst: 2, minimumRelativeVariation: 0)
        #expect(partial.coefficient == 1 && partial.pairCount == 2)
        let empty = PulseSearchKernel.correlation(
            samples, anchorFirst: 0, anchorLast: 3, candidateFirst: 20, minimumRelativeVariation: 0)
        #expect(empty.support == .noObservedPairs && empty.pairCount == 0)
    }
    for (value, status) in [(0.0, PulsePairSupport.silent), (0.3, .observed), (1e-200, .observed)] {
        Array(repeating: value, count: 8).withUnsafeBufferPointer { samples in
            let r = PulseSearchKernel.correlation(
                samples, anchorFirst: 0, anchorLast: 3, candidateFirst: 4,
                minimumRelativeVariation: 0)
            #expect(r.support == status && !r.varyingAnchor && !r.varyingCandidate)
        }
    }
    for gain in [1e-100, 1e-200, 1e-300, -1e-300] {
        [1.0, 0, -1, 0, 1, 0, -1, 0].map { $0 * gain }.withUnsafeBufferPointer { samples in
            let r = PulseSearchKernel.correlation(
                samples, anchorFirst: 0, anchorLast: 3, candidateFirst: 4,
                minimumRelativeVariation: 0)
            #expect(r.coefficient == 1 && r.support == .observed)
            #expect(r.varyingAnchor && r.varyingCandidate)
        }
    }
}

@Test func pulseNativeSeedUsesFractionalExtremaAndExplicitDegenerateSupport() throws {
    let worker = PulseSearchKernel(try PulseConfiguration(sampleRate: 4000, pitchCeilingHz: 1000))
    var values = Array(repeating: 0.0, count: 16)
    // y=1+x/4-x*x/2 at x=-1,0,1 has vertex x=1/4.
    values[6] = 0.25
    values[7] = 1
    values[8] = 0.75
    for gain in [1.0, -1.0] {
        try values.map { $0 * gain }.withUnsafeBufferPointer { samples in
            let seed = try worker.seed(samples, midpoint: 0.002, frequency: 500)
            #expect(abs(seed.timeSeconds - 0.0019375) < 1e-17)
            #expect(seed.varyingSupport && seed.peak == 1)
        }
    }
    for value in [0.0, 0.3] {
        try Array(repeating: value, count: 16).withUnsafeBufferPointer { samples in
            let seed = try worker.seed(samples, midpoint: 0.002, frequency: 500)
            #expect(seed.timeSeconds == 0.002 && !seed.varyingSupport)
        }
    }
    try [0.5, -0.5].withUnsafeBufferPointer { samples in
        let seed = try worker.seed(samples, midpoint: 0.00025, frequency: 500)
        #expect(seed.timeSeconds == 0.00025)
    }
}

@Test func pulseNativeMatchingRecoversAnExactSamplePeriodAndReusesItsWorkspace() throws {
    let worker = PulseSearchKernel(try PulseConfiguration(sampleRate: 4000, pitchCeilingHz: 1000))
    let cycle: [Double] = [0, 0, 0.5, 1, 0.5, 0, 0, 0]
    let values = Array(repeating: cycle, count: 8).flatMap { $0 }
    let bytes = worker.workspaceBytes
    for _ in 0..<3 {
        try values.withUnsafeBufferPointer { samples in
            for direction in [PulseSearchDirection.backward, .forward] {
                let r = try worker.match(
                    samples, anchor: 0.004875, frequency: 500, direction: direction)
                #expect(
                    abs(r.timeSeconds - (0.004875 + Double(direction.rawValue) * 0.002)) < 1e-17)
                #expect(r.correlation == 1 && r.varyingSupport && !r.usedRangeFallback)
                #expect(r.observedPairCount == 9 && r.curvature > 0)
            }
            #expect(throws: PulseError.invalidInput) {
                try worker.match(samples, anchor: .infinity, frequency: 500, direction: .forward)
            }
        }
        #expect(worker.workspaceBytes == bytes)
    }
}
