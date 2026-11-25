import Foundation

/// A model proposes meaning; native code resolves calendar intervals and reads
/// current appointment records. This contract has no generic photo fallback.
public enum AppointmentPeriod: String, Codable, Sendable {
    case all, today, tomorrow, thisWeek, nextWeek, nextSevenDays, unresolved
}

public enum AppointmentWindow: Equatable, Sendable {
    case all, interval(DateInterval), unresolved

    public static func resolve(_ period: AppointmentPeriod, now: Date, calendar: Calendar) -> Self {
        func day(_ date: Date) -> Self {
            guard let interval = calendar.dateInterval(of: .day, for: date) else { return .unresolved }
            return .interval(interval)
        }
        switch period {
        case .all: return .all
        case .today: return day(now)
        case .tomorrow:
            guard let date = calendar.date(byAdding: .day, value: 1, to: now) else { return .unresolved }
            return day(date)
        case .thisWeek:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return .unresolved }
            return .interval(interval)
        case .nextWeek:
            guard let current = calendar.dateInterval(of: .weekOfYear, for: now),
                  let next = calendar.dateInterval(of: .weekOfYear, for: current.end) else { return .unresolved }
            return .interval(next)
        case .nextSevenDays:
            // A rolling seven calendar days from now, not the following week.
            guard let end = calendar.date(byAdding: .day, value: 7, to: now) else { return .unresolved }
            return .interval(DateInterval(start: now, end: end))
        case .unresolved: return .unresolved
        }
    }

    public func includes(_ date: Date) -> Bool {
        switch self {
        case .all: return true
        case .interval(let interval): return date >= interval.start && date < interval.end
        case .unresolved: return false
        }
    }
}

/// The answer describes permitted photos, never a complete personal calendar.
public enum AppointmentReadingCoverage: Equatable, Sendable {
    case readAvailablePhotos, incomplete, unknown
}

public struct AppointmentAnswer: Equatable, Sendable {
    public let window: AppointmentWindow
    public let selection: AppointmentSelection
    public let matches: [AppointmentItem]
    public let uncertain: [AppointmentItem]
    public let coverage: AppointmentReadingCoverage
    public init(window:AppointmentWindow,selection:AppointmentSelection,matches:[AppointmentItem],uncertain:[AppointmentItem],coverage:AppointmentReadingCoverage){self.window=window;self.selection=selection;self.matches=matches;self.uncertain=uncertain;self.coverage=coverage}
    public var needsDateClarification: Bool { window == .unresolved }
    public var canAssertPersonalCalendarIsEmpty: Bool { false }
    /// Preserve the displayed membership/order, but use live reminder state.
    /// Any changed/withdrawn evidence invalidates the entire displayed answer.
    public func refreshed(items: [AppointmentItem], originals: [PhotoMemory]) -> AppointmentAnswer? {
        guard let rows = AppointmentAnswerEngine.rebind(matches + uncertain, items: items, originals: originals) else { return nil }
        return AppointmentAnswer(window: window, selection: selection,
            matches: Array(rows.prefix(matches.count)), uncertain: Array(rows.dropFirst(matches.count)), coverage: coverage)
    }

}

public enum AppointmentAnswerEngine {
    /// Exact duplicate rows collapse. Distinct source photos do not establish
    /// the same booking; a future supported booking identity may group them.
    /// Conflicting rows for one source are withheld, not arbitrarily selected.
    public static func currentRecords(_ items: [AppointmentItem], originals: [PhotoMemory], includingCancelled: Bool = false) -> [AppointmentItem] {
        let current = items.filter { item in
            !item.dismissed && (includingCancelled || item.observation.cancelled != true) && item.observation.sourceID == item.sourceID &&
            item.allSources.allSatisfy { source in originals.contains { AppointmentSource($0) == source && !AppointmentCardReader.isPinInterface($0.text) } }
        }
        return Dictionary(grouping: current, by: \.id).values.compactMap { rows in
            guard let first = rows.first, rows.allSatisfy({ $0 == first }) else { return nil }
            return first
        }.sorted { $0.id < $1.id }
    }

