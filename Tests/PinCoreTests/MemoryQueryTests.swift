import XCTest
@testable import PinCore

final class MemoryQueryTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from:"2026-10-25T16:30:00Z")!
    var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone=TimeZone(identifier:"America/Los_Angeles")!; c.firstWeekday=1; return c }
    func record(_ id:String, ticket:Bool = false) -> (PhotoMemory,AppointmentItem) {
        let m = PhotoMemory(id:id,fingerprint:"v1")
        var c = AppointmentCardReader.extract([CardLine("Appointment confirmed"),CardLine("Oct 26, 2026"),CardLine("1 PM")],sourceID:id,deviceTimeZone:calendar.timeZone)
        c.eventTicket=ticket
        return (m,AppointmentItem(source:AppointmentSource(m),observation:c))
    }
    func context() -> AppointmentConversationContext {
        let rows=[record("a"),record("b",ticket:true)]
        return AppointmentConversationContext(answerID:UUID(),answer:AppointmentAnswerEngine.answer(period:.thisWeek,now:now,calendar:calendar,items:rows.map(\.1),originals:rows.map(\.0),coverage:.readAvailablePhotos))
    }
    func testWeeklyPlanUsesNativeCalendar() {
        let p = MemoryQueryCompiler.compile(.init(intent:.appointments,period:.thisWeek),now:now,calendar:calendar)
        XCTAssertEqual(p,.appointments(window:AppointmentWindow.resolve(.thisWeek,now:now,calendar:calendar),selection:.any))
    }
    func testTicketConstraintIsAppliedAndDoesNotBroaden() {
        let rows=[record("eye"),record("ticket",ticket:true)]
        let result=AppointmentAnswerEngine.answer(window:.all,selection:.eventTickets,items:rows.map(\.1),originals:rows.map(\.0),coverage:.readAvailablePhotos)
        XCTAssertEqual(result.matches.map(\.id),["ticket"])
        let refused=AppointmentAnswerEngine.answer(window:.all,selection:.unsupported,items:rows.map(\.1),originals:rows.map(\.0),coverage:.readAvailablePhotos)
        XCTAssertTrue(refused.matches.isEmpty);XCTAssertEqual(refused.window,.unresolved)
    }
    func testAmbiguousOrUnsupportedAppointmentPlanHasNoPhotoFallback() {
        for (meaning,expected) in [
            (MemoryQueryMeaning(intent:.unclear,period:.all),MemoryQueryPlan.unclear),
            (.init(intent:.unsupported,period:.all),.unsupported),
            (.init(intent:.appointments,period:.unsupported),.needsDate),
            (.init(intent:.appointments,period:.all,selection:.unsupported),.unsupported),
            (.init(intent:.appointments,period:.all,reference:.second),.unsupported),
            (.init(intent:.appointments,period:.inherit),.needsContext)
        ] { XCTAssertEqual(MemoryQueryCompiler.compile(meaning,now:now,calendar:calendar),expected) }
    }
    func testLiteralPhotoSearchCannotBecomeAppointmentDateFilter() {
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.photos,period:.thisWeek),now:now,calendar:calendar),.unsupported)
    }
    func testSecondLocationRequiresPriorListAndValidOrdinal() {
        let q=MemoryQueryMeaning(intent:.appointmentLocation,period:.inherit,reference:.second)
        XCTAssertEqual(MemoryQueryCompiler.compile(q,now:now,calendar:calendar),.needsContext)
        XCTAssertEqual(MemoryQueryCompiler.compile(q,now:now,calendar:calendar,previous:context()),.appointmentLocation(ordinal:2))
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.appointmentLocation,period:.inherit,reference:.third),now:now,calendar:calendar,previous:context()),.needsContext)
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.appointmentLocation,period:.inherit,reference:.none),now:now,calendar:calendar,previous:context()),.needsContext)
    }
    func testSelectedLocationDoesNotGuessWhichOfTwo() {
        let q=MemoryQueryMeaning(intent:.appointmentLocation,period:.inherit,reference:.selected)
        XCTAssertEqual(MemoryQueryCompiler.compile(q,now:now,calendar:calendar,previous:context()),.needsContext)
        XCTAssertEqual(MemoryQueryCompiler.compile(q,now:now,calendar:calendar,previous:context(),selectedOrdinal:2),.appointmentLocation(ordinal:2))
        XCTAssertEqual(MemoryQueryCompiler.compile(q,now:now,calendar:calendar,previous:context(),selectedOrdinal:99),.needsContext)
    }
    func testInheritedWindowDoesNotDriftToNextWeek() {
        let prior=context(), future=now.addingTimeInterval(8*86400)
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.appointments,period:.inherit),now:future,calendar:calendar,previous:prior),.appointments(window:prior.window,selection:.any))
        XCTAssertNotEqual(prior.window,AppointmentWindow.resolve(.thisWeek,now:future,calendar:calendar))
    }
    func testTicketFilterSurvivesDateOnlyFollowupAndEmptyIntermediateAnswer() {
        let rows=[record("eye"),record("ticket",ticket:true)]
        let first=AppointmentAnswerEngine.answer(window:.all,selection:.eventTickets,items:rows.map(\.1),originals:rows.map(\.0),coverage:.incomplete)
        let prior=AppointmentConversationContext(answerID:UUID(),answer:first)
        let next=MemoryQueryCompiler.compile(.init(intent:.appointments,period:.today,selection:.inherit),now:now,calendar:calendar,previous:prior)
        guard case .appointments(let today,let selection)=next else { return XCTFail("Expected filtered list") }
        let empty=AppointmentAnswerEngine.answer(window:today,selection:selection,items:rows.map(\.1),originals:rows.map(\.0),coverage:.incomplete)
        XCTAssertTrue(empty.matches.isEmpty)
        XCTAssertEqual(empty.selection,.eventTickets)
        let emptyContext=AppointmentConversationContext(answerID:UUID(),answer:empty)
        let followup=MemoryQueryCompiler.compile(.init(intent:.appointments,period:.tomorrow,selection:.inherit),now:now,calendar:calendar,previous:emptyContext)
        guard case .appointments(let tomorrow,let retained)=followup else { return XCTFail("Empty results must retain the query scope") }
        let answer=AppointmentAnswerEngine.answer(window:tomorrow,selection:retained,items:rows.map(\.1),originals:rows.map(\.0),coverage:.incomplete)
        XCTAssertEqual(answer.matches.map(\.id),["ticket"])
        XCTAssertEqual(answer.selection,.eventTickets)
    }
    func testExplicitBroadeningReplacesTicketFilterForLaterFollowups() {
        let rows=[record("eye"),record("ticket",ticket:true)]
        let first=AppointmentAnswerEngine.answer(window:.all,selection:.eventTickets,items:rows.map(\.1),originals:rows.map(\.0),coverage:.readAvailablePhotos)
        let prior=AppointmentConversationContext(answerID:UUID(),answer:first)
        let broad=MemoryQueryCompiler.compile(.init(intent:.appointments,period:.inherit,selection:.any),now:now,calendar:calendar,previous:prior)
        guard case .appointments(let window,let selection)=broad else { return XCTFail("Expected explicit broadening") }
        let answer=AppointmentAnswerEngine.answer(window:window,selection:selection,items:rows.map(\.1),originals:rows.map(\.0),coverage:.readAvailablePhotos)
        XCTAssertEqual(answer.matches.map(\.id),["eye","ticket"])
        let updated=AppointmentConversationContext(answerID:UUID(),answer:answer)
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.appointments,period:.tomorrow,selection:.inherit),now:now,calendar:calendar,previous:updated),.appointments(window:AppointmentWindow.resolve(.tomorrow,now:now,calendar:calendar),selection:.any))
    }
    func testInheritedSelectionRequiresUsableContext() {
        let meaning=MemoryQueryMeaning(intent:.appointments,period:.tomorrow,selection:.inherit)
        XCTAssertEqual(MemoryQueryCompiler.compile(meaning,now:now,calendar:calendar),.needsContext)
        let refused=AppointmentAnswerEngine.answer(window:.all,selection:.unsupported,items:[],originals:[],coverage:.unknown)
        let context=AppointmentConversationContext(answerID:UUID(),answer:refused)
        XCTAssertEqual(MemoryQueryCompiler.compile(meaning,now:now,calendar:calendar,previous:context),.needsContext)
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.appointments,period:.inherit),now:now,calendar:calendar,previous:context),.needsDate)
    }
    func testInheritedFilterUsesCurrentSourcesAfterWithdrawal() {
        let eye=record("eye"),ticket=record("ticket",ticket:true),replacement=record("new-ticket",ticket:true)
        let first=AppointmentAnswerEngine.answer(window:.all,selection:.eventTickets,items:[eye.1,ticket.1],originals:[eye.0,ticket.0],coverage:.readAvailablePhotos)
        let previous=AppointmentConversationContext(answerID:UUID(),answer:first)
        let plan=MemoryQueryCompiler.compile(.init(intent:.appointments,period:.tomorrow,selection:.inherit),now:now,calendar:calendar,previous:previous)
        guard case .appointments(let window,let selection)=plan else { return XCTFail("Expected filtered current list") }
        let answer=AppointmentAnswerEngine.answer(window:window,selection:selection,items:[eye.1,ticket.1,replacement.1],originals:[eye.0,replacement.0],coverage:.readAvailablePhotos)
        XCTAssertEqual(answer.matches.map(\.id),["new-ticket"])
        XCTAssertEqual(previous.location(of:1,answerID:previous.answerID,items:[eye.1,ticket.1,replacement.1],originals:[eye.0,replacement.0]),.staleContext)
    }

    func testEquivalentPeriodOptionsShareOneNativeWindow() {
        let prior=context()
        let options=MemoryQueryPeriodOptions.aliases(now:now,calendar:calendar,previous:prior)
        XCTAssertEqual(options[.thisWeek],[.thisWeek,.inherit])
        XCTAssertNil(options[.inherit])
        for (canonical,aliases) in options where canonical != .unsupported {
            let a=MemoryQueryCompiler.compile(.init(intent:.appointments,period:canonical),now:now,calendar:calendar,previous:prior)
            for alias in aliases { XCTAssertEqual(a,MemoryQueryCompiler.compile(.init(intent:.appointments,period:alias),now:now,calendar:calendar,previous:prior)) }
        }
    }
    func testInheritedPeriodDoesNotMergeAfterWeekChanges() {
        let prior=context(),future=now.addingTimeInterval(8*86400)
        let options=MemoryQueryPeriodOptions.aliases(now:future,calendar:calendar,previous:prior)
        XCTAssertEqual(options[.inherit],[.inherit])
        XCTAssertEqual(options[.thisWeek],[.thisWeek])
        let withoutContext=MemoryQueryPeriodOptions.aliases(now:now,calendar:calendar)
        XCTAssertFalse(withoutContext.values.flatMap { $0 }.contains(.inherit))
    }

    func testPreviousResultSubsetDoesNotAdmitNewlyIndexedTicket() {
        let eye=record("eye"),ticket=record("ticket",ticket:true),later=record("later-ticket",ticket:true)
        let first=AppointmentAnswerEngine.answer(window:.all,items:[eye.1,ticket.1],originals:[eye.0,ticket.0],coverage:.incomplete)
        let previous=AppointmentConversationContext(answerID:UUID(),answer:first)
        let result=previous.subset(selection:.eventTickets,items:[eye.1,ticket.1,later.1],originals:[eye.0,ticket.0,later.0],coverage:.incomplete)
        guard case .answer(let answer)=result else { return XCTFail("Expected source-bound subset") }
        XCTAssertEqual(answer.matches.map(\.id),["ticket"])
        XCTAssertEqual(answer.selection,.eventTickets)
        let current=AppointmentAnswerEngine.answer(window:.all,selection:.eventTickets,items:[eye.1,ticket.1,later.1],originals:[eye.0,ticket.0,later.0],coverage:.incomplete)
        XCTAssertEqual(Set(current.matches.map(\.id)),Set(["ticket","later-ticket"]))
    }
    func testPreviousSubsetRefusesRevisedOrWithdrawnMembers() {
        let eye=record("eye"),ticket=record("ticket",ticket:true)
        let first=AppointmentAnswerEngine.answer(window:.all,items:[eye.1,ticket.1],originals:[eye.0,ticket.0],coverage:.readAvailablePhotos)
        let previous=AppointmentConversationContext(answerID:UUID(),answer:first)
        XCTAssertEqual(previous.subset(selection:.eventTickets,items:[eye.1,ticket.1],originals:[ticket.0],coverage:.unknown),.staleContext)
        var corrected=ticket.1;corrected.observation.venue="Corrected venue"
        XCTAssertEqual(previous.subset(selection:.eventTickets,items:[eye.1,corrected],originals:[eye.0,ticket.0],coverage:.unknown),.staleContext)
        XCTAssertEqual(previous.subset(selection:.unsupported,items:[eye.1,ticket.1],originals:[eye.0,ticket.0],coverage:.unknown),.unsupported)
    }
    func testEmptyPreviousSubsetStaysEmptyAfterNewRead() {
        let initial=AppointmentAnswerEngine.answer(window:.all,selection:.eventTickets,items:[],originals:[],coverage:.incomplete)
        let previous=AppointmentConversationContext(answerID:UUID(),answer:initial),new=record("new",ticket:true)
        guard case .answer(let result)=previous.subset(items:[new.1],originals:[new.0],coverage:.incomplete) else { return XCTFail("Empty source set is still a valid subset") }
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.selection,.eventTickets)
        XCTAssertFalse(result.canAssertPersonalCalendarIsEmpty)
    }

    func testSubsetPlanBindsPriorAnswerAndExecutesOnlyItsMembers() {
        let eye=record("eye"), ticket=record("ticket",ticket:true), new=record("new",ticket:true)
        let initial=AppointmentAnswerEngine.answer(window:.all,items:[eye.1,ticket.1],originals:[eye.0,ticket.0],coverage:.incomplete)
        let previous=AppointmentConversationContext(answerID:UUID(),answer:initial)
        let meaning=MemoryQueryMeaning(intent:.appointmentSubset,period:.inherit,selection:.eventTickets)
        let plan=MemoryQueryCompiler.compile(meaning,now:now,calendar:calendar,previous:previous)
        XCTAssertEqual(plan,.appointmentSubset(answerID:previous.answerID,window:.all,selection:.eventTickets))
        guard case .answer(let filtered)=MemoryQueryExecutor.appointments(plan,previous:previous,items:[eye.1,ticket.1,new.1],originals:[eye.0,ticket.0,new.0],coverage:.incomplete) else { return XCTFail("Expected previous members") }
        XCTAssertEqual(filtered.matches.map(\.id),["ticket"])
        let fresh=MemoryQueryCompiler.compile(.init(intent:.appointments,period:.inherit,selection:.eventTickets),now:now,calendar:calendar,previous:previous)
        guard case .answer(let current)=MemoryQueryExecutor.appointments(fresh,previous:previous,items:[eye.1,ticket.1,new.1],originals:[eye.0,ticket.0,new.0],coverage:.incomplete) else { return XCTFail("Expected current inventory") }
        XCTAssertEqual(Set(current.matches.map(\.id)),Set(["ticket","new"]))
        let replacement=AppointmentConversationContext(answerID:UUID(),answer:initial)
        XCTAssertEqual(MemoryQueryExecutor.appointments(plan,previous:replacement,items:[eye.1,ticket.1],originals:[eye.0,ticket.0],coverage:.unknown),.staleContext)
        XCTAssertEqual(MemoryQueryExecutor.appointments(plan,items:[eye.1,ticket.1],originals:[eye.0,ticket.0],coverage:.unknown),.staleContext)
    }
    func testSubsetPlanRetainsFilterButResolvesNewDayNatively() {
        let ticket=record("ticket",ticket:true)
        let previous=AppointmentConversationContext(answerID:UUID(),answer:AppointmentAnswerEngine.answer(window:.all,selection:.eventTickets,items:[ticket.1],originals:[ticket.0],coverage:.unknown))
        let plan=MemoryQueryCompiler.compile(.init(intent:.appointmentSubset,period:.today,selection:.inherit),now:now,calendar:calendar,previous:previous)
        XCTAssertEqual(plan,.appointmentSubset(answerID:previous.answerID,window:AppointmentWindow.resolve(.today,now:now,calendar:calendar),selection:.eventTickets))
        guard case .answer(let result)=MemoryQueryExecutor.appointments(plan,previous:previous,items:[ticket.1],originals:[ticket.0],coverage:.unknown) else { return XCTFail("Expected filtered prior list") }
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.selection,.eventTickets)
        var dismissed=ticket.1;dismissed.dismissed=true
        XCTAssertEqual(MemoryQueryExecutor.appointments(plan,previous:previous,items:[dismissed],originals:[ticket.0],coverage:.unknown),.staleContext)
    }
    func testSubsetMissingContextOrUnsupportedConstraintCannotBroaden() {
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.appointmentSubset,period:.all),now:now,calendar:calendar),.needsContext)
        for meaning in [MemoryQueryMeaning(intent:.appointmentSubset,period:.inherit,selection:.unsupported),.init(intent:.appointmentSubset,period:.inherit,reference:.second)] {
            XCTAssertEqual(MemoryQueryCompiler.compile(meaning,now:now,calendar:calendar,previous:context()),.unsupported)
        }
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.appointmentSubset,period:.unsupported),now:now,calendar:calendar,previous:context()),.needsDate)
        XCTAssertEqual(MemoryQueryExecutor.appointments(.photos,items:[],originals:[],coverage:.unknown),.unsupported)
    }
    func testExistingProviderMeaningKeepsFreshQuerySemantics() throws {
        let json=Data(#"{"intent":"appointments","period":"thisWeek","reference":"none","selection":"any"}"#.utf8)
        let meaning=try JSONDecoder().decode(MemoryQueryMeaning.self,from:json)
        XCTAssertEqual(MemoryQueryCompiler.compile(meaning,now:now,calendar:calendar,previous:context()),.appointments(window:AppointmentWindow.resolve(.thisWeek,now:now,calendar:calendar),selection:.any))
    }

}

