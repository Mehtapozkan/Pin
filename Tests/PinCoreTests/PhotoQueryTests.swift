import Foundation
import XCTest
@testable import PinCore

final class PhotoQueryTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-10-28T19:00:00Z") }
    private func photo(_ id: String, _ instant: String? = nil, text: [String] = [], screenshot: Bool? = false) -> PhotoMemory {
        PhotoMemory(id: id, fingerprint: "\(id)-v1", photographedAt: instant.map(date), text: text, isScreenshot: screenshot)
    }
    private func plan(_ request: PhotoQueryRequest) -> PhotoQueryPlan { PhotoQueryCompiler.compile(request, now: now, calendar: calendar)! }

    func testCaptureWeekDoesNotSearchForWeekWordsOrPrintedEventDates() {
        let rows = [photo("current", "2026-10-26T07:00:00Z", text: ["Printed event: May 1, 2027"]),
                    photo("old-words", "2025-10-28T19:00:00Z", text: ["I took this photo this week"]),
                    photo("next-boundary", "2026-11-02T08:00:00Z", text: ["this week"])]
        let result = PhotoQueryExecutor.execute(plan(.init(capturePeriod: .thisWeek)), in: rows)
        XCTAssertEqual(result.hits.map(\.id), ["current"])
    }
    func testLiteralTextIsConjunctiveWithDateAndNeverUsesLabelsOrTokenOverlap() {
        let a = photo("match", "2026-10-28T19:00:00Z", text: ["Violet", "lantern"])
        let b = photo("overlap", "2026-10-28T19:00:00Z", text: ["violet archive and paper lantern"])
        let c = photo("old", "2025-10-28T19:00:00Z", text: ["violet lantern"])
        var d = photo("labels", "2026-10-28T19:00:00Z"); d.labels = [VisualLabel("violet lantern", confidence: 1)]
        let result = PhotoQueryExecutor.execute(plan(.init(capturePeriod: .thisWeek, recognizedText: "VIOLET  lantern")), in: [a,b,c,d])
        XCTAssertEqual(result.hits.map(\.id), ["match"]); XCTAssertEqual(result.withoutRecognizedText, 1)
    }
    func testLiteralMetacharactersUnicodeAndAccentsArePreserved() {
        let rows = [photo("literal", text: ["C++ (main) café"]),photo("different", text: ["C main cafe"])]
        XCTAssertEqual(PhotoQueryExecutor.execute(plan(.init(recognizedText: "C++ (MAIN) cafe\u{301}")), in: rows).hits.map(\.id), ["literal"])
        XCTAssertTrue(PhotoQueryExecutor.execute(plan(.init(recognizedText: "C++ (main) cafe")), in: rows).hits.isEmpty)
    }
    func testMissingMetadataDoesNotBecomeMatchAndReasonsAreDisjoint() {
        let rows = [photo("no-text", screenshot: nil),photo("no-type", text: ["key"], screenshot: nil),
                    photo("no-date", text: ["key"], screenshot: true),photo("known-nonshot", "2026-10-28T19:00:00Z", text: ["key"])]
        let r = PhotoQueryExecutor.execute(plan(.init(capturePeriod: .today, recognizedText: "key", media: .screenshots)), in: rows)
        XCTAssertTrue(r.hits.isEmpty); XCTAssertEqual(r.withoutRecognizedText,1); XCTAssertEqual(r.withoutScreenshotStatus,1); XCTAssertEqual(r.withoutPhotoDate,1)
        XCTAssertEqual(PhotoQueryExecutor.execute(plan(.init(recognizedText: "key")), in: rows).hits.count,3)
    }
    func testKnownExclusionDoesNotInflateMissingDetailsForTheQuery() {
        let rows = [photo("old-no-text","2025-10-28T19:00:00Z",screenshot:nil),
                    photo("old-no-type","2025-10-28T19:00:00Z",text:["key"],screenshot:nil),
                    photo("nonshot-no-text","2026-10-28T19:00:00Z",screenshot:false),
                    photo("wrong-text-no-date",text:["other"],screenshot:true),
                    photo("possible-no-text","2026-10-28T19:00:00Z",screenshot:true),
                    photo("possible-no-type","2026-10-28T19:00:00Z",text:["key"],screenshot:nil),
                    photo("possible-no-date",text:["key"],screenshot:true)]
        let result=PhotoQueryExecutor.execute(plan(.init(capturePeriod:.thisWeek,recognizedText:"key",media:.screenshots)),in:rows)
        XCTAssertTrue(result.hits.isEmpty); XCTAssertEqual(result.withoutRecognizedText,1)
        XCTAssertEqual(result.withoutScreenshotStatus,1); XCTAssertEqual(result.withoutPhotoDate,1)
    }
    func testNonScreenshotsDoNotMeanCameraPhotosOrUnknownSubtype() {
        let rows = [photo("download", text:["key"], screenshot:false),photo("shot",text:["key"],screenshot:true),photo("unknown",text:["key"],screenshot:nil)]
        XCTAssertEqual(PhotoQueryExecutor.execute(plan(.init(media:.nonScreenshots)), in:rows).hits.map(\.id),["download"])
    }
    func testCalendarDayHandlesDSTAndHalfOpenBoundaries() {
        let spring = PhotoQueryCompiler.compile(.init(capturePeriod:.today),now:date("2027-03-14T19:00:00Z"),calendar:calendar)!
        XCTAssertEqual(spring.captureInterval!.duration,23*3600)
        let fall = PhotoQueryCompiler.compile(.init(capturePeriod:.today),now:date("2026-11-01T20:00:00Z"),calendar:calendar)!
        XCTAssertEqual(fall.captureInterval!.duration,25*3600)
        let start=fall.captureInterval!.start,end=fall.captureInterval!.end
        let rows=[PhotoMemory(id:"start",fingerprint:"s",photographedAt:start),PhotoMemory(id:"end",fingerprint:"e",photographedAt:end)]
        XCTAssertEqual(PhotoQueryExecutor.execute(fall,in:rows).hits.map(\.id),["start"])
    }
    func testWeekRespectsFirstWeekdayAndPlanStaysAnchoredAcrossRollover() {
        let monday=plan(.init(capturePeriod:.thisWeek));var sunday=calendar;sunday.firstWeekday=1
        let other=PhotoQueryCompiler.compile(.init(capturePeriod:.thisWeek),now:now,calendar:sunday)!
        XCTAssertNotEqual(monday.captureInterval,other.captureInterval)
        XCTAssertEqual(monday.calendar,calendar); XCTAssertEqual(other.calendar,sunday)
        let fresh=PhotoQueryCompiler.compile(.init(capturePeriod:.thisWeek),now:date("2026-11-04T20:00:00Z"),calendar:calendar)!
        let row=photo("old-answer-member","2026-10-28T19:00:00Z")
        XCTAssertEqual(PhotoQueryExecutor.execute(monday,in:[row]).hits.count,1)
        XCTAssertTrue(PhotoQueryExecutor.execute(fresh,in:[row]).hits.isEmpty)
    }
    func testYesterdayLastWeekAndInvalidRequests() {
        XCTAssertEqual(PhotoQueryCompiler.compile(.init(capturePeriod:.yesterday),now:now,calendar:calendar)!.captureInterval!.end,calendar.startOfDay(for:now))
        XCTAssertEqual(PhotoQueryCompiler.compile(.init(capturePeriod:.lastWeek),now:now,calendar:calendar)!.captureInterval!.end,plan(.init(capturePeriod:.thisWeek)).captureInterval!.start)
        XCTAssertNil(PhotoQueryCompiler.compile(.init(capturePeriod:.unsupported),now:now,calendar:calendar))
        XCTAssertNil(PhotoQueryCompiler.compile(.init(recognizedText:" \n "),now:now,calendar:calendar))
        XCTAssertNil(PhotoQueryCompiler.compile(.init(recognizedText:String(repeating:"a",count:4097)),now:now,calendar:calendar))
    }
    func testCompositionalExplicitGrammarConsumesEveryWord() {
        for text in ["Find photos I took this week containing \"violet lantern\"", "Show me the photos containing “violet lantern” and taken this week", "Photos taken this week containing 'violet lantern'", "Which photos did I take this week with the text \"violet lantern\"?"] {
            XCTAssertEqual(PhotoQuestion.explicitRequest(text),.photos(.init(capturePeriod:.thisWeek,recognizedText:"violet lantern")),text)
        }
        XCTAssertEqual(PhotoQuestion.explicitRequest("Find screenshots that say \"this week\""),.photos(.init(recognizedText:"this week",media:.screenshots)))
        XCTAssertEqual(PhotoQuestion.explicitRequest("Photos from last week"),.photos(.init(capturePeriod:.lastWeek)))
        XCTAssertEqual(PhotoQuestion.explicitRequest("Show screenshots"),.photos(.init(media:.screenshots)))
    }
    func testConversationalWithKeepsTheLiteralAndOtherPredicates() {
        let phrase = "paper seed envelope"
        for question in [
            "Find the photo with \"paper seed envelope\"",
            "Show me the picture with “paper seed envelope”.",
            "Find photos with 'paper seed envelope'"
        ] {
            XCTAssertEqual(PhotoQuestion.explicitRequest(question), .photos(.init(recognizedText: phrase)), question)
        }
        XCTAssertEqual(
            PhotoQuestion.explicitRequest("Find screenshots from yesterday with “paper seed envelope”"),
            .photos(.init(capturePeriod: .yesterday, recognizedText: phrase, media: .screenshots))
        )
        for question in [
            "Find the photo without \"paper seed envelope\"",
            "Find the photo not with \"paper seed envelope\"",
            "Find the photo with \"paper seed envelope\" or \"plant label\"",
            "Find the photo with \"paper seed envelope\" in Tokyo"
        ] {
            XCTAssertEqual(PhotoQuestion.explicitRequest(question), .unsupported, question)
        }
    }
    func testUnquotedWithSearchesTheWholePhrase() {
        let question = "Find the photo with paper seed envelope"
        let request = PhotoQueryRequest(recognizedText: "paper seed envelope")
        XCTAssertEqual(PhotoQuestion.explicitRequest(question), .photos(request))
        XCTAssertEqual(PhotoQuestion.explicitRequest(question + "?"), .photos(request))
        XCTAssertEqual(
            PhotoQuestion.explicitRequest("Find the screenshot with paper seed envelope"),
            .photos(.init(recognizedText: "paper seed envelope", media: .screenshots))
        )
        XCTAssertEqual(PhotoQuestion.explicitRequest(question + " from yesterday"), .unsupported)
        let rows = [
            photo("match", text: ["A paper seed", "envelope"]),
            photo("separate-words", text: ["Paper notes, seed samples, and an envelope"])
        ]
        XCTAssertEqual(PhotoQueryExecutor.execute(plan(request), in: rows).hits.map(\.id), ["match"])
    }
    func testExtraRestrictionsNegationAndCompoundPeriodsNeverBroaden() {
        for text in ["Find photos taken this week in Tokyo", "Find photos of red shoes taken this week", "Photos not containing \"key\"", "Photos containing \"a\" or \"b\"", "Photos this week or next week", "Photos since yesterday", "Photos from October", "Photos from 2025", "Find screenshots of shoes", "Photos containing \"key\" without people", "Photos containing violet lantern"] {
            XCTAssertEqual(PhotoQuestion.explicitRequest(text),.unsupported,text)
        }
    }
    func testAppointmentAndUnqualifiedObjectJourneysRemainSeparate() {
        XCTAssertNil(PhotoQuestion.explicitRequest("What appointments are there this week?"))
        XCTAssertNil(PhotoQuestion.explicitRequest("Find the yellow shoes"))
        XCTAssertNil(PhotoQuestion.explicitRequest("Find photos of yellow shoes"))
        XCTAssertTrue(PhotoQuestion.isExplicitObjectRecall("Find photos of yellow shoes"))
        XCTAssertTrue(PhotoQuestion.isExplicitObjectRecall("Show me pictures showing a lantern"))
        XCTAssertFalse(PhotoQuestion.isExplicitObjectRecall("What appointments are there this week?"))
        XCTAssertFalse(PhotoQuestion.isExplicitObjectRecall("Where is the second one?"))
        XCTAssertFalse(PhotoQuestion.isExplicitObjectRecall("Photos from last week"))
        XCTAssertFalse(PhotoQuestion.isExplicitObjectRecall("Find photos of shoes from last week"))
        XCTAssertEqual(PhotoQuestion.explicitRequest("Find photos today containing \"appointments tomorrow\""),.photos(.init(capturePeriod:.today,recognizedText:"appointments tomorrow")))
    }
    func testLegacyPhotoIntentCannotDiscardPopulatedConditions() {
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.photos,period:.all),now:now,calendar:calendar),.photos)
        for meaning in [MemoryQueryMeaning(intent:.photos,period:.thisWeek), .init(intent:.photos,period:.all,reference:.selected), .init(intent:.photos,period:.all,selection:.eventTickets)] {
            XCTAssertEqual(MemoryQueryCompiler.compile(meaning,now:now,calendar:calendar),.unsupported)
        }
    }
    func testStoreWithdrawalChangedSourceAndColdNoOpKeepQueryCurrent() async throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("memories.json")
        let store=try MemoryStore(file:file);let a=photo("a","2026-10-28T19:00:00Z",text:["key"]),b=photo("b","2026-10-28T19:00:00Z",text:["key"])
        let permit=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        try await store.upsert(a,permit:permit);try await store.upsert(b,permit:permit)
        let p=plan(.init(capturePeriod:.thisWeek,recognizedText:"key"));let first=await store.photos(matching:p);XCTAssertEqual(Set(first.hits.map(\.id)),["a","b"])
        try await store.forget(first.hits.first{$0.id=="a"}!);let after=await store.photos(matching:p);XCTAssertEqual(after.hits.map(\.id),["b"])
        let bytes=try Data(contentsOf:file);let cold=try MemoryStore(file:file)
        _=try await cold.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let reopened=await cold.photos(matching:p);XCTAssertEqual(reopened.hits.map(\.id),["b"]);XCTAssertEqual(try Data(contentsOf:file),bytes)
        _=try await cold.synchronizeSources([b.id:"b-v2"]);let changed=await cold.photos(matching:p);XCTAssertTrue(changed.hits.isEmpty)
    }
}
