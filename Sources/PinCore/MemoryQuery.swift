import Foundation

public enum MemoryQueryIntent: String, Codable, Sendable {
    case appointments, appointmentSubset, appointmentLocation, photos, museums, unsupported, unclear
}
public enum MemoryQueryPeriod: String, Codable, Sendable {
    case all, today, tomorrow, thisWeek, nextWeek, nextSevenDays, inherit, unsupported
}
public enum MemoryQueryReference: String, Codable, Sendable {
    case none, first, second, third, selected, unsupported
}
public enum MemoryQuerySelection: String, Codable, Sendable { case any, eventTickets, inherit, unsupported }
public enum AppointmentSelection: String, Codable, Sendable { case any, eventTickets, unsupported }

/// Provider-independent proposed meaning. It contains no appointment facts,
/// photo IDs, dates computed by a model, or permission to perform an action.
public struct MemoryQueryMeaning: Codable, Equatable, Sendable {
    public var intent: MemoryQueryIntent
    public var period: MemoryQueryPeriod
    public var reference: MemoryQueryReference
    public var selection: MemoryQuerySelection
    public init(intent: MemoryQueryIntent, period: MemoryQueryPeriod, reference: MemoryQueryReference = .none, selection: MemoryQuerySelection = .any) {
        self.intent = intent; self.period = period; self.reference = reference; self.selection = selection
    }
}

public enum MemoryQueryPlan: Equatable, Sendable {
    case appointments(window: AppointmentWindow, selection: AppointmentSelection)
    case appointmentSubset(answerID: UUID, window: AppointmentWindow, selection: AppointmentSelection)
    case appointmentLocation(ordinal: Int)
    case photos, museums
    case needsContext, needsDate, unsupported, unclear
}

public enum MemoryQueryCompiler {
    /// A plan may only inspect existing data. Unknown/unsupported appointment
    /// meanings have no branch to generic photo search.
    public static func compile(_ meaning: MemoryQueryMeaning, now: Date, calendar: Calendar,
                               previous: AppointmentConversationContext? = nil, selectedOrdinal: Int? = nil) -> MemoryQueryPlan {
        switch meaning.intent {
        case .photos:
            // The legacy four-field meaning cannot express photo predicates.
            // Never silently discard populated period/reference/kind fields.
            guard meaning.period == .all, meaning.reference == .none, meaning.selection == .any else { return .unsupported }
            return .photos
        case .museums: return .museums
        case .unsupported: return .unsupported
        case .unclear: return .unclear
        case .appointmentLocation:
            // Both preserve the exact displayed result; neither adds a filter.
            // A new explicit kind restriction still requires a different query.
            guard meaning.selection == .any || meaning.selection == .inherit else { return .unsupported }
            guard let previous, meaning.period == .inherit else { return .needsContext }
            let ordinal: Int?
            switch meaning.reference {
            case .first: ordinal = 1
            case .second: ordinal = 2
            case .third: ordinal = 3
            case .selected: ordinal = selectedOrdinal ?? previous.selectedOrdinal ?? (previous.resultCount == 1 ? 1 : nil)
            case .none, .unsupported: ordinal = nil
            }
            guard let ordinal, ordinal > 0, ordinal <= previous.resultCount else { return .needsContext }
            return .appointmentLocation(ordinal: ordinal)
        case .appointments, .appointmentSubset:
            if meaning.intent == .appointmentSubset {
                guard let previous, previous.window != .unresolved, previous.selection != .unsupported else { return .needsContext }
            }
            guard meaning.selection != .unsupported, meaning.reference == .none else { return .unsupported }
            let selection: AppointmentSelection
            switch meaning.selection {
            case .any: selection = .any
            case .eventTickets: selection = .eventTickets
            case .inherit:
                guard let previous, previous.selection != .unsupported else { return .needsContext }
                selection = previous.selection
            case .unsupported: return .unsupported
            }
            func plan(_ window: AppointmentWindow) -> MemoryQueryPlan {
                if meaning.intent == .appointmentSubset, let previous {
                    return .appointmentSubset(answerID: previous.answerID, window: window, selection: selection)
                }
                return .appointments(window: window, selection: selection)
            }
            if meaning.period == .inherit {
                guard let previous else { return .needsContext }
                guard previous.window != .unresolved else { return .needsDate }
                return plan(previous.window)
            }
            guard let period = AppointmentPeriod(rawValue: meaning.period.rawValue) else { return .needsDate }
            let window = AppointmentWindow.resolve(period, now: now, calendar: calendar)
            guard window != .unresolved else { return .needsDate }
            return plan(window)
        }
    }
}

