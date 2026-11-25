import Foundation
import IBrain

public enum PinVisitReconstruction {
    public enum Request: Equatable, Sendable {
        case city(String)
        case all
        case allWithReceipts
        case receiptSubset

        public init?(question: String) {
            let text = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
            let lower = text.lowercased()
            if lower == "show all my visits" || lower == "show all the visits you can establish and say which ones have an uncertain receipt match" {
                self = .all
                return
            }
            if lower == "which of my visits have a matching receipt" ||
                lower == "which of my visits have a matching receipt? give the place, the date and what makes each receipt a match" {
                self = .allWithReceipts
                return
            }
            if text.caseInsensitiveCompare("Which of those have receipts") == .orderedSame {
                self = .receiptSubset
                return
            }
            let prefixes = ["What places did I visit in ", "Reconstruct my visits in "]
            guard let prefix = prefixes.first(where: { text.prefix($0.count).caseInsensitiveCompare($0) == .orderedSame })
            else { return nil }
            let city = String(text.dropFirst(prefix.count))
            guard city.count <= 60,
                  PinVisitReconstruction.isLocality(city),
                  city.range(of: #"\b(?:and|or|near|during|last|this|before|after|with|between|since|on|only)\b"#,
                             options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            self = .city(city)
        }
    }

    public struct Detail: Equatable, Sendable {
        public let value: String
        public var anchor: EvidenceAnchor { anchors[0] }
        public let anchors: [EvidenceAnchor]

        fileprivate init(value: String, anchors: [EvidenceAnchor]) {
            self.value = value
            self.anchors = anchors
        }

        fileprivate init(value: String, anchor: EvidenceAnchor) {
            self.init(value: value, anchors: [anchor])
        }
    }

    public struct ReceiptAssociation: Equatable, Sendable {
        public enum Basis: Equatable, Sendable { case sharedReference, sameDateAndVenue }
        public let basis: Basis
        public let anchors: [EvidenceAnchor]
    }

    public struct Card: Equatable, Identifiable, Sendable {
        public var id: SourceReference { visit.anchor.source }
        public let visit: Detail
        public let city: Detail
        public let branch: Detail?
        public let date: Detail?
        public let receipt: Detail?
        public let receiptAssociation: ReceiptAssociation?
        public let receiptAmbiguous: Bool
        public var sources: [SourceReference] {
            var seen = Set<SourceReference>()
            return ([visit.anchor.source, date?.anchor.source, receipt?.anchor.source].compactMap { $0 } +
                    (receiptAssociation?.anchors.map(\.source) ?? []))
                .filter { seen.insert($0).inserted }
        }
    }

    public struct Answer: Sendable {
        public let city: String?
        public let cards: [Card]
        public let receiptsOnly: Bool
        fileprivate let scope: MemoryScope
        public let photoInventory: PinPhotoInventory
    }

    private struct PrintedDate {
        let detail: Detail
        let day: String

        init?(_ detail: Detail?) {
            guard let detail, let day = dateKey(detail.value) else { return nil }
            self.detail = detail
            self.day = day
        }
    }

    private struct VenueDay: Hashable {
        let name: String
        let city: String
        let date: String
    }

    private struct Reading {
        let date: PrintedDate?
        let receiptDate: PrintedDate?
        let receipt: Detail?
        let place: Detail?
        let conflictingPlace: Bool
        let visit: Detail?
        let city: Detail?
        let branch: Detail?
        let hasBranchText: Bool
        let reference: Detail?
        let hasReferenceText: Bool

