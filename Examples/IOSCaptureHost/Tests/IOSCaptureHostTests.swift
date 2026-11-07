import XCTest

@testable import IOSCaptureHost

final class IOSCaptureHostTests: XCTestCase {
    @MainActor func testSyntheticHostWithoutMicrophoneAccess() async throws {
        let result = try await HostSelfTest.run()
        XCTAssertEqual(result.status, "passed")
        XCTAssertEqual(
            result.checks,
            [
                "late-start-intent-rejected", "late-lifecycle-intent-rejected",
                "idempotent-lifecycle-finish",
                "bounded-lifecycle-display-completion", "independent-lifecycle-strict-delivery",
                "private-error-redacted",
                "permission-states-distinct",
                "bounded-pcm-samples-preserved",
                "closed-transfer-drained", "worker-rejects-gap",
            ])
    }
}