/// Native execution keeps a fresh inventory query distinct from filtering the
/// exact previous answer. The latter also binds the answer's identity.
public enum MemoryQueryExecutor {
    public static func appointments(_ plan: MemoryQueryPlan, previous: AppointmentConversationContext? = nil,
                                    items: [AppointmentItem], originals: [PhotoMemory],
                                    coverage: AppointmentReadingCoverage) -> AppointmentSubsetAnswer {
        switch plan {
        case .appointments(let window, let selection):
            return .answer(AppointmentAnswerEngine.answer(window: window, selection: selection,
                items: items, originals: originals, coverage: coverage))
        case .appointmentSubset(let answerID, let window, let selection):
            guard let previous, previous.answerID == answerID else { return .staleContext }
            return previous.subset(window: window, selection: selection, items: items, originals: originals, coverage: coverage)
        default: return .unsupported
        }
    }
}

/// Native calendar windows can give two expressions the same meaning (for
/// example thisWeek and an inherited this-week answer). Offer one choice for
/// that window so model confidence is not split between equivalent operations.
/// Previous windows stay anchored to the original answer across clock changes.
public enum MemoryQueryPeriodOptions {
    public static func aliases(now: Date, calendar: Calendar,
                               previous: AppointmentConversationContext? = nil) -> [MemoryQueryPeriod: [MemoryQueryPeriod]] {
        let periods: [MemoryQueryPeriod] = [.all, .today, .tomorrow, .thisWeek, .nextWeek, .nextSevenDays]
        var choices: [(MemoryQueryPeriod, AppointmentWindow)] = []
        var result: [MemoryQueryPeriod: [MemoryQueryPeriod]] = [:]
        for period in periods + (previous == nil ? [] : [.inherit]) {
            let window: AppointmentWindow
            if period == .inherit { window = previous!.window }
            else { window = AppointmentWindow.resolve(AppointmentPeriod(rawValue: period.rawValue)!, now: now, calendar: calendar) }
            guard window != .unresolved else { continue }
            if let canonical = choices.first(where: { $0.1 == window })?.0 {
                result[canonical, default: []].append(period)
            } else {
                choices.append((period, window)); result[period] = [period]
            }
        }
        result[.unsupported] = [.unsupported]
        return result
    }
}

/// A model-facing description of an executable appointment operation. Only
/// applicable fields exist: a location lookup has no new kind/provider filter.
/// Source IDs and the native answer binding never leave the execution plan.
public enum AppointmentQueryDescription: Codable, Equatable, Sendable {
    public enum SourceScope: String, Codable, Sendable { case currentPhotos, previousResults }
    public enum Window: Codable, Equatable, Sendable {
        case all
        case interval(start: Date, endExclusive: Date)
        fileprivate init?(_ window: AppointmentWindow) {
            switch window {
            case .all: self = .all
            case .interval(let interval):
                guard interval.duration > 0 else { return nil }
                self = .interval(start: interval.start, endExclusive: interval.end)
            case .unresolved: return nil
            }
        }
    }
    case list(sourceScope: SourceScope, window: Window, kind: AppointmentSelection)
    case location(previousResultOrdinal: Int)

