import XCTest
@testable import PinCore
final class AppointmentContextTests: XCTestCase {
    let zone=TimeZone(identifier:"America/Los_Angeles")!
    func at(_ text:String)->Date { ISO8601DateFormatter().date(from:text)! }
    func read(_ text:[String],captured:String?="2026-10-06T20:00:00Z",screenshot:Bool?=true)->AppointmentObservation {
        AppointmentCardReader.extract(text.map { CardLine($0) },sourceID:"fictional",deviceTimeZone:zone,photographedAt:captured.map(at),isScreenshot:screenshot)
    }
    let eye=["Appointment confirmed","Example Vision","Wed, Oct 7","1 PM"]
    func testScreenshotYearIsUsefulAndExplicitlyInferred() {
        let value=read(eye)
        XCTAssertEqual(value.inferredYear,2026);XCTAssertEqual(value.date,at("2026-10-07T20:00:00Z"))
        XCTAssertEqual(value.yearBasisDate,at("2026-10-06T20:00:00Z"));XCTAssertEqual(value.printedDate,"Wed, Oct 7")
        XCTAssertTrue(value.reviewReason?.contains("inferred") == true)
        let facts=AppointmentCardReader.facts(for:value,source:EvidenceSource(id:"fictional",fingerprint:"v1",revision:1))
        XCTAssertEqual(facts.first { $0.field == "inferredYear" }?.origin,.inferred)
        XCTAssertEqual(facts.first { $0.field == "inferredYear" }?.support.first?.text,"Wed, Oct 7")
    }
    func testBookingScreenshotUsesBranchAndBulletedVisitDetails() {
        let lines=["SAMPLEVISION", "Your appointment has been booked!", "SampleVision Bellevue",
            "• Wed, Oct 7 - 1:00 PM", "• Medical Visit- Self Pay or Billed to", "Insurance",
            "• SampleVision Bellevue/Seattle"]
        let value=read(lines,captured:"2026-09-28T23:29:05Z")
        XCTAssertEqual(value.date,at("2026-10-07T20:00:00Z"))
        XCTAssertEqual(value.inferredYear,2026)
        XCTAssertEqual(value.provider,"SampleVision Bellevue")
        XCTAssertEqual(value.service,"Medical Visit")
        XCTAssertEqual(value.venue,"SampleVision Bellevue/Seattle")
    }
    func testDecemberScreenshotCanReferToJanuaryNextYear() {
        let c=read(["Appointment confirmed","Jan 4","1 PM"],captured:"2026-12-28T20:00:00Z")
        XCTAssertEqual(c.inferredYear,2027);XCTAssertEqual(c.date,at("2027-01-04T21:00:00Z"))
    }
    func testJanuaryScreenshotCanReferToDecemberPreviousYear() {
        XCTAssertEqual(read(["Appointment confirmed","Dec 30","1 PM"],captured:"2027-01-02T20:00:00Z").inferredYear,2026)
    }
    func testExplicitYearWinsEvenWhenPhotoIsYearsNewer() {
        let c=read(["Appointment confirmed","Oct 7, 2024","1 PM"])
        XCTAssertNil(c.inferredYear);XCTAssertNil(c.yearBasisDate);XCTAssertEqual(c.date,at("2024-10-07T20:00:00Z"))
    }
    func testMissingMetadataAndOrdinaryPhotoDoNotImplyEventYear() {
        XCTAssertNil(read(eye,captured:nil).date);XCTAssertNil(read(eye,screenshot:false).inferredYear)
        XCTAssertNil(read(eye,screenshot:nil).inferredYear)
    }
    func testConflictingWeekdayDoesNotSearchDistantYearToFit() {
        let c=read(["Appointment confirmed","Monday, Oct 7","1 PM"])
        XCTAssertNil(c.inferredYear);XCTAssertNil(c.date);XCTAssertTrue(c.reviewReason?.contains("weekday") == true)
    }
    func testServiceWindowStillGetsInferredYearWithoutInventingExactTime() {
        let c=read(["Your appointment is coming up","Friday, Sep 18","8:30 AM – 12:00 PM PDT"])
        XCTAssertEqual(c.inferredYear,2026);XCTAssertNil(c.date);XCTAssertTrue(c.reviewReason?.contains("window") == true)
    }
    func testLowConfidenceDateAndImpossibleDayDoNotInfer() {
        let c=AppointmentCardReader.extract([CardLine("Appointment confirmed"),CardLine("Oct 7",confidence:0.4),CardLine("1 PM")],sourceID:"fictional",deviceTimeZone:zone,photographedAt:at("2026-10-06T20:00:00Z"),isScreenshot:true)
        XCTAssertNil(c.inferredYear);XCTAssertNil(read(["Appointment confirmed","Feb 30","1 PM"],captured:"2026-02-01T20:00:00Z").date)
    }
    func testInferredYearDoesNotAutomaticallyAuthorizeReminderOrConfirmedToday() {
        let memory=PhotoMemory(id:"fictional",fingerprint:"v1")
        var item=AppointmentItem(source:AppointmentSource(memory),observation:read(eye));item.remindersApproved=true
        XCTAssertTrue(AppointmentReminderPlanner.plan(item,now:at("2026-10-01T20:00:00Z")).isEmpty)
        XCTAssertFalse(AppointmentQuestion.isToday(item.observation,now:at("2026-10-07T17:00:00Z"),calendar:.current))
    }
    func ticketLines()->[CardLine] {
        func line(_ t:String,_ x:Double,_ y:Double,_ h:Double)->CardLine { CardLine(t,region:EvidenceRegion(x:x,y:y,width:0.3,height:h)) }
        return [line("3:00 PM",0.6,0.92,0.022),line("Oct 26, 2026",0.6,0.87,0.035),line("#Example Week Open...",0.1,0.76,0.04),line("Location",0.1,0.71,0.02),line("Example Hall",0.1,0.68,0.022),line("Guest",0.1,0.6,0.02),line("Ticket",0.6,0.6,0.02),line("October 16",0.6,0.74,0.007),line("7:00 PM",0.6,0.72,0.007)]
    }
    func testWalletTicketUsesPrimaryScheduleInsteadOfTinyPosterOCR() {
        let c=AppointmentCardReader.extract(ticketLines(),sourceID:"fictional",deviceTimeZone:zone)
        XCTAssertTrue(c.eventTicket == true);XCTAssertEqual(c.title,"#Example Week Open...");XCTAssertEqual(c.venue,"Example Hall")
        XCTAssertEqual(c.date,at("2026-10-26T22:00:00Z"));XCTAssertNil(c.reviewReason)
        XCTAssertEqual(c.printedDate,"Oct 26, 2026");XCTAssertEqual(c.printedTime,"3:00 PM")
    }
    func testPhotographedTicketUsesAdjacentLocationWhenOCRGeometryIsRotated() {
        func line(_ text:String,_ x:Double,_ y:Double,_ h:Double)->CardLine {
            CardLine(text,region:EvidenceRegion(x:x,y:y,width:0.3,height:h))
        }
        let lines=[line("Event Ticket",0.1,0.96,0.03),line("3:00 PM",0.6,0.92,0.022),
            line("Oct 26, 2026",0.6,0.87,0.035),line("#ExampleWeek Open...",0.1,0.76,0.04),
            line("Location",0.29,0.17,0.10),line("Example Hall",0.31,0.17,0.11),
            line("Guest",0.1,0.10,0.02),line("Ticket",0.6,0.10,0.02)]
        let value=AppointmentCardReader.extract(lines,sourceID:"fictional",deviceTimeZone:zone)
        XCTAssertEqual(value.venue,"Example Hall")
        XCTAssertEqual(value.date,at("2026-10-26T22:00:00Z"))
    }
    func testTicketWithoutGeometryKeepsConflictingDatesUnresolved() {
        XCTAssertNil(read(ticketLines().map(\.text)).date)
    }
    func testTicketAdmissionNeedsEventContextAndSchedule() {
        XCTAssertTrue(AppointmentCardReader.isCandidate(["Event ticket","Event: Example concert","Oct 26, 2026","3 PM"]))
        for text in [["Ticket #3","Parking receipt","Oct 26, 2026","3 PM"],["Buy tickets","Oct 26, 2026","3 PM"],["Event ticket","No date"]] { XCTAssertFalse(AppointmentCardReader.isCandidate(text)) }
        XCTAssertEqual(AppointmentQuestion.intent("my tickets"),.bookings)
    }
    func testPlainEventTicketReadsLabelledEventAndVenue() {
        let c=read(["Event ticket","Event: Example concert","Location: Example Hall","Oct 26, 2026","3 PM"])
        XCTAssertEqual(c.title,"Example concert");XCTAssertEqual(c.venue,"Example Hall");XCTAssertNotNil(c.date)
    }
    func testOldObservationWithoutContextFieldsStillDecodes() throws {
        let c=read(eye);var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(c)) as! [String:Any]
        for key in ["inferredYear","yearBasisDate","eventTicket"] { object.removeValue(forKey:key) }
        let old=try JSONDecoder().decode(AppointmentObservation.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(old.inferredYear);XCTAssertNil(old.yearBasisDate);XCTAssertNil(old.eventTicket)
    }
    func testRenderedTicketAnswerCannotBecomeAnotherTicket() {
        let text=["EVENT TICKET","#Example Week Opening","Mon, Oct 26, 2026 · 3:00 PM","From this photo","Original card","Tickets"]
        XCTAssertTrue(AppointmentCardReader.isPinInterface(text));XCTAssertFalse(AppointmentCardReader.isCandidate(text))
    }

}