        init(_ source: SourceSnapshot) {
            var fields: [String: [Detail]] = [:]
            let text = source.observations.filter { $0.kind == .text }
            let heading = text.first.map { key($0.value) }
            let isReceipt = ["receipt", "sales receipt", "digital receipt"].contains(heading ?? "")
            for observation in text {
                let line = observation.value.trimmingCharacters(in: .whitespaces)
                let anchor = EvidenceAnchor(source: source.reference, observationID: observation.id, quote: observation.value)
                if let (venue, city) = visitSentence(line) {
                    fields["visited", default: []].append(Detail(value: venue, anchor: anchor))
                    fields["city", default: []].append(Detail(value: city, anchor: anchor))
                }
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if isReceipt && parts.count == 1,
                   let amount = unlabelledReceiptTotal(line) {
                    fields["total", default: []].append(Detail(value: amount, anchor: anchor))
                }
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                let label = key(String(parts[0]))
                guard !value.isEmpty || label == "visit reference" || label == "branch" || label == "visit date" else { continue }
                fields[label, default: []].append(Detail(value: value, anchor: anchor))
            }
            if heading == "journal" {
                for (label, detail) in journalDetails(text, source: source.reference) {
                    fields[label, default: []].append(detail)
                }
            }
            if isReceipt && fields["place"] == nil && fields["merchant"] == nil {
                for (label, detail) in receiptHeader(text, source: source.reference) {
                    fields[label, default: []].append(detail)
                }
            }
            func unique(_ names: String...) -> Detail? {
                let details = names.flatMap { fields[$0] ?? [] }
                guard Set(details.map { key($0.value) }).count == 1 else { return nil }
                return details.first
            }
            let visitDetail = unique("visited")
            visit = visitDetail
            let explicitDate = fields["visit date"] != nil
            date = PrintedDate(explicitDate ? unique("visit date") : (visitDetail != nil ? unique("date") : nil))
            receiptDate = explicitDate ? date : PrintedDate(unique("transaction date", "purchase date", "date"))
            receipt = isReceipt ? unique("receipt total", "paid total", "total") : unique("receipt total")
            place = isReceipt ? unique("place", "merchant") : unique("place")
            conflictingPlace = place == nil && (fields["place"] != nil || (isReceipt && fields["merchant"] != nil))
            city = unique("city")
            branch = unique("branch").flatMap { $0.value.isEmpty ? nil : $0 }
            hasBranchText = fields["branch"] != nil
            hasReferenceText = fields["visit reference"] != nil
            reference = unique("visit reference").flatMap {
                $0.value.range(of: #"^[A-Z0-9][A-Z0-9-]{3,31}$"#, options: .regularExpression) == nil ? nil : $0
            }
        }

        var visitDay: VenueDay? {
            guard let visit, let city, let date else { return nil }
            return VenueDay(name: key(visit.value), city: key(city.value), date: date.day)
        }

        var receiptDay: VenueDay? {
            guard visit == nil, receipt != nil, let place, let city, let receiptDate else { return nil }
            return VenueDay(name: key(place.value), city: key(city.value), date: receiptDate.day)
        }
    }