    public init?(_ plan: MemoryQueryPlan) {
        switch plan {
        case .appointments(let window, let selection):
            guard selection != .unsupported, let described = Window(window) else { return nil }
            self = .list(sourceScope: .currentPhotos, window: described, kind: selection)
        case .appointmentSubset(_, let window, let selection):
            guard selection != .unsupported, let described = Window(window) else { return nil }
            self = .list(sourceScope: .previousResults, window: described, kind: selection)
        case .appointmentLocation(let ordinal):
            guard ordinal > 0 else { return nil }
            self = .location(previousResultOrdinal: ordinal)
        default: return nil
        }
    }
}

public struct MemoryQueryOption: Sendable {
    public let id: String
    public let criteria: String
    public let meaning: MemoryQueryMeaning
    public let plan: MemoryQueryPlan
    public var appointmentDescription: AppointmentQueryDescription? { AppointmentQueryDescription(plan) }
}

/// Native code enumerates only operations it can execute. The interpreter
/// selects meaning; it cannot manufacture dates, source IDs, filters or actions.
/// Choosing from this set is still a semantic task and requires separate eval.
public enum MemoryQueryOptions {
    public static func make(now: Date, calendar: Calendar, previous: AppointmentConversationContext? = nil,
                            selectedOrdinal: Int? = nil) -> [MemoryQueryOption] {
        var options: [MemoryQueryOption] = []
        func append(_ id: String, _ criteria: String, _ meaning: MemoryQueryMeaning) {
            let plan = MemoryQueryCompiler.compile(meaning, now: now, calendar: calendar, previous: previous, selectedOrdinal: selectedOrdinal)
            guard plan != .needsContext, plan != .needsDate else { return }
            options.append(MemoryQueryOption(id: id, criteria: criteria, meaning: meaning, plan: plan))
        }
        let names: [MemoryQueryPeriod: String] = [
            .all: "no date restriction", .today: "today", .tomorrow: "tomorrow",
            .thisWeek: "this calendar week", .nextWeek: "next calendar week",
            .nextSevenDays: "the rolling next seven days", .inherit: "the preceding answer’s fixed date range"
        ]
        let aliases = MemoryQueryPeriodOptions.aliases(now: now, calendar: calendar, previous: previous)
        for period in aliases.keys.sorted(by: { $0.rawValue < $1.rawValue }) where period != .unsupported {
            let expressions = aliases[period, default: []].compactMap { names[$0] }.joined(separator: "; equivalently, ")
            for selection in [MemoryQuerySelection.any, .eventTickets] {
                let filter = selection == .any ? "all appointment kinds, including ordinary appointments and event tickets" : "only event-ticket appointments"
                var criteria = "Search current permitted photo records for \(filter), with \(expressions). This may include newly read records."
                if let previous {
                    criteria += previous.selection.rawValue == selection.rawValue
                        ? " This preserves the preceding kind filter."
                        : " This changes the preceding kind filter; the request must support that change."
                }
                criteria += " No provider, venue, service or other property restriction is applied."
                append("list_\(period.rawValue)_\(selection.rawValue)", criteria,
                       .init(intent: .appointments, period: period, selection: selection))
                if previous != nil {
                    append("subset_\(period.rawValue)_\(selection.rawValue)",
                        "From only the preceding answer’s dated results, keep \(filter), with \(expressions). Never admit newly read records or bring back appointments excluded from that answer. No additional provider, venue, service or other property restriction is applied.",
                        .init(intent: .appointmentSubset, period: period, selection: selection))
                }
            }
        }
        if let previous {
            let references: [(MemoryQueryReference, Int)] = [(.first, 1), (.second, 2), (.third, 3)]
            for (reference, ordinal) in references where ordinal <= previous.resultCount {
                let singular = previous.resultCount == 1 ? " It is the sole previous result, so an explicit singular reference can mean this result." : " A singular 'it' without a selected result is ambiguous."
                append("location_\(reference.rawValue)",
                       "Read the location of result \(ordinal) in the preceding displayed answer. This keeps that exact result and does not run a new search or apply new filters.\(singular)",
                       .init(intent: .appointmentLocation, period: .inherit, reference: reference))
            }
            if let selectedOrdinal, selectedOrdinal > 0, selectedOrdinal <= previous.resultCount {
                // If already offered by ordinal, give that operation the selected
                // reference alias rather than split probability across duplicates.
                if let i = options.firstIndex(where: { $0.plan == .appointmentLocation(ordinal: selectedOrdinal) }) {
                    let old = options[i]
                    options[i] = MemoryQueryOption(id: old.id, criteria: old.criteria + " This is also the explicitly selected result.", meaning: old.meaning, plan: old.plan)
                } else {
                    append("location_selected", "Read the location of the explicitly selected result \(selectedOrdinal) from the preceding answer. Keep that exact result; do not search or apply new filters.",
                           .init(intent: .appointmentLocation, period: .inherit, reference: .selected))
                }
            }
        }
        append("photos", "Generic lexical photo recall only. This option encodes no capture-date, literal-text, media-type, topic or prior-photo-result filter. If any such condition is required, this legacy option cannot preserve it.", .init(intent: .photos, period: .all))
        append("museums", "Ask about museum identity or visits.", .init(intent: .museums, period: .all))
        append("unsupported", "The request is clear but no operation preserves every constraint: unsupported provider, venue, service, property, date or ordinal; or an action such as book, cancel, move or remind. Never drop a restriction to fit an option.", .init(intent: .unsupported, period: .all))
        append("unclear", "The operation, scope or reference is ambiguous or lacks needed context. Do not guess a domain for a bare date follow-up.", .init(intent: .unclear, period: .all))
        return options
    }
}

