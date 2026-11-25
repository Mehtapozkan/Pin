import XCTest
@testable import PinCore

final class MemoryQueryOptionsTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-25T16:30:00Z")!
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; c.firstWeekday = 1; return c }
    func prior(count: Int, selection: AppointmentSelection = .any) -> AppointmentConversationContext {
        let rows = (0..<count).map { i -> (PhotoMemory, AppointmentItem) in
            let m = PhotoMemory(id: "fictional-secret-source-\(i)", fingerprint: "v1")
            var o = AppointmentCardReader.extract([CardLine("Appointment confirmed"), CardLine("Oct 26, 2026"), CardLine("1 PM")], sourceID: m.id, deviceTimeZone: calendar.timeZone)
            o.eventTicket = true
            return (m, AppointmentItem(source: AppointmentSource(m), observation: o))
        }
        return .init(answerID: UUID(), answer: AppointmentAnswerEngine.answer(period: .thisWeek, now: now, calendar: calendar, items: rows.map(\.1), originals: rows.map(\.0), coverage: .unknown).withSelectionForTest(selection))
    }
    func json(_ descriptor: AppointmentQueryDescription) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(descriptor)) as! [String: Any]
    }
    func testLocationDescriptionHasOnlyTheBoundOrdinalAndNoListFilters() throws {
        let context = prior(count: 2, selection: .eventTickets)
        let option = try XCTUnwrap(MemoryQueryOptions.make(now: now, calendar: calendar, previous: context).first { $0.id == "location_second" })
        let descriptor = try XCTUnwrap(option.appointmentDescription)
        XCTAssertEqual(descriptor, .location(previousResultOrdinal: 2))
        let encoded = try json(descriptor)
        XCTAssertEqual(Set(encoded.keys), ["location"])
        let location = try XCTUnwrap(encoded["location"] as? [String: Any])
        XCTAssertEqual(Set(location.keys), ["previousResultOrdinal"])
        XCTAssertEqual(location["previousResultOrdinal"] as? Int, 2)
        XCTAssertNil(location["kind"]); XCTAssertNil(location["providerFilter"])
    }
    func testListDescriptionPreservesNativeWindowMembershipAndActualKind() throws {
        let context = prior(count: 2), options = MemoryQueryOptions.make(now: now, calendar: calendar, previous: context)
        let fresh = try XCTUnwrap(options.first { $0.id == "list_thisWeek_eventTickets" })
        let subset = try XCTUnwrap(options.first { $0.id == "subset_thisWeek_eventTickets" })
        guard case .interval(let interval) = context.window else { return XCTFail() }
        let window = AppointmentQueryDescription.Window.interval(start: interval.start, endExclusive: interval.end)
        XCTAssertEqual(fresh.appointmentDescription, .list(sourceScope: .currentPhotos, window: window, kind: .eventTickets))
        XCTAssertEqual(subset.appointmentDescription, .list(sourceScope: .previousResults, window: window, kind: .eventTickets))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(try XCTUnwrap(subset.appointmentDescription))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(context.answerID.uuidString))
        XCTAssertFalse(text.contains("fictional-secret-source"))
        XCTAssertTrue(text.contains("2026-10-25T07:00:00Z"))
        XCTAssertTrue(text.contains("2026-11-01T07:00:00Z"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(AppointmentQueryDescription.self, from: data), subset.appointmentDescription)
    }
    func testGeneratedChoicesCompileExactlyAndDoNotDuplicateEquivalentOperations() {
        for context in [nil, prior(count: 0), prior(count: 1), prior(count: 4, selection: .eventTickets)] {
            for date in [now, now.addingTimeInterval(8 * 86400)] {
                let options = MemoryQueryOptions.make(now: date, calendar: calendar, previous: context, selectedOrdinal: 2)
                XCTAssertEqual(Set(options.map(\.id)).count, options.count)
                for (index, option) in options.enumerated() {
                    XCTAssertEqual(option.plan, MemoryQueryCompiler.compile(option.meaning, now: date, calendar: calendar, previous: context, selectedOrdinal: 2))
                    XCTAssertNotEqual(option.plan, .needsContext); XCTAssertNotEqual(option.plan, .needsDate)
                    XCTAssertFalse(options.prefix(index).contains { $0.plan == option.plan }, "Equivalent operations split model confidence: \(option.id)")
                }
            }
        }
    }
    func testEmptyPreviousAnswerRetainsSubsetButNeverOffersLocation() {
        let empty = prior(count: 0), options = MemoryQueryOptions.make(now: now, calendar: calendar, previous: empty)
        XCTAssertTrue(options.contains { $0.id.hasPrefix("subset_") })
        XCTAssertFalse(options.contains { $0.id.hasPrefix("location_") })
        let absent = MemoryQueryOptions.make(now: now, calendar: calendar)
        XCTAssertFalse(absent.contains { $0.id.hasPrefix("subset_") || $0.id.hasPrefix("location_") })
        let refused = AppointmentConversationContext(answerID: UUID(), answer: AppointmentAnswerEngine.answer(window: .unresolved, items: [], originals: [], coverage: .unknown))
        let invalid = MemoryQueryOptions.make(now: now, calendar: calendar, previous: refused)
        XCTAssertFalse(invalid.contains { $0.id.hasPrefix("subset_") || $0.id.hasPrefix("location_") })
    }
    func testSelectedResultAddsNoDuplicateAndOutOfRangeSelectionCannotCreateLocation() {
        let context = prior(count: 4)
        let within = MemoryQueryOptions.make(now: now, calendar: calendar, previous: context, selectedOrdinal: 2)
        XCTAssertEqual(within.filter { $0.plan == .appointmentLocation(ordinal: 2) }.count, 1)
        XCTAssertTrue(within.first { $0.id == "location_second" }!.criteria.contains("explicitly selected"))
        let fourth = MemoryQueryOptions.make(now: now, calendar: calendar, previous: context, selectedOrdinal: 4)
        XCTAssertEqual(fourth.first { $0.id == "location_selected" }?.plan, .appointmentLocation(ordinal: 4))
        let missing = MemoryQueryOptions.make(now: now, calendar: calendar, previous: context, selectedOrdinal: 5)
        XCTAssertFalse(missing.contains { $0.id == "location_selected" })
    }
    func testUnsupportedPlansHaveNoExecutableAppointmentDescription() {
        for plan in [MemoryQueryPlan.needsDate, .needsContext, .unsupported, .unclear, .photos,
                     .appointments(window: .unresolved, selection: .any), .appointments(window: .all, selection: .unsupported),
                     .appointmentLocation(ordinal: 0)] {
            XCTAssertNil(AppointmentQueryDescription(plan))
        }
    }
}

private extension AppointmentAnswer {
    func withSelectionForTest(_ value: AppointmentSelection) -> AppointmentAnswer {
        AppointmentAnswer(window: window, selection: value, matches: matches, uncertain: uncertain, coverage: coverage)
    }
}