    public static func search(city: String? = nil, in evidence: PinEvidenceSnapshot) -> Answer {
        let readings = evidence.authority.sources.map(Reading.init)
        let cityKey = city.map(key)
        let visits = readings.filter { reading in
            guard reading.visit != nil, let observedCity = reading.city else { return false }
            return cityKey == nil || cityKey == key(observedCity.value) ||
                cityKey == observedCity.value.split(separator: ",", maxSplits: 1).first.map { key(String($0)) }
        }
        let byReference = Dictionary(grouping: readings.compactMap { reading in
            reading.reference.map { ($0.value, reading) }
        }, by: { $0.0 })
        let visitsByDay = grouped(visits, by: \.visitDay)
        let receiptsByDay = grouped(readings, by: \.receiptDay)
        let cards = visits.compactMap { reading -> (String, Card)? in
            guard let visit = reading.visit, let observedCity = reading.city else { return nil }
            let observedCityKey = key(observedCity.value)
            let sameReference = reading.reference.flatMap { byReference[$0.value] }?.map(\.1) ?? []
            let matching = sameReference.filter {
                $0.city.map { key($0.value) } == observedCityKey &&
                    ($0.visit ?? $0.place).map { key($0.value) } == key(visit.value)
            }
            let receiptCandidates = matching.filter { $0.visit == nil && $0.receipt != nil &&
                branchesCompatible(reading, $0, requireBoth: false) }
            let referenceVisitCount = matching.filter { $0.visit != nil }.count
            let uniqueReference = referenceVisitCount == 1 && receiptCandidates.count == 1 ? receiptCandidates.first : nil
            let referenceAmbiguous = !receiptCandidates.isEmpty && uniqueReference == nil
            let dates = [reading.date, uniqueReference?.date].compactMap { $0 }
            let date = Set(dates.map(\.day)).count == 1 ? dates.first : nil

            let day = reading.hasReferenceText ? nil : reading.visitDay
            let byDate = (day.flatMap { receiptsByDay[$0] } ?? []).filter {
                !$0.hasReferenceText && branchesCompatible(reading, $0, requireBoth: true)
            }
            let competingVisits = byDate.first.map { receipt in
                (day.flatMap { visitsByDay[$0] } ?? []).filter {
                    branchesCompatible($0, receipt, requireBoth: true)
                }.count
            } ?? 0
            let ambiguous = byDate.count > 1 || (byDate.count == 1 && competingVisits > 1)
            let joined: (Detail, ReceiptAssociation?)?
            if let receipt = reading.receipt, !reading.conflictingPlace,
               reading.place.map({ key($0.value) == key(visit.value) }) != false {
                joined = (receipt, nil)
            } else if let companion = uniqueReference, let receipt = companion.receipt,
                      let visitReference = reading.reference, let receiptReference = companion.reference {
                joined = (receipt, ReceiptAssociation(basis: .sharedReference,
                    anchors: [visitReference.anchor, receiptReference.anchor]))
            } else if byDate.count == 1, competingVisits == 1, let companion = byDate.first,
                      let receipt = companion.receipt, let receiptPlace = companion.place, let receiptCity = companion.city,
                      let visitDate = reading.date, let receiptDate = companion.receiptDate {
                joined = (receipt, ReceiptAssociation(basis: .sameDateAndVenue,
                    anchors: visit.anchors + observedCity.anchors + visitDate.detail.anchors +
                    receiptPlace.anchors + receiptCity.anchors + receiptDate.detail.anchors +
                    (reading.branch?.anchors ?? []) + (companion.branch?.anchors ?? [])))
            } else {
                joined = nil
            }

            return (date?.day ?? "", Card(visit: visit, city: observedCity, branch: reading.branch, date: date?.detail,
                                          receipt: joined?.0, receiptAssociation: joined?.1,
                                          receiptAmbiguous: joined == nil && (ambiguous || referenceAmbiguous || (reading.receipt != nil && reading.conflictingPlace))))
        }.sorted { ($0.0, $0.1.id.id) > ($1.0, $1.1.id.id) }.map(\.1)
        return Answer(city: city, cards: cards, receiptsOnly: false, scope: evidence.scope, photoInventory: evidence.photoInventory)
    }

    private static func grouped(_ readings: [Reading], by keyPath: KeyPath<Reading, VenueDay?>) -> [VenueDay: [Reading]] {
        var groups: [VenueDay: [Reading]] = [:]
        for reading in readings {
            if let day = reading[keyPath: keyPath] { groups[day, default: []].append(reading) }
        }
        return groups
    }

    private static func branchesCompatible(_ visit: Reading, _ receipt: Reading, requireBoth: Bool) -> Bool {
        guard !(visit.hasBranchText && visit.branch == nil),
              !(receipt.hasBranchText && receipt.branch == nil) else { return false }
        let first = visit.branch.map { key($0.value) }
        let second = receipt.branch.map { key($0.value) }
        return first == second || (!requireBoth && (first == nil || second == nil))
    }

    private static let visitAction = #"(?:visited|went to|dined at|ate at|stopped at|stopped by)"#
    private static let localityPattern = #"[\p{L}\p{M}]+(?:[ ’'\-][\p{L}\p{M}]+)*(?:, [\p{L}\p{M}]+(?:[ ’'\-][\p{L}\p{M}]+)*)?"#

    private static func isLocality(_ text: String) -> Bool {
        text.range(of: "^" + localityPattern + "$", options: .regularExpression) != nil
    }

    private static let visitSentencePattern = try! NSRegularExpression(
        pattern: "^(?:I|we) " + visitAction + #" ([\p{L}][\p{L}\p{M}0-9&’' .-]+?) in ("# + localityPattern + #")\.$"#,
        options: .caseInsensitive
    )

    private static func visitSentence(_ line: String) -> (venue: String, city: String)? {
        guard let match = visitSentencePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let name = Range(match.range(at: 1), in: line), let city = Range(match.range(at: 2), in: line)
        else { return nil }
        return (String(line[name]), String(line[city]))
    }