/// Explicitly update an already understood list without interpreting its words
/// again. Fixed subsets retain evidence membership; current-library queries may
/// admit new matches. Old conversation ordinals remain separate and unchanged.
public struct AppointmentAnswerUpdate: Sendable {
    public let plan: MemoryQueryPlan
    public let window: AppointmentWindow
    public let selection: AppointmentSelection
    private let fixedMembers: [AppointmentItem]?
    private let submittedAt: Date
    private let calendar: Calendar

    public init?(plan: MemoryQueryPlan, answer: AppointmentAnswer, now: Date, calendar: Calendar) {
        let window: AppointmentWindow, selection: AppointmentSelection
        switch plan {
        case .appointments(let w, let s): window = w; selection = s; fixedMembers = nil
        case .appointmentSubset(_, let w, let s): window = w; selection = s; fixedMembers = answer.matches + answer.uncertain
        default: return nil
        }
        guard AppointmentQueryDescription(plan) != nil, answer.window == window, answer.selection == selection else { return nil }
        self.plan = plan; self.window = window; self.selection = selection
        self.submittedAt = now; self.calendar = calendar
    }

    public func answer(now: Date, calendar: Calendar, items: [AppointmentItem], originals: [PhotoMemory],
                       coverage: AppointmentReadingCoverage) -> AppointmentAnswer? {
        guard self.calendar == calendar, calendar.isDate(now, inSameDayAs: submittedAt) else { return nil }
        let current = AppointmentAnswerEngine.currentRecords(items, originals: originals)
        let rows: [AppointmentItem]
        if let fixedMembers {
            rows = current.filter { live in fixedMembers.contains { live.hasSameEvidence(as: $0) } }
        } else { rows = current }
        return AppointmentAnswerEngine.answer(window: window, selection: selection,
            items: rows, originals: originals, coverage: coverage)
    }
}


