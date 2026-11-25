import XCTest
@testable import PinCore

final class VoiceCaptureSessionTests: XCTestCase {
    func testBackgroundCancellationNeverSubmitsPartialOrLateFinal() throws {
        var session = VoiceCaptureSession()
        let id = try XCTUnwrap(session.begin())
        XCTAssertTrue(session.startRecording(id))
        XCTAssertTrue(session.partial("List appointments except", from: id))
        session.cancel()
        XCTAssertNil(session.final("List appointments except tickets", from: id))
        XCTAssertFalse(session.partial("List appointments", from: id))
        XCTAssertEqual(session.phase, .idle)
    }
    func testCancelledPermissionCallbackCannotStartOrAffectNextCapture() throws {
        var session = VoiceCaptureSession()
        let old = try XCTUnwrap(session.begin())
        session.cancel()
        let next = try XCTUnwrap(session.begin())
        XCTAssertFalse(session.owns(old))
        XCTAssertFalse(session.startRecording(old))
        XCTAssertTrue(session.startRecording(next))
        XCTAssertNil(session.final("Old question", from: old))
        XCTAssertEqual(session.final("New question", from: next), .question("New question"))
    }
    func testStopWaitsForFinalRecognitionInsteadOfUsingPartialIntent() throws {
        var session = VoiceCaptureSession()
        let id = try XCTUnwrap(session.begin())
        XCTAssertTrue(session.startRecording(id))
        XCTAssertTrue(session.partial("Show appointments", from: id))
        XCTAssertEqual(session.requestFinish(), id)
        XCTAssertEqual(session.phase, .finishing)
        XCTAssertTrue(session.partial("Show appointments except concerts", from: id))
        XCTAssertEqual(session.final("Show appointments except concerts.", from: id), .question("Show appointments except concerts."))
    }
    func testTimeoutLeavesNoQuestionToSubmitAndAllowsFreshCapture() throws {
        var session = VoiceCaptureSession()
        let old = try XCTUnwrap(session.begin())
        XCTAssertTrue(session.startRecording(old))
        XCTAssertTrue(session.partial("How many", from: old))
        XCTAssertEqual(session.requestFinish(), old)
        session.cancel() // Actual timeout path discards session; UI retains its separate draft.
        XCTAssertNil(session.final("How many tomorrow?", from: old))
        let next = try XCTUnwrap(session.begin())
        XCTAssertNotEqual(next, old)
        XCTAssertEqual(session.latest, "")
        XCTAssertEqual(session.phase, .preparing)
    }
    func testOneActiveCaptureAndOneFinalSubmission() throws {
        var session = VoiceCaptureSession()
        let id = try XCTUnwrap(session.begin())
        XCTAssertNil(session.begin())
        XCTAssertTrue(session.startRecording(id))
        XCTAssertEqual(session.final("Where is the concert?", from: id), .question("Where is the concert?"))
        XCTAssertNil(session.final("Where is the concert?", from: id))
        XCTAssertNil(session.requestFinish())
    }
    func testEmptyRecognitionHasExplicitEmptyOutcome() throws {
        var session = VoiceCaptureSession()
        let id = try XCTUnwrap(session.begin())
        XCTAssertTrue(session.startRecording(id))
        XCTAssertEqual(session.final(" \n ", from: id), .empty)
        XCTAssertEqual(session.phase, .idle)
    }
    func testFinalQuestionPreservesQuotesTyposAndConditions() throws {
        var session = VoiceCaptureSession()
        let id = try XCTUnwrap(session.begin())
        XCTAssertFalse(session.partial("before permission", from: id))
        XCTAssertNil(session.final("before permission", from: id))
        XCTAssertTrue(session.startRecording(id))
        let question = "“What appointent do I have today, except concerts?”"
        XCTAssertEqual(session.final("  " + question + "\n", from: id), .question(question))
    }
}