extension MemoryQueryTests {
    func testExplicitUpdatePreservesNativeWindowAndKindWhileAdmittingNewCurrentMatches() throws {
        let old=record("old",ticket:true), new=record("new",ticket:true), eye=record("eye")
        let window=AppointmentWindow.resolve(.thisWeek,now:now,calendar:calendar)
        let answer=AppointmentAnswerEngine.answer(window:window,selection:.eventTickets,items:[old.1],originals:[old.0],coverage:.unknown)
        let update=try XCTUnwrap(AppointmentAnswerUpdate(plan:.appointments(window:window,selection:.eventTickets),answer:answer,now:now,calendar:calendar))
        let next=try XCTUnwrap(update.answer(now:now,calendar:calendar,items:[new.1,eye.1],originals:[new.0,eye.0],coverage:.incomplete))
        XCTAssertEqual(next.matches.map(\.id),["new"])
        XCTAssertEqual(next.window,window); XCTAssertEqual(next.selection,.eventTickets)
        XCTAssertEqual(next.coverage,.incomplete)
    }
    func testExplicitSubsetUpdateDropsWithdrawnAndChangedMembersWithoutAdmittingNewRecords() throws {
        let a=record("a",ticket:true), b=record("b",ticket:true), c=record("c",ticket:true), d=record("new",ticket:true)
        let window=AppointmentWindow.resolve(.thisWeek,now:now,calendar:calendar)
        let answer=AppointmentAnswerEngine.answer(window:window,selection:.eventTickets,items:[a.1,b.1,c.1],originals:[a.0,b.0,c.0],coverage:.unknown)
        let update=try XCTUnwrap(AppointmentAnswerUpdate(plan:.appointmentSubset(answerID:UUID(),window:window,selection:.eventTickets),answer:answer,now:now,calendar:calendar))
        var changed=b.1; changed.observation.venue="Replacement venue"
        var live=c.1; live.remindersApproved=true
        let next=try XCTUnwrap(update.answer(now:now,calendar:calendar,items:[changed,live,d.1],originals:[b.0,c.0,d.0],coverage:.unknown))
        XCTAssertEqual(next.matches.map(\.id),["c"])
        XCTAssertTrue(next.matches[0].remindersApproved)
        let empty=try XCTUnwrap(update.answer(now:now,calendar:calendar,items:[d.1],originals:[d.0],coverage:.unknown))
        XCTAssertTrue(empty.matches.isEmpty)
    }
    func testExplicitUpdateDoesNotChangeOldOrdinalContext() throws {
        var a=record("a"), b=record("b")
        a.1.observation.venue="First"; b.1.observation.venue="Second"
        let window=AppointmentWindow.resolve(.thisWeek,now:now,calendar:calendar)
        let answer=AppointmentAnswerEngine.answer(window:window,items:[a.1,b.1],originals:[a.0,b.0],coverage:.unknown)
        let old=AppointmentConversationContext(answerID:UUID(),answer:answer)
        let update=try XCTUnwrap(AppointmentAnswerUpdate(plan:.appointments(window:window,selection:.any),answer:answer,now:now,calendar:calendar))
        let next=try XCTUnwrap(update.answer(now:now,calendar:calendar,items:[b.1],originals:[b.0],coverage:.unknown))
        XCTAssertEqual(old.location(of:1,answerID:old.answerID,items:[b.1],originals:[b.0]),.staleContext)
        let new=AppointmentConversationContext(answerID:UUID(),answer:next)
        XCTAssertNotEqual(old.answerID,new.answerID)
        XCTAssertEqual(new.location(of:1,answerID:new.answerID,items:[b.1],originals:[b.0]),.location(source:b.1.source,venue:"Second",address:nil))
    }
    func testExplicitUpdateExpiresOnCalendarDayOrTimezoneChange() throws {
        let a=record("a"), window=AppointmentWindow.resolve(.thisWeek,now:now,calendar:calendar)
        let answer=AppointmentAnswerEngine.answer(window:window,items:[a.1],originals:[a.0],coverage:.unknown)
        let update=try XCTUnwrap(AppointmentAnswerUpdate(plan:.appointments(window:window,selection:.any),answer:answer,now:now,calendar:calendar))
        XCTAssertNil(update.answer(now:calendar.date(byAdding:.day,value:1,to:now)!,calendar:calendar,items:[a.1],originals:[a.0],coverage:.unknown))
        var changed=calendar; changed.timeZone=TimeZone(identifier:"Europe/London")!
        XCTAssertNil(update.answer(now:now,calendar:changed,items:[a.1],originals:[a.0],coverage:.unknown))
    }
    func testCannotCreateUpdateForUnresolvedOrMismatchedOperation() {
        let a=record("a"), window=AppointmentWindow.resolve(.thisWeek,now:now,calendar:calendar)
        let answer=AppointmentAnswerEngine.answer(window:window,items:[a.1],originals:[a.0],coverage:.unknown)
        for plan in [MemoryQueryPlan.photos,.unsupported,.appointmentLocation(ordinal:1),.appointments(window:.unresolved,selection:.any),.appointments(window:window,selection:.eventTickets)] {
            XCTAssertNil(AppointmentAnswerUpdate(plan:plan,answer:answer,now:now,calendar:calendar))
        }
    }
    func testContextPreservingLocationProposalKeepsExactSecondSourceAndWithdrawalFence() {
        var first=record("eye"), second=record("ticket",ticket:true)
        first.1.observation.venue="Eye Clinic"; second.1.observation.venue="Event Hall"
        let rows=[first.1,second.1], originals=[first.0,second.0]
        let answer=AppointmentAnswerEngine.answer(window:.all,items:rows,originals:originals,coverage:.incomplete)
        let prior=AppointmentConversationContext(answerID:UUID(),answer:answer)
        let observed=MemoryQueryMeaning(intent:.appointmentLocation,period:.inherit,reference:.second,selection:.inherit)
        XCTAssertEqual(MemoryQueryCompiler.compile(observed,now:now,calendar:calendar,previous:prior),.appointmentLocation(ordinal:2))
        XCTAssertEqual(prior.location(of:2,answerID:prior.answerID,items:rows,originals:originals),.location(source:second.1.source,venue:"Event Hall",address:nil))
        XCTAssertEqual(prior.location(of:2,answerID:prior.answerID,items:[first.1],originals:[first.0]),.staleContext)
        XCTAssertEqual(MemoryQueryCompiler.compile(observed,now:now,calendar:calendar),.needsContext)
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.appointmentLocation,period:.tomorrow,reference:.second,selection:.inherit),now:now,calendar:calendar,previous:prior),.needsContext)
        XCTAssertEqual(MemoryQueryCompiler.compile(.init(intent:.appointmentLocation,period:.inherit,reference:.second,selection:.eventTickets),now:now,calendar:calendar,previous:prior),.unsupported)
    }

}