/// A model's evidence for how the current question uses appointment-kind scope.
/// Words must come from this question; matching text is provenance, not proof
/// that the model correctly understood it. Evaluate semantics separately.
public struct AppointmentScopeEvidence: Codable, Equatable, Sendable {
    public enum Basis: String, Codable, Sendable { case explicit, inherited, ambiguous, notApplicable }
    public var basis: Basis
    public var words: [String]
    public init(basis: Basis, words: [String]) { self.basis = basis; self.words = words }
    public func hasCurrentWords(in question: String) -> Bool {
        !words.isEmpty && words.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                question.range(of: $0, options: .caseInsensitive) != nil
        }
    }
    /// A model's "explicit" label and a substring such as "anything" are
    /// insufficient to widen a previous ticket-only result. The current
    /// question itself must name the broader appointment scope; the model's
    /// quoted words still have to come from that question, but need not repeat
    /// its scope phrase when they cite the requested date instead.
    public func explicitlyBroadensAppointmentKinds(in question: String) -> Bool {
        guard basis == .explicit, hasCurrentWords(in: question) else { return false }
        let current = question.lowercased().replacingOccurrences(of: "’", with: "'")
        // A quoted screenshot or previous answer can contain these words
        // without making them the person's requested scope.
        let request = current.replacingOccurrences(of: #""[^"]*"|“[^”]*”|`[^`]*`"#,
            with: " ", options: .regularExpression)
        let conflicts = [
            #"\b(?:not|never)\s+(?:show\s+)?(?:all|every|any)\b"#,
            #"\bonly\s+(?:event\s+)?(?:tickets?|appointments?|bookings?)\b"#,
            #"\b(?:without|except|excluding)\s+(?:event\s+)?tickets?\b"#
        ]
        guard !conflicts.contains(where: { request.range(of: $0, options: .regularExpression) != nil }) else { return false }
        let tokens = request.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let appointmentNouns: Set<String> = ["appointment", "appointments", "booking", "bookings"]
        for index in tokens.indices where ["all", "every", "any"].contains(tokens[index]) {
            if tokens.dropFirst(index + 1).prefix(3).contains(where: appointmentNouns.contains) { return true }
        }
        let namesAppointments = tokens.contains(where: appointmentNouns.contains)
        let namesTickets = tokens.contains { ["ticket", "tickets", "ticketed"].contains($0) }
        let joinsKinds = tokens.contains { ["and", "plus", "including"].contains($0) } ||
            request.localizedCaseInsensitiveContains("as well as")
        return namesAppointments && namesTickets && joinsKinds
    }
}

public enum AppointmentScopeAdmission: Sendable {
    case plan(MemoryQueryPlan)
    case clarify(AppointmentScopeClarification)

    /// A legacy meaning cannot silently remove a preceding ticket constraint.
    /// The interpreter must supply supported explicit scope, or the person must
    /// resolve it. This does not guess intent from a list of question phrases.
    public static func resolve(_ meaning: MemoryQueryMeaning, evidence: AppointmentScopeEvidence? = nil,
                               question: String, requestID: UUID, now: Date, calendar: Calendar,
                               previous: AppointmentConversationContext? = nil,
                               items: [AppointmentItem], originals: [PhotoMemory]) -> AppointmentScopeAdmission {
        let plan = MemoryQueryCompiler.compile(meaning, now: now, calendar: calendar, previous: previous)
        guard meaning.intent == .appointments || meaning.intent == .appointmentSubset else { return .plan(plan) }
        switch plan {
        case .appointments, .appointmentSubset: break
        default: return .plan(plan)
        }
        let broadens = previous?.selection == .eventTickets && meaning.selection == .any
        let ambiguous = evidence?.basis == .ambiguous
        guard broadens || ambiguous else { return .plan(plan) }
        if broadens, evidence?.explicitlyBroadensAppointmentKinds(in: question) == true { return .plan(plan) }
        guard let pending = AppointmentScopeClarification(plan: plan, requestID: requestID, now: now,
            calendar: calendar, previous: previous, items: items, originals: originals) else { return .plan(.unclear) }
        return .clarify(pending)
    }
}

/// Transient pending answer, never durable evidence. Choosing scope retains the
/// exact native window, source membership and receipt from the original question.
public struct AppointmentScopeClarification: Sendable {
    public let requestID: UUID
    public let window: AppointmentWindow
    private let prior: AppointmentConversationContext
    private let previousResultsOnly: Bool
    private let receipt: AppointmentAnswerReceipt
    private let submittedAt: Date
    private let calendar: Calendar

