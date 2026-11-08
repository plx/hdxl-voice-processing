import Foundation
import XCTest

final class SessionInterchangeTests: XCTestCase {
    func testSessionArchiveFixturesOnIOS27() throws {
        let directory = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "Sessions", withExtension: nil))
        let report = try SessionFixtureProbe.run(
            fixtures: directory, scratch: FileManager.default.temporaryDirectory)
        XCTAssertEqual(report.status, "passed")
        XCTAssertEqual(report.checks, SessionFixtureProbe.checks)
        XCTAssertEqual(report.fixtures, 6)
        XCTAssertEqual(report.completeRoundTrips, 5)
        XCTAssertEqual(report.scalarMeasurements, 15)
        XCTAssertEqual(report.replayedMeasurements, 4)
        XCTAssertEqual(report.calibrationTakes, 64)
        XCTAssertEqual(report.calibrationTargets, 2)
    }
}
