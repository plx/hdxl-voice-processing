import Synchronization
import XCTest

@testable import IOSCaptureHost

final class IOSCaptureHostTests: XCTestCase {
    @MainActor func testSessionStorageRemainsSerializedAcrossDestinations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "Storage worker started")
        let release = DispatchSemaphore(value: 0)
        let rootCalls = Mutex(0)
        // Hold the first operation before publication while its destination goes
        // away. A new destination must observe the same owner and busy guard.
        let model = SessionStorageModel {
            let call = rootCalls.withLock { count in
                count += 1
                return count
            }
            if call == 1 {
                entered.fulfill()
                guard release.wait(timeout: .now() + 10) == .success else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return root
        }
        defer { release.signal() }
        var destination: SessionStorageView? = SessionStorageView(model: model)
        destination?.model.create(includeAudio: false)
        await fulfillment(of: [entered], timeout: 5)
        destination = nil
        let reopened = SessionStorageView(model: model)
        XCTAssertTrue(reopened.model === model)
        XCTAssertTrue(reopened.model.isBusy)
        reopened.model.delete()
        reopened.model.prepareShare(includeAudio: false)
        XCTAssertEqual(reopened.model.status, "Working…")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertEqual(rootCalls.withLock { $0 }, 1)
        release.signal()
        try await waitUntilIdle(model)
        XCTAssertEqual(model.inspection?.measurements, 99)
        XCTAssertNil(model.shareURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("session.hvps").path)
        )
        reopened.model.delete()
        try await waitUntilIdle(model)
        XCTAssertNil(model.inspection)
        XCTAssertEqual(model.status, "Local session and sharing copies deleted.")
        XCTAssertEqual(rootCalls.withLock { $0 }, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @MainActor private func waitUntilIdle(_ model: SessionStorageModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isBusy && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isBusy, "Storage operation did not finish")
    }

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