extension MemoryQueryTests {
    func ticketContext(_ rows:[(PhotoMemory,AppointmentItem)]) -> AppointmentConversationContext {
        AppointmentConversationContext(answerID:UUID(),answer:AppointmentAnswerEngine.answer(window:.all,
            selection:.eventTickets,items:rows.map(\.1),originals:rows.map(\.0),coverage:.unknown))
    }
    func pendingScope(_ meaning:MemoryQueryMeaning, rows:[(PhotoMemory,AppointmentItem)], previous:AppointmentConversationContext,
                      question:String = "Do I have anything today?", evidence:AppointmentScopeEvidence? = nil,
                      id:UUID = UUID()) -> AppointmentScopeAdmission {
        AppointmentScopeAdmission.resolve(meaning,evidence:evidence,question:question,requestID:id,now:now,calendar:calendar,
            previous:previous,items:rows.map(\.1),originals:rows.map(\.0))
    }
    func testRetainedAmbiguousBroadeningRequiresChoiceAndKeepsRequestedWindow() {
        let rows=[record("eye"),record("ticket",ticket:true)],prior=ticketContext(rows),id=UUID()
        let meaning=MemoryQueryMeaning(intent:.appointments,period:.tomorrow,selection:.any)
        guard case .clarify(let pending)=pendingScope(meaning,rows:rows,previous:prior,id:id) else { return XCTFail("Must not broaden") }
        let window=AppointmentWindow.resolve(.tomorrow,now:now,calendar:calendar)
        XCTAssertEqual(pending.window,window)
        for choice in [AppointmentSelection.any,.eventTickets] {
            let plan=pending.resolve(choice,requestID:id,previous:prior,now:now,calendar:calendar,items:rows.map(\.1),originals:rows.map(\.0))
            XCTAssertEqual(plan,.appointments(window:window,selection:choice))
            guard let plan,case .answer(let answer)=MemoryQueryExecutor.appointments(plan,previous:prior,items:rows.map(\.1),originals:rows.map(\.0),coverage:.unknown) else { return XCTFail("Chosen answer") }
            XCTAssertEqual(answer.matches.map(\.id),choice == .any ? ["eye","ticket"] : ["ticket"])
        }
    }
    func testExplicitBroadeningRequiresCurrentQuestionEvidence() {
        let rows=[record("eye"),record("ticket",ticket:true)],prior=ticketContext(rows)
        let meaning=MemoryQueryMeaning(intent:.appointments,period:.tomorrow,selection:.any)
        for (q,words) in [
            ("Show all appointments tomorrow.",["all appointments"]),
            ("Show all my appointments tomorrow.",["all my appointments"]),
            ("Include ordinary appointments as well as ticketed events tomorrow.",["ordinary appointments as well as ticketed events"]),
            ("What appointments and ticketed events are there tomorrow?",["appointments and ticketed events"]),
            ("Show every appointment kind tomorrow.",["every appointment kind"]),
            ("Show all bookings tomorrow.",["all bookings"]),
            ("Show all appointments tomorrow.",["tomorrow"])
        ] {
            guard case .plan(let plan)=pendingScope(meaning,rows:rows,previous:prior,question:q,evidence:.init(basis:.explicit,words:words)) else { return XCTFail("Supported explicit scope: \(q)") }
            XCTAssertEqual(plan,.appointments(window:AppointmentWindow.resolve(.tomorrow,now:now,calendar:calendar),selection:.any))
        }
        // The proposal may cite the date while the person's own request
        // explicitly names both kinds of appointment.
        let nextWeek=MemoryQueryMeaning(intent:.appointments,period:.nextWeek,selection:.any)
        guard case .plan(let datedPlan)=pendingScope(nextWeek,rows:rows,previous:prior,
            question:"Include ordinary appointments as well as ticketed events next week.",
            evidence:.init(basis:.explicit,words:["next week"])) else { return XCTFail("Explicit scope with a date citation") }
        XCTAssertEqual(datedPlan,.appointments(window:AppointmentWindow.resolve(.nextWeek,now:now,calendar:calendar),selection:.any))
        for words in [[],[" "] ,["all appointments"],["Show all appointments tomorrow."]] {
            guard case .clarify = pendingScope(meaning,rows:rows,previous:prior,evidence:.init(basis:.explicit,words:words)) else { return XCTFail("Evidence cannot come from another question") }
        }
        for (q,words) in [
            ("Do I have anything today?",["anything"]),
            ("What appointments do I have tomorrow?",["appointments"]),
            ("Show all tickets tomorrow.",["all tickets"]),
            ("Show all commitments tomorrow.",["all commitments"]),
            ("Do not show all appointments; only tickets tomorrow.",["all appointments"]),
            ("Show all appointments except tickets tomorrow.",["all appointments"]),
            ("The screenshot says \"all appointments\"; show tickets tomorrow.",["tomorrow"]),
            ("The card says “appointments and tickets”; show tickets tomorrow.",["tomorrow"])
        ] {
            guard case .clarify = pendingScope(meaning,rows:rows,previous:prior,question:q,evidence:.init(basis:.explicit,words:words)) else { return XCTFail("A model label alone must not broaden: \(q)") }
        }
        guard case .clarify = pendingScope(meaning,rows:rows,previous:prior,evidence:.init(basis:.ambiguous,words:[])) else { return XCTFail("Ambiguity must remain") }
    }
    func testPendingScopeCannotSurviveChangedEvidenceQuestionOrCalendar() {
        let rows=[record("eye"),record("ticket",ticket:true)],prior=ticketContext(rows),id=UUID()
        guard case .clarify(let pending)=pendingScope(.init(intent:.appointments,period:.thisWeek),rows:rows,previous:prior,id:id) else { return XCTFail() }
        let items=rows.map(\.1),originals=rows.map(\.0)
        XCTAssertNil(pending.resolve(.any,requestID:UUID(),previous:prior,now:now,calendar:calendar,items:items,originals:originals))
        XCTAssertNil(pending.resolve(.any,requestID:id,previous:ticketContext(rows),now:now,calendar:calendar,items:items,originals:originals))
        XCTAssertNil(pending.resolve(.any,requestID:id,previous:prior,now:now.addingTimeInterval(86400),calendar:calendar,items:items,originals:originals))
        var other=calendar;other.timeZone=TimeZone(secondsFromGMT:0)!
        XCTAssertNil(pending.resolve(.any,requestID:id,previous:prior,now:now,calendar:other,items:items,originals:originals))
        XCTAssertNil(pending.resolve(.any,requestID:id,previous:prior,now:now,calendar:calendar,items:[items[0]],originals:[originals[0]]))
        var changed=items;changed[1].observation.venue="Corrected Hall"
        XCTAssertNil(pending.resolve(.any,requestID:id,previous:prior,now:now,calendar:calendar,items:changed,originals:originals))
        XCTAssertNil(pending.resolve(.unsupported,requestID:id,previous:prior,now:now,calendar:calendar,items:items,originals:originals))
    }
    func testScopeChoiceKeepsFixedMembershipAndCannotAdmitNewTicket() {
        let rows=[record("eye"),record("ticket",ticket:true),record("new",ticket:true)]
        let prior=ticketContext(Array(rows.prefix(2))),id=UUID()
        guard case .clarify(let pending)=pendingScope(.init(intent:.appointmentSubset,period:.inherit,selection:.any),rows:rows,previous:prior,id:id) else { return XCTFail() }
        guard let plan=pending.resolve(.any,requestID:id,previous:prior,now:now,calendar:calendar,items:rows.map(\.1),originals:rows.map(\.0)),
              case .answer(let answer)=MemoryQueryExecutor.appointments(plan,previous:prior,items:rows.map(\.1),originals:rows.map(\.0),coverage:.unknown) else { return XCTFail() }
        XCTAssertEqual(plan,.appointmentSubset(answerID:prior.answerID,window:.all,selection:.any))
        XCTAssertEqual(answer.matches.map(\.id),["ticket"])
        XCTAssertNil(AppointmentScopeClarification(plan:.appointments(window:.all,selection:.unsupported),requestID:id,now:now,calendar:calendar,previous:prior,items:rows.map(\.1),originals:rows.map(\.0)))
        XCTAssertNil(AppointmentScopeClarification(plan:.appointmentSubset(answerID:prior.answerID,window:.all,selection:.unsupported),requestID:id,now:now,calendar:calendar,previous:prior,items:rows.map(\.1),originals:rows.map(\.0)))
    }
    func testScopeAdmissionDoesNotAlterIndependentOrInheritedOperations() {
        let rows=[record("eye"),record("ticket",ticket:true)],prior=ticketContext(rows)
        for meaning in [MemoryQueryMeaning(intent:.photos,period:.all),.init(intent:.appointmentLocation,period:.inherit,reference:.first),.init(intent:.appointments,period:.today,selection:.inherit),.init(intent:.unsupported,period:.all),.init(intent:.appointments,period:.unsupported)] {
            guard case .plan(let p)=pendingScope(meaning,rows:rows,previous:prior) else { return XCTFail("Unrelated operation") }
            XCTAssertEqual(p,MemoryQueryCompiler.compile(meaning,now:now,calendar:calendar,previous:prior))
        }
        let m=MemoryQueryMeaning(intent:.appointments,period:.thisWeek)
        guard case .plan(let p)=AppointmentScopeAdmission.resolve(m,question:"What appointments this week?",requestID:UUID(),now:now,calendar:calendar,items:rows.map(\.1),originals:rows.map(\.0)) else { return XCTFail("Fresh question has no prior scope") }
        XCTAssertEqual(p,.appointments(window:AppointmentWindow.resolve(.thisWeek,now:now,calendar:calendar),selection:.any))
    }
}