    private static func receiptHeader(_ lines: [SourceObservation], source: SourceReference) -> [(String, Detail)] {
        guard lines.count >= 4 else { return [] }
        let branchLine = lines[2].value.trimmingCharacters(in: .whitespaces)
        guard branchLine.lowercased().hasSuffix(" branch") else { return [] }
        let trim = [lines[1].value, String(branchLine.dropLast(" branch".count)), lines[3].value]
        guard trim.prefix(2).allSatisfy({ $0.range(of: #"^[\p{L}][\p{L}\p{M} &’'-]+$"#, options: .regularExpression) != nil }),
              isLocality(trim[2])
        else { return [] }
        var fields = zip(["place", "branch", "city"], zip(trim, lines[1...3])).map { label, field in
            (label, Detail(value: field.0, anchor: EvidenceAnchor(source: source, observationID: field.1.id, quote: field.1.value)))
        }
        if let date = printedDate(in: lines.dropFirst(4), source: source) {
            fields.append(("date", date))
        }
        return fields
    }

    private static func printedDate(in lines: ArraySlice<SourceObservation>, source: SourceReference) -> Detail? {
        guard let start = lines.first else { return nil }
        let anchor = EvidenceAnchor(source: source, observationID: start.id, quote: start.value)
        if dateKey(start.value) != nil { return Detail(value: start.value, anchor: anchor) }

        // A trailing comma identifies a wrapped month/day line. Require the
        // adjacent observation to be just the printed year.
        let monthAndDay = start.value.trimmingCharacters(in: .whitespaces)
        guard monthAndDay.hasSuffix(","), let last = lines.dropFirst().first,
              last.value.range(of: #"^\h*[0-9]{4}\h*$"#, options: .regularExpression) != nil else { return nil }
        let value = monthAndDay + " " + last.value.trimmingCharacters(in: .whitespaces)
        guard dateKey(value) != nil else { return nil }
        let year = EvidenceAnchor(source: source, observationID: last.id, quote: last.value)
        return Detail(value: value, anchors: [anchor, year])
    }

    private static func unlabelledReceiptTotal(_ line: String) -> String? {
        guard line.range(of: #"^(?i:total) [A-Z]{3} [0-9]+(?:\.[0-9]{2})?$"#,
                         options: .regularExpression) != nil
        else { return nil }
        return String(line.dropFirst("total ".count))
    }

    private static func adjacentJournalVisit(
        _ statement: SourceObservation, _ location: SourceObservation, source: SourceReference
    ) -> [(String, Detail)] {
        let namedLocation = #"^([\p{L}][\p{L}\p{M}0-9&’' .-]+?) branch, ("# + localityPattern + #")\.?$"#
        guard let match = try? NSRegularExpression(pattern: namedLocation, options: .caseInsensitive),
              let parts = match.firstMatch(in: location.value, range: NSRange(location.value.startIndex..., in: location.value)),
              let branchRange = Range(parts.range(at: 1), in: location.value),
              let cityRange = Range(parts.range(at: 2), in: location.value) else { return [] }
        let branch = String(location.value[branchRange])
        let city = String(location.value[cityRange])
        let locationAnchor = EvidenceAnchor(source: source, observationID: location.id, quote: location.value)
        if let stated = visitSentence(statement.value) {
            return [("branch", Detail(value: key(stated.city) == key(city) ? branch : "",
                                      anchor: locationAnchor))]
        }

        let directVisit = "^(?:I|we) " + visitAction +
            #" ([\p{L}][\p{L}\p{M}0-9&’' .-]+?)(?: (?:before|after) (?:breakfast|lunch|dinner|work|school))?\.$"#
        guard let matcher = try? NSRegularExpression(pattern: directVisit, options: .caseInsensitive),
              let visit = matcher.firstMatch(in: statement.value, range: NSRange(statement.value.startIndex..., in: statement.value)),
              let venueRange = Range(visit.range(at: 1), in: statement.value) else { return [] }
        let venue = String(statement.value[venueRange])
        guard venue.range(of: #"\b(?:before|after|near|instead|planned|hoped|wanted|next)\b"#,
                          options: [.regularExpression, .caseInsensitive]) == nil else { return [] }
        let visitAnchor = EvidenceAnchor(source: source, observationID: statement.id, quote: statement.value)
        return [("visited", Detail(value: venue, anchor: visitAnchor)),
                ("branch", Detail(value: branch, anchor: locationAnchor)),
                ("city", Detail(value: city, anchor: locationAnchor))]
    }

    private static func journalDetails(_ lines: [SourceObservation], source: SourceReference) -> [(String, Detail)] {
        var details: [(String, Detail)] = []
        let dates = lines.indices.dropFirst().prefix(4).compactMap { printedDate(in: lines[$0...], source: source) }
        if dates.count == 1, let date = dates.first {
            details.append(("visit date", date))
        }

        let patterns = [
            #"^(?:I|we) (?:went to|visited|ate at|dined at) (.+?) at (?:its|the) (.+?) branch in ([^,.]+?)(?: for [^.]*)?\."#,
            #"^(?:I|we) returned to (.+?), (.+?) branch, ([^,.]+?)(?:, for [^.]*)?\."#,
            #"^(?:I|we) stopped at (.+?)(?: today)?\. (?:I was|we were) at the (.+?) branch in ([^,.]+?)[,.]"#
        ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        for (statement, location) in zip(lines.dropFirst(), lines.dropFirst(2)) {
            details.append(contentsOf: adjacentJournalVisit(statement, location, source: source))
        }
        for i in lines.indices.dropFirst() {
            let candidates = Array(lines[i...].prefix(3))
            let joined = candidates.map(\.value).joined(separator: " ")
            let range = NSRange(joined.startIndex..., in: joined)
            guard let match = patterns.lazy.compactMap({ $0.firstMatch(in: joined, range: range) }).first else { continue }
            for (index, label) in ["visited", "branch", "city"].enumerated() {
                let span = match.range(at: index + 1)
                guard let valueRange = Range(span, in: joined) else { continue }
                let value = String(joined[valueRange])
                guard value.range(of: #"^[\p{L}][\p{L}\p{M}0-9&’' .-]{1,79}$"#, options: .regularExpression) != nil else { continue }
                var start = 0
                let supports = candidates.compactMap { line -> EvidenceAnchor? in
                    let lineRange = NSRange(location: start, length: line.value.utf16.count)
                    start += lineRange.length + 1
                    guard NSIntersectionRange(lineRange, span).length > 0 else { return nil }
                    return EvidenceAnchor(source: source, observationID: line.id, quote: line.value)
                }
                if !supports.isEmpty { details.append((label, Detail(value: value, anchors: supports))) }
            }
        }
        return details
    }

    public static func allWithReceipts(in evidence: PinEvidenceSnapshot) throws -> Answer {
        let visits = search(in: evidence)
        return Answer(city: visits.city, cards: visits.cards.filter { $0.receipt != nil },
                      receiptsOnly: true, scope: visits.scope, photoInventory: visits.photoInventory)
    }

    public static func receiptSubset(of previous: Answer, in evidence: PinEvidenceSnapshot) throws -> Answer {
        guard previous.scope == evidence.scope else { throw PinEvidenceError.staleRecord }
        let current = Dictionary(uniqueKeysWithValues: search(city: previous.city, in: evidence).cards.map { ($0.id, $0) })
        let cards = previous.cards.filter { $0.receipt != nil && current[$0.id] == $0 }
        return Answer(city: previous.city, cards: cards, receiptsOnly: true, scope: previous.scope, photoInventory: evidence.photoInventory)
    }

    private static func key(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func dayFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter
    }

    // Each formatter keeps its fixed pattern across concurrent searches.
    private static let isoDay = dayFormatter("yyyy-MM-dd")
    private static let printedDays = [isoDay] + ["MMMM d, yyyy", "MMM d, yyyy", "d MMMM yyyy", "d MMM yyyy"].map(dayFormatter)

    private static func dateKey(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\h*,\h*"#, with: ", ", options: .regularExpression)
        for formatter in printedDays {
            if let date = formatter.date(from: normalized),
               formatter.string(from: date).caseInsensitiveCompare(normalized) == .orderedSame {
                return isoDay.string(from: date)
            }
        }
        return nil
    }
}
