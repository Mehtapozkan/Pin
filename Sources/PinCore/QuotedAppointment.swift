import Foundation
import CryptoKit

/// Model output may select a substring, but only current OCR lines can support it.
public struct QuotedAppointmentField: Codable, Equatable, Sendable {
    public let lineID: String
    public let quote: String
    public init(lineID: String, quote: String) { self.lineID = lineID; self.quote = quote }
}

public struct QuotedAppointmentEvent: Codable, Equatable, Sendable {
    public let kind: String
    public let status: String
    public let title: QuotedAppointmentField
    public let effectiveDate: QuotedAppointmentField
    public let supersededDate: QuotedAppointmentField
    public let time: QuotedAppointmentField
    public let provider: QuotedAppointmentField
    public let venue: QuotedAppointmentField
    public let confirmation: QuotedAppointmentField
    public let bookingID: QuotedAppointmentField
    public let conflictingDates: [QuotedAppointmentField]
    public var fields: [QuotedAppointmentField] {
        [title, effectiveDate, supersededDate, time, provider, venue, confirmation, bookingID] + conflictingDates
    }
}

public struct QuotedAppointmentDocument: Codable, Equatable, Sendable {
    public let document: String
    public let events: [QuotedAppointmentEvent]
}

public enum QuotedAppointmentRead: Sendable {
    case bookings([AppointmentItem])
    case notBooking
    case unresolved(String)
}

/// A proposal is data, never publication authority. The caller retains the
/// digest from the OCR request; the store still rechecks source/permit/facts.
/// This is an application-owned admission policy, never a model-selected ID.
/// The existing printed-reference contract remains the default.
public enum QuotedAppointmentIdentityPolicy: Equatable, Sendable {
    case printedReference, sourceAnchors
}

public enum QuotedAppointmentCompiler {
    public static let version = "pin-quoted-document-v2"
    public static let sourceAnchorVersion = "pin-quoted-document-source-anchors-v1"