    public init?(plan: MemoryQueryPlan, requestID: UUID, now: Date, calendar: Calendar,
                 previous: AppointmentConversationContext?, items: [AppointmentItem], originals: [PhotoMemory]) {
        guard let previous, previous.selection == .eventTickets else { return nil }
        switch plan {
        case .appointments(let window, let selection):
            guard selection != .unsupported else { return nil }
            self.window = window; previousResultsOnly = false
        case .appointmentSubset(let answerID, let window, let selection):
            guard answerID == previous.answerID, selection != .unsupported else { return nil }
            self.window = window; previousResultsOnly = true
        default: return nil
        }
        guard window != .unresolved else { return nil }
        self.requestID = requestID; prior = previous; submittedAt = now; self.calendar = calendar
        receipt = AppointmentAnswerReceipt(requestID: requestID, period: .all, now: now, calendar: calendar, items: items, originals: originals)
    }

    public func resolve(_ selection: AppointmentSelection, requestID: UUID, previous: AppointmentConversationContext?,
                        now: Date, calendar: Calendar, items: [AppointmentItem], originals: [PhotoMemory]) -> MemoryQueryPlan? {
        guard selection == .any || selection == .eventTickets,
              let previous, previous.answerID == prior.answerID, previous.window == prior.window,
              previous.selection == prior.selection, previous.resultCount == prior.resultCount,
              self.calendar == calendar, calendar.isDate(now, inSameDayAs: submittedAt),
              receipt.isCurrent(requestID: requestID, now: now, calendar: calendar, items: items, originals: originals),
              case .answer = prior.subset(items: items, originals: originals, coverage: .unknown) else { return nil }
        if previousResultsOnly { return .appointmentSubset(answerID: prior.answerID, window: window, selection: selection) }
        return .appointments(window: window, selection: selection)
    }
}


/// Versioned proposal for the fictional query lab. All unsupported restrictions
/// stay visible to admission; structured output alone never authorizes a plan.
public struct MemoryQueryProposal: Codable, Equatable, Sendable {
    public struct Qualifier: Codable, Equatable, Sendable {
        public enum Facet: String, Codable, Sendable { case provider, venue, service, other }
        public var words: String
        public var facet: Facet
        public init(words:String,facet:Facet) { self.words=words;self.facet=facet }
    }
    public var qualifiers:[Qualifier]
    public var requiresPreviousContext:Bool
    public var intent:MemoryQueryIntent
    public var period:MemoryQueryPeriod
    public var reference:MemoryQueryReference
    public var selection:MemoryQuerySelection
    public var scope:AppointmentScopeEvidence
    public var meaning:MemoryQueryMeaning { .init(intent:intent,period:period,reference:reference,selection:selection) }
    public init(meaning:MemoryQueryMeaning,scope:AppointmentScopeEvidence,qualifiers:[Qualifier]=[],requiresPreviousContext:Bool=false) {
        intent=meaning.intent;period=meaning.period;reference=meaning.reference;selection=meaning.selection
        self.scope=scope;self.qualifiers=qualifiers;self.requiresPreviousContext=requiresPreviousContext
    }
    public func admission(question:String,requestID:UUID,now:Date,calendar:Calendar,
                          previous:AppointmentConversationContext?,items:[AppointmentItem],originals:[PhotoMemory]) -> AppointmentScopeAdmission {
        guard qualifiers.allSatisfy({ !$0.words.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && question.contains($0.words) }) else { return .plan(.unclear) }
        guard qualifiers.isEmpty else { return .plan(.unsupported) }
        guard !requiresPreviousContext || previous != nil else { return .plan(.needsContext) }
        return AppointmentScopeAdmission.resolve(meaning,evidence:scope,question:question,requestID:requestID,now:now,calendar:calendar,
            previous:previous,items:items,originals:originals)
    }
}