    /// Match exact source/evidence identity, then return current action state.
    /// New records never enter a previous result, and no ordinal is compressed.
    public static func rebind(_ records: [AppointmentItem], items: [AppointmentItem], originals: [PhotoMemory]) -> [AppointmentItem]? {
        // Membership was selected by the answer's operation. Rebinding only
        // validates those exact rows; it must preserve an explicitly selected
        // cancelled record rather than applying the scheduled-list default.
        let current = Dictionary(uniqueKeysWithValues: currentRecords(items, originals: originals, includingCancelled: true).map { ($0.id, $0) })
        var rebound: [AppointmentItem] = []
        for record in records {
            guard let live = current[record.id], live.hasSameEvidence(as: record) else { return nil }
            rebound.append(live)
        }
        return rebound
    }

    public static func answer(period: AppointmentPeriod, now: Date, calendar: Calendar,
                              items: [AppointmentItem], originals: [PhotoMemory],
                              coverage: AppointmentReadingCoverage) -> AppointmentAnswer {
        answer(window: AppointmentWindow.resolve(period, now: now, calendar: calendar), items: items, originals: originals, coverage: coverage)
    }

    public static func answer(window: AppointmentWindow, selection: AppointmentSelection = .any,
                              items: [AppointmentItem], originals: [PhotoMemory],
                              coverage: AppointmentReadingCoverage) -> AppointmentAnswer {
        guard window != .unresolved, selection != .unsupported else {
            return AppointmentAnswer(window: .unresolved, selection: .unsupported, matches: [], uncertain: [], coverage: coverage)
        }
        let current = currentRecords(items, originals: originals).filter {
            selection != .eventTickets || $0.observation.eventTicket == true
        }
        let matches = current.filter {
            guard let date = $0.observation.date, $0.observation.reviewReason == nil,
                  TimeZone(identifier: $0.observation.timeZoneID) != nil else { return false }
            return window.includes(date)
        }
        let uncertain = current.filter {
            let card = $0.observation
            guard card.date == nil || card.reviewReason != nil || TimeZone(identifier: card.timeZoneID) == nil else { return false }
            // A tentative date outside the interval does not become a match.
            // Completely unresolved dates remain a separate review collection.
            if let date=card.date {return window.includes(date)}
            return card.calendarDay?.mayOverlap(window) ?? true
        }
        func ordered(_ rows: [AppointmentItem]) -> [AppointmentItem] {
            rows.sorted {
                let a = $0.observation.date ?? .distantFuture, b = $1.observation.date ?? .distantFuture
                return a == b ? $0.id < $1.id : a < b
            }
        }
        return AppointmentAnswer(window: window, selection: selection, matches: ordered(matches), uncertain: ordered(uncertain), coverage: coverage)
    }
}

/// An asynchronous interpretation cannot publish over a newer question or a
/// changed appointment inventory. Holds no additional durable truth store.
public struct AppointmentAnswerReceipt: Sendable {
    public let requestID: UUID
    private let inventory: [AppointmentItem]
    private let period: AppointmentPeriod
    private let calendar: Calendar
    private let window: AppointmentWindow
    private let submittedAt: Date
    public init(requestID: UUID, period: AppointmentPeriod, now: Date, calendar: Calendar,
                items: [AppointmentItem], originals: [PhotoMemory]) {
        self.requestID = requestID; self.period = period; self.calendar = calendar; submittedAt = now
        window = AppointmentWindow.resolve(period, now: now, calendar: calendar)
        inventory = AppointmentAnswerEngine.currentRecords(items, originals: originals)
    }
    public func isCurrent(requestID: UUID, now: Date, calendar: Calendar,
                          items: [AppointmentItem], originals: [PhotoMemory]) -> Bool {
        // A rolling interval remains anchored to the submitted question, so
        // ordinary inference latency does not invalidate every answer. A day
        // boundary still requires a fresh interpretation/read projection.
        let sameTimeScope = period == .nextSevenDays
            ? calendar.isDate(now, inSameDayAs: submittedAt)
            : window == AppointmentWindow.resolve(period, now: now, calendar: calendar)
        return self.requestID == requestID && self.calendar == calendar && sameTimeScope &&
            inventory.elementsEqual(AppointmentAnswerEngine.currentRecords(items, originals: originals), by: { $0.hasSameEvidence(as: $1) })
    }
}