extension MemoryQueryTests {
    func testScopeEvidenceCannotDiscardUnsupportedProviderCondition() {
        let rows=[record("eye"),record("ticket",ticket:true)],previous=ticketContext(rows)
        let proposal=MemoryQueryProposal(meaning:.init(intent:.appointments,period:.tomorrow,selection:.any),
            scope:.init(basis:.explicit,words:["all appointments"]),qualifiers:[.init(words:"at Example Vision",facet:.provider)])
        guard case .plan(let plan)=proposal.admission(question:"Show all appointments at Example Vision tomorrow.",requestID:UUID(),now:now,calendar:calendar,previous:previous,items:rows.map(\.1),originals:rows.map(\.0)) else {return XCTFail("Condition must not become scope choice")}
        XCTAssertEqual(plan,.unsupported)
    }
    func testProposalMissingContextAndInventedRestrictionCannotExecute() {
        let rows=[record("eye"),record("ticket",ticket:true)]
        var proposal=MemoryQueryProposal(meaning:.init(intent:.appointments,period:.tomorrow,selection:.inherit),scope:.init(basis:.inherited,words:["tomorrow"]),requiresPreviousContext:true)
        guard case .plan(let missing)=proposal.admission(question:"And tomorrow?",requestID:UUID(),now:now,calendar:calendar,previous:nil,items:rows.map(\.1),originals:rows.map(\.0)) else {return XCTFail()}
        XCTAssertEqual(missing,.needsContext)
        proposal.qualifiers=[.init(words:"not in this question",facet:.other)]
        guard case .plan(let invalid)=proposal.admission(question:"And tomorrow?",requestID:UUID(),now:now,calendar:calendar,previous:ticketContext(rows),items:rows.map(\.1),originals:rows.map(\.0)) else {return XCTFail()}
        XCTAssertEqual(invalid,.unclear)
    }
}
