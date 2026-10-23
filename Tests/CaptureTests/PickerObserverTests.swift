import XCTest
@testable import Capture

final class PickerObserverTests: XCTestCase {
    func testResultDeliveredBeforeWaitingIsNotLost() async {
        let observer = PickerObserver()
        observer.finish(.failure(CapturePermissionError.denied))

        do {
            try await observer.waitForCompletion()
            XCTFail("Expected the cancelled picker to throw")
        } catch CapturePermissionError.denied {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResultDeliveredWhileWaitingResumesTheCaller() async throws {
        let observer = PickerObserver()
        let waiter = Task { try await observer.waitForCompletion() }
        DispatchQueue.global().async { observer.finish(.success(())) }
        try await waiter.value
    }

    func testOnlyTheFirstResultCounts() async throws {
        let observer = PickerObserver()
        observer.finish(.success(()))
        observer.finish(.failure(CapturePermissionError.denied))
        try await observer.waitForCompletion()
    }
}