public enum AppointmentLocationAnswer: Equatable, Sendable {
    case location(source: AppointmentSource, venue: String?, address: String?)
    case unknownLocation, missingContext, invalidOrdinal, staleContext
}

public enum AppointmentSubsetAnswer: Equatable, Sendable {
    case answer(AppointmentAnswer)
    case staleContext, unsupported
}

/// Ordered, source-bound references for the currently displayed dated list.
/// Never compress this list after withdrawal: “second” must not become third.
public struct AppointmentConversationContext: Sendable {
    public let answerID: UUID
    public let window: AppointmentWindow
    public let selection: AppointmentSelection
    private let ordered: [AppointmentItem]
    /// Ephemeral inspection within this answer, never a new record or source.
    public private(set) var selectedOrdinal: Int? = nil
    public var resultCount: Int { ordered.count }
    public init(answerID: UUID, answer: AppointmentAnswer,includingUncertain:Bool=false) {
        self.answerID = answerID; window = answer.window; selection = answer.selection; ordered = answer.matches+(includingUncertain ? answer.uncertain:[])
    }
    /// Inspect one exact current event. A shared original can contain several
    /// events, so photo identity alone must never choose the reference.
    @discardableResult public mutating func select(_ item: AppointmentItem,
        items: [AppointmentItem], originals: [PhotoMemory]) -> Bool {
        guard let index = ordered.firstIndex(where: { $0.id == item.id }),
              let current = self.item(of: index + 1, answerID: answerID, items: items, originals: originals),
              current.hasSameEvidence(as: item) else { return false }
        selectedOrdinal = index + 1
        return true
    }
    /// Return the exact event row, not merely its photo source. Two tickets
    /// photographed together have the same source but different identities.
    public func item(of ordinal: Int, answerID: UUID, items: [AppointmentItem], originals: [PhotoMemory]) -> AppointmentItem? {
        guard self.answerID == answerID, ordinal > 0, ordinal <= ordered.count else { return nil }
        return AppointmentAnswerEngine.rebind([ordered[ordinal - 1]], items: items, originals: originals)?.first
    }
    /// A reference to “those” filters the prior result membership. A new query
    /// for tomorrow may use current records; this operation must not admit new
    /// records merely because they share the old time range. Changed members
    /// invalidate the projection rather than silently substituting new evidence.
    public func subset(window: AppointmentWindow? = nil, selection: AppointmentSelection? = nil,
                       items: [AppointmentItem], originals: [PhotoMemory],
                       coverage: AppointmentReadingCoverage) -> AppointmentSubsetAnswer {
        let filter = selection ?? self.selection
        guard filter != .unsupported else { return .unsupported }
        guard let current = AppointmentAnswerEngine.rebind(ordered, items: items, originals: originals) else { return .staleContext }
        return .answer(AppointmentAnswerEngine.answer(window: window ?? self.window, selection: filter,
            items: current, originals: originals, coverage: coverage))
    }

    public func location(of ordinal: Int, answerID: UUID, items: [AppointmentItem], originals: [PhotoMemory]) -> AppointmentLocationAnswer {
        guard self.answerID == answerID else { return .staleContext }
        guard !ordered.isEmpty else { return .missingContext }
        guard ordinal > 0 && ordinal <= ordered.count else { return .invalidOrdinal }
        guard let selected = item(of: ordinal, answerID: answerID, items: items, originals: originals) else { return .staleContext }
        let card = selected.observation
        guard card.venue?.isEmpty == false || card.address?.isEmpty == false else { return .unknownLocation }
        return .location(source: selected.source, venue: card.venue, address: card.address)
    }
}