    public static func compile(_ proposal: QuotedAppointmentDocument,
                               requestedTextDigest: String,
                               read: AppointmentSourceRead,
                               current: PhotoMemory,
                               timePolicy: SemanticAppointmentTimePolicy = .printedZoneOnly,
                               identityPolicy: QuotedAppointmentIdentityPolicy = .printedReference) -> QuotedAppointmentRead {
        guard AppointmentSource(current) == read.source,
              !read.observations.isEmpty,
              Set(read.observations.map(\.id)).count == read.observations.count,
              read.observations.allSatisfy({ !$0.id.isEmpty && $0.id != "unknown" && $0.id != "conflicting" &&
                  !$0.line.text.isEmpty && $0.line.confidence.isFinite && (0...1).contains($0.line.confidence) &&
                  ($0.line.region?.isValid ?? true) && current.textEvidence?.contains($0.line) == true }),
              AppointmentSourceDigest.text(read.observations.map(\.line)) == requestedTextDigest else {
            return .unresolved("The source or OCR request changed.")
        }
        let lines = read.observations.map(\.line)
        if AppointmentCardReader.isPinInterface(lines.map(\.text)) { return .notBooking }
        switch AppointmentCardReader.sourceDisposition(lines.map(\.text)) {
        case .nonHolder: return .notBooking
        case .contradictory: return .unresolved("The source has conflicting holder or issue evidence.")
        case .notExcluded: break
        }
        guard ["booking", "notBooking", "unclear"].contains(proposal.document) else {
            return .unresolved("The document decision is unsupported.")
        }
        if proposal.document == "notBooking" {
            return proposal.events.isEmpty ? .notBooking : .unresolved("A nonbooking returned events.")
        }
        guard proposal.document == "booking", (1...8).contains(proposal.events.count) else {
            return .unresolved("The document has no supported booking events.")
        }
        let indexed = Dictionary(uniqueKeysWithValues: read.observations.map { ($0.id, $0.line) })
        func supported(_ field: QuotedAppointmentField) -> CardLine? {
            guard field.lineID != "unknown", field.lineID != "conflicting",
                  !field.quote.isEmpty, let line = indexed[field.lineID],
                  line.confidence >= 0.5, line.text.contains(field.quote) else { return nil }
            return line
        }
        func valid(_ field: QuotedAppointmentField) -> Bool {
            if field.lineID == "unknown" || field.lineID == "conflicting" { return field.quote.isEmpty }
            return supported(field) != nil
        }
        let evidenceSource = EvidenceSource(current)
        var keys = Set<String>()
        var rows: [AppointmentItem] = []
        for event in proposal.events {
            guard ["appointment", "eventTicket"].contains(event.kind),
                  ["scheduled", "cancelled", "unknown"].contains(event.status),
                  event.fields.allSatisfy(valid),
                  supported(event.title) != nil, supported(event.confirmation) != nil,
                  supported(event.bookingID) != nil || (identityPolicy == .sourceAnchors &&
                      event.bookingID.lineID == "unknown" && event.bookingID.quote.isEmpty) else {
                return .unresolved("An event has no distinct, source-supported booking identity or field.")
            }
            var card = AppointmentObservation(sourceID: current.id,
                title: event.title.quote, date: nil, timeZoneID: "", zoneFromCard: false, evidence: lines)
            card.semanticVersion = identityPolicy == .sourceAnchors ? sourceAnchorVersion : version
            card.bookingReference = supported(event.bookingID) == nil ? nil : event.bookingID.quote
            card.eventTicket = event.kind == "eventTicket"
            card.cancelled = event.status == "cancelled" ? true : event.status == "scheduled" ? false : nil
            card.provider = supported(event.provider) == nil ? nil : event.provider.quote
            card.venue = supported(event.venue) == nil ? nil : event.venue.quote
            card.printedDate = supported(event.effectiveDate) == nil ? nil : event.effectiveDate.quote
            card.printedTime = supported(event.time) == nil ? nil : event.time.quote
            var facts: [FieldFact] = []
            for (field, quote) in [("purpose", event.title), ("printedDate", event.effectiveDate),
                                    ("supersededDate", event.supersededDate), ("printedTime", event.time),
                                    ("provider", event.provider), ("venue", event.venue),
                                    ("confirmation", event.confirmation), ("bookingReference", event.bookingID)] {
                if let line = supported(quote) {
                    facts.append(FieldFact(field: field, value: quote.quote, origin: .observed,
                        source: evidenceSource, support: [line], extractorVersion: card.semanticVersion!))
                }
            }
            for quote in event.conflictingDates where supported(quote) != nil {
                facts.append(FieldFact(field: "conflictingDate", value: quote.quote, origin: .observed,
                    source: evidenceSource, support: [supported(quote)!], extractorVersion: card.semanticVersion!))
            }
            let confirmationLine = supported(event.confirmation)!
            facts.append(FieldFact(field: "bookingKind", value: event.kind, origin: .inferred,
                source: evidenceSource, support: [confirmationLine], extractorVersion: card.semanticVersion!))
            facts.append(FieldFact(field: "bookingStatus", value: event.status, origin: .inferred,
                source: evidenceSource, support: [confirmationLine], extractorVersion: card.semanticVersion!))

            let dateLine = supported(event.effectiveDate)
            let dateQuote = event.effectiveDate.quote
            if let dateLine, dateLine.confidence >= 0.8 {
                card.calendarDay = AppointmentCalendarDay.parse(dateQuote)
                if card.calendarDay == nil, current.isScreenshot == true,
                   let captured = current.photographedAt,
                   dateQuote.range(of: "\\b[0-9]{4}\\b", options: .regularExpression) == nil,
                   let zone = assumedZone(timePolicy),
                   let year = AppointmentCardReader.screenshotYear(for: dateQuote, captured: captured, zone: zone),
                   let inferred = AppointmentCalendarDay.parse("\(dateQuote), \(year)") {
                    card.calendarDay = inferred
                    card.inferredYear = year
                    card.yearBasisDate = captured
                }
                if let day = card.calendarDay,
                   !SemanticAppointmentCompiler.weekdayAgrees(dateQuote, day: day) {
                    card.calendarDay = nil
                    card.inferredYear = nil
                    card.yearBasisDate = nil
                }
                if let day = card.calendarDay {
                    if let inferredYear = card.inferredYear {
                        facts.append(FieldFact(field: "inferredYear", value: String(inferredYear), origin: .inferred,
                            source: evidenceSource, support: [dateLine], extractorVersion: card.semanticVersion!))
                    }
                    facts.append(FieldFact(field: "calendarDay", value: day.label, origin: .inferred,
                        source: evidenceSource, support: [dateLine], extractorVersion: card.semanticVersion!))
                }
            }
            if card.cancelled == true { card.reviewReason = "This source says the booking was cancelled." }
            else if card.cancelled == nil { card.reviewReason = "The booking status is unresolved." }
            else if event.effectiveDate.lineID == "conflicting" || !event.conflictingDates.isEmpty {
                card.reviewReason = "The source contains conflicting appointment dates."
            }
            else if card.inferredYear != nil {
                card.reviewReason = "The year is inferred from the screenshot date. Check the original before setting a reminder."
            }
            else if let day = card.calendarDay, let timeLine = supported(event.time), timeLine.confidence >= 0.8,
                    let clock = clock(event.time.quote),
                    let zoneSelection = selectedZone(event.effectiveDate.quote + " " + event.time.quote,
                        policy: timePolicy) {
                let zone = zoneSelection.zone
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                let parts = DateComponents(year: day.year, month: day.month, day: day.day,
                                           hour: clock.0, minute: clock.1)
                if let instant = calendar.date(from: parts),
                   calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant) == parts {
                    let midnight = calendar.startOfDay(for: instant).addingTimeInterval(-1)
                    let matching = DateComponents(hour: clock.0, minute: clock.1)
                    let first = calendar.nextDate(after: midnight, matching: matching,
                        matchingPolicy: .strict, repeatedTimePolicy: .first)
                    let last = calendar.nextDate(after: midnight, matching: matching,
                        matchingPolicy: .strict, repeatedTimePolicy: .last)
                    if let printed = zoneSelection.abbreviation,
                       zone.abbreviation(for: instant)?.uppercased() != printed {
                        card.reviewReason = "The printed time zone does not match this date."
                    }
                    else if first == last {
                        card.date = instant
                        card.timeZoneID = zone.identifier
                        card.zoneFromCard = zoneSelection.abbreviation != nil
                    }
                    else { card.reviewReason = "The local time occurs twice. Check the original." }
                } else { card.reviewReason = "The printed local date or time does not exist." }
            }
            if card.date == nil && card.reviewReason == nil {
                card.reviewReason = "The printed date, time or time zone is unresolved."
            }
            card.fieldFacts = facts
            guard let identity = card.bookingReference ?? sourceAnchorID(for: card, source: read.source),
                  !identity.isEmpty, identity.utf8.count <= 256, keys.insert(identity).inserted else {
                return .unresolved("The source does not distinguish each event's identity.")
            }
            rows.append(AppointmentItem(source: read.source, observation: card, eventID: identity))
        }
        return .bookings(rows)
    }

    /// A derived identity is scoped to this exact source version. It is not a
    /// booking reference, person identity, cross-photo dedup key or fact of attendance.
    /// Equal observed anchors deliberately collide and hold the entire batch;
    /// ordinal position is never invented to make ambiguous rows distinct.
    static func sourceAnchorID(for card: AppointmentObservation, source: AppointmentSource) -> String? {
        guard card.semanticVersion == sourceAnchorVersion, card.sourceID == source.id,
              card.bookingReference == nil, let facts = card.fieldFacts,
              !facts.contains(where: { $0.field == "bookingReference" }) else { return nil }
        let observed = facts.filter { $0.origin == .observed }
        let evidence = EvidenceSource(id: source.id, fingerprint: source.fingerprint, revision: source.revision)
        let expected: [(String, String?)] = [("purpose", card.title), ("printedDate", card.printedDate),
            ("printedTime", card.printedTime), ("provider", card.provider), ("venue", card.venue)]
        for (field, value) in expected {
            let rows = observed.filter { $0.field == field }
            if let value {
                guard rows.count == 1, rows[0].value == value else { return nil }
            } else if !rows.isEmpty { return nil }
        }
        guard observed.filter({ $0.field == "confirmation" }).count == 1,
              !observed.isEmpty, observed.allSatisfy({ fact in
                  fact.source == evidence && fact.extractorVersion == sourceAnchorVersion &&
                  !fact.value.isEmpty && !fact.support.isEmpty &&
                  fact.support.contains(where: { $0.text.contains(fact.value) })
              }) else { return nil }
        var bytes = Data()
        func frame(_ value: String) {
            let data = Data(value.utf8)
            bytes.append(contentsOf: String(data.count).utf8); bytes.append(0x3a); bytes.append(data)
        }
        frame(sourceAnchorVersion); frame(source.id); frame(source.fingerprint); frame(String(source.revision))
        let anchors = observed.map { fact in
            [fact.field, fact.value] + fact.support.map(\.text).sorted()
        }.sorted { $0.lexicographicallyPrecedes($1) }
        for anchor in anchors { frame(String(anchor.count)); for value in anchor { frame(value) } }
        return "source-event-v1:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func assumedZone(_ policy: SemanticAppointmentTimePolicy) -> TimeZone? {
        if case .deviceZoneAtRead(let zone) = policy { return zone }
        return nil
    }
    private static func selectedZone(_ text: String,
                                     policy: SemanticAppointmentTimePolicy) -> (zone: TimeZone, abbreviation: String?)? {
        // A printed zone is evidence, not a reason to silently use the device zone.
        // Resolve the Pacific abbreviations exercised by the source-bound ticket.
        // Other abbreviations, including geographically ambiguous CST/EST, stay on review.
        let pattern = "\\b(?:PST|PDT|EST|EDT|CST|CDT|MST|MDT|CET|CEST|BST|IST|JST|AEST|AEDT|AKST|AKDT|HST|UTC|GMT)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let printed = Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]).uppercased() } })
        guard printed.count <= 1 else { return nil }
        if let abbreviation = printed.first {
            let identifiers = ["PST": "America/Los_Angeles", "PDT": "America/Los_Angeles"]
            guard let identifier = identifiers[abbreviation],
                  let zone = TimeZone(identifier: identifier) else { return nil }
            return (zone, abbreviation)
        }
        guard let zone = assumedZone(policy) else { return nil }
        return (zone, nil)
    }
    private static func clock(_ value: String) -> (Int, Int)? {
        let pattern = "^\\s*(1[0-2]|0?[1-9])(?::([0-5][0-9]))?\\s*(AM|PM)(?:\\s+(?:PST|PDT|EST|EDT|CST|CDT|MST|MDT|CET|CEST|BST|IST|JST|AEST|AEDT|AKST|AKDT|HST|UTC|GMT))?\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let hourRange = Range(match.range(at: 1), in: value),
              let meridiemRange = Range(match.range(at: 3), in: value),
              let hour = Int(value[hourRange]) else { return nil }
        let minute = Range(match.range(at: 2), in: value).flatMap { Int(value[$0]) } ?? 0
        let period = value[meridiemRange].uppercased()
        return ((hour % 12) + (period == "PM" ? 12 : 0), minute)
    }
}
