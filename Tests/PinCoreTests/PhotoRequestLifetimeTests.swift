import XCTest
@testable import PinCore

final class PhotoRequestLifetimeTests: XCTestCase {
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [String: Int]()
        func add(_ key: String) { lock.lock(); values[key, default: 0] += 1; lock.unlock() }
        func value(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key, default: 0] }
    }

    func testAlreadyCancelledTaskDoesNotStartImageRequest() {
        let request = PhotoRequestLifetime(), counts = Counts()
        request.cancel()
        let shouldStart = request.begin { counts.add("released") }
        if shouldStart { counts.add("started") }
        XCTAssertFalse(shouldStart)
        XCTAssertEqual(counts.value("released"), 1)
        XCTAssertEqual(counts.value("started"), 0)
    }

    func testCancelReleasesWaiterWithoutWaitingForPhotoKitCallback() {
        let request = PhotoRequestLifetime(), counts = Counts()
        XCTAssertTrue(request.begin { counts.add("released") })
        request.setRequestCancellation { counts.add("cancelled") }
        request.cancel()
        request.cancel()
        XCTAssertEqual(counts.value("cancelled"), 1)
        XCTAssertEqual(counts.value("released"), 1)
        XCTAssertFalse(request.complete { counts.add("delivered") })
        XCTAssertEqual(counts.value("delivered"), 0)
    }

    func testCancellationDuringStartCancelsRequestWhenIdentifierArrives() {
        let request = PhotoRequestLifetime(), counts = Counts()
        XCTAssertTrue(request.begin { counts.add("released") })
        request.cancel()
        request.setRequestCancellation { counts.add("cancelled") }
        XCTAssertEqual(counts.value("released"), 1)
        XCTAssertEqual(counts.value("cancelled"), 1)
        XCTAssertFalse(request.complete { counts.add("delivered") })
    }

    func testSynchronousResultBeforeIdentifierIsNotCancelledLater() {
        let request = PhotoRequestLifetime(), counts = Counts()
        XCTAssertTrue(request.begin { counts.add("released") })
        XCTAssertTrue(request.complete { counts.add("delivered") })
        request.setRequestCancellation { counts.add("cancelled") }
        request.cancel()
        XCTAssertEqual(counts.value("delivered"), 1)
        XCTAssertEqual(counts.value("released"), 0)
        XCTAssertEqual(counts.value("cancelled"), 0)
    }

    func testDuplicateTerminalCallbacksDeliverOnlyOnce() {
        let request = PhotoRequestLifetime(), counts = Counts()
        XCTAssertTrue(request.begin { counts.add("released") })
        XCTAssertTrue(request.complete { counts.add("first") })
        XCTAssertFalse(request.complete { counts.add("late") })
        XCTAssertEqual(counts.value("first"), 1)
        XCTAssertEqual(counts.value("late"), 0)
    }

    func testSynchronousCancellationCallbackCannotDeadlockOrDoubleDeliver() {
        let request = PhotoRequestLifetime(), counts = Counts()
        XCTAssertTrue(request.begin { counts.add("released") })
        request.setRequestCancellation {
            counts.add("cancelled")
            request.complete { counts.add("late") }
        }
        request.cancel()
        XCTAssertEqual(counts.value("cancelled"), 1)
        XCTAssertEqual(counts.value("released"), 1)
        XCTAssertEqual(counts.value("late"), 0)
    }

    func testRacingCancellationAndResultHaveOneTerminalDelivery() {
        for _ in 0..<100 {
            let request = PhotoRequestLifetime(), counts = Counts()
            XCTAssertTrue(request.begin { counts.add("released") })
            request.setRequestCancellation { counts.add("cancelled") }
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                request.cancel()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                request.complete { counts.add("delivered") }
                group.leave()
            }
            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(counts.value("released") + counts.value("delivered"), 1)
            XCTAssertEqual(counts.value("cancelled"), counts.value("released"))
        }
    }

    func testTaskCancellationCompletesEvenWhenBackendNeverCallsBack() async {
        let request = PhotoRequestLifetime(), counts = Counts()
        let started = expectation(description: "request started")
        let finished = expectation(description: "cancelled waiter finished")
        let task = Task {
            let result: Int = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard request.begin(onCancel: { continuation.resume(returning: -1) }) else { return }
                    request.setRequestCancellation { counts.add("cancelled") }
                    started.fulfill()
                    // Deliberately no backend completion.
                }
            } onCancel: { request.cancel() }
            if result == -1 { counts.add("released") }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(counts.value("released"), 1)
        XCTAssertEqual(counts.value("cancelled"), 1)
    }
}
