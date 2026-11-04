import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func digitalLevelsDistinguishSilenceRangeAndUnavailability() throws {
    let sine = try LevelEnergy(scale: 1, normalizedMeanSquare: 0.5)
    #expect(sine.meanSquare.estimate?.value == 0.5)
    #expect(sine.rms.estimate?.value == sqrt(0.5))
    #expect(abs(try #require(sine.digitalLevel.finiteDecibels) + 3.010299956639812) < 1e-12)
    let quieter = try LevelEnergy(scale: 0.5, normalizedMeanSquare: 0.5)
    #expect(
        abs(
            try #require(sine.digitalLevel.finiteDecibels) - #require(
                quieter.digitalLevel.finiteDecibels) - 6.020599913279624) < 1e-12)
    #expect(LevelEnergy.zero.meanSquare.estimate?.value == 0)
    #expect(LevelEnergy.zero.rms.estimate?.value == 0)
    #expect(LevelEnergy.zero.digitalLevel.status == .zeroEnergy)
    #expect(LevelEnergy.zero.digitalLevel.mathematicalDecibels == -.infinity)
    #expect(LevelEnergy.zero.digitalLevel.scalarOutcome == .unavailable(.silence))
    #expect(DigitalLevel.unavailable(.insufficientData).mathematicalDecibels == nil)
    #expect(DigitalLevel.unavailable(.invalidInput).scalarOutcome == .unavailable(.invalidInput))

    let smallest = try LevelEnergy(scale: Double.leastNonzeroMagnitude, normalizedMeanSquare: 1)
    #expect(!smallest.isZero)
    #expect(smallest.rms.estimate?.value == Double.leastNonzeroMagnitude)
    #expect(smallest.meanSquare == .unavailable(.unsupportedRange))
    #expect(smallest.digitalLevel.status == .finite)
    #expect(try #require(smallest.digitalLevel.finiteDecibels) < -6400)
    let smallerRMS = try LevelEnergy(
        scale: Double.leastNonzeroMagnitude, normalizedMeanSquare: 0.125)
    #expect(smallerRMS.rms == .unavailable(.unsupportedRange))
    #expect(smallerRMS.digitalLevel.status == .finite)
    let huge = try LevelEnergy(scale: Double.greatestFiniteMagnitude, normalizedMeanSquare: 1)
    #expect(huge.meanSquare == .unavailable(.unsupportedRange))
    #expect(huge.rms.estimate?.value == Double.greatestFiniteMagnitude)
    #expect(huge.digitalLevel.status == .finite)
    let representableProduct = try LevelEnergy(scale: 1e160, normalizedMeanSquare: 1e-20)
    #expect(abs(try #require(representableProduct.meanSquare.estimate?.value) / 1e300 - 1) < 1e-15)

    for energy in [sine, quieter, .zero, smallest, smallerRMS, huge, representableProduct] {
        #expect(
            try JSONDecoder().decode(LevelEnergy.self, from: JSONEncoder().encode(energy)) == energy
        )
        #expect(
            try JSONDecoder().decode(
                DigitalLevel.self, from: JSONEncoder().encode(energy.digitalLevel))
                == energy.digitalLevel)
    }
    #expect(try DigitalLevel.finite(-0.0) == .finite(0.0))
    #expect(throws: ContractError.invalidValue) { try DigitalLevel.finite(.infinity) }
    for (scale, value) in [(0.0, 1.0), (1.0, 0.0), (-1.0, 0.5), (.nan, 1.0), (1.0, 1.01)] {
        #expect(throws: ContractError.invalidValue) {
            try LevelEnergy(scale: scale, normalizedMeanSquare: value)
        }
    }
    for text in [
        #"{"status":"zeroEnergy","finiteDecibels":0}"#,
        #"{"status":"finite"}"#,
        #"{"status":"unavailable"}"#,
        #"{"status":"zeroEnergy","unavailability":"silence"}"#,
        #"{"status":"zeroEnergy","future":true}"#,
    ] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DigitalLevel.self, from: Data(text.utf8))
        }
    }
}

@Test func scaledEnergyHasClosedFormResultsWithoutSquaringOverflow() throws {
    func energy(_ values: [Double]) throws -> LevelEnergy {
        var sum = LevelScaledSum()
        for value in values { sum.append(value) }
        return try sum.energy(sampleCount: values.count)
    }
    let known = try energy([3, 4])
    #expect(known.scale == 4)
    #expect(known.meanSquare.estimate?.value == 12.5)
    let a = try energy([1, 2, 3])
    let b = try energy([4, 5])
    let all = try energy([1, 2, 3, 4, 5])
    let firstEnergy = try #require(a.meanSquare.estimate?.value) * 3
    let secondEnergy = try #require(b.meanSquare.estimate?.value) * 2
    let combinedEnergy = try #require(all.meanSquare.estimate?.value) * 5
    #expect(abs(firstEnergy + secondEnergy - combinedEnergy) < 1e-13)
    let tiny = try energy([Double.leastNonzeroMagnitude, 0, 0, 0])
    #expect(!tiny.isZero && tiny.scale == Double.leastNonzeroMagnitude)
    #expect(tiny.normalizedMeanSquare == 0.25)
    #expect(tiny.digitalLevel.status == .finite)
    let huge = try energy([Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude])
    #expect(huge.scale == Double.greatestFiniteMagnitude && huge.normalizedMeanSquare == 1)
    #expect(try energy([0, -0.0]) == .zero)
    #expect(throws: ContractError.invalidConfiguration) { try energy([]) }
}
