import Foundation
import PinCore

struct RailItinerary {
    enum Document: String {
        case notice = "Service update"
        case board = "Departure board snapshot"
        case ticket = "Rail ticket"
        case flight = "Flight confirmation"
        case hotel = "Hotel confirmation"

        var label: String {
            switch self {
            case .notice: "Change notice"
            case .board: "Departure board"
            case .ticket: "Rail ticket"
            case .flight: "Flight confirmation"
            case .hotel: "Hotel confirmation"
            }
        }
    }
    struct Record {
        let kind: Document
        let fields: [String: String]
        let photo: PhotoMemory

        init?(_ photo: PhotoMemory) {
            let lines = photo.text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let kind = Document.all(in: lines) else { return nil }
            var fields: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard fields[key] == nil else { return nil }
                if !value.isEmpty { fields[key] = value }
            }
            self.kind = kind
            self.fields = fields
            self.photo = photo
        }
    }
    struct Row: Identifiable {
        let kind: Document
        let detail: String
        let photo: PhotoMemory?
        var id: String { kind.rawValue }
    }
    let id = UUID()
    let booking: String
    var rows: [Row] = []
    var summary: String?
    var needsModel = false

    static func answer(_ question: String, photos: [PhotoMemory], decision: NativItinerary.Decision? = nil) -> Self? {
        let q = question.lowercased()
        let railIDs = Set(q.matches(of: #/\br\d{3}\b/#).map { String($0.output).uppercased() })
        let flights = Set(q.matches(of: #/\b[a-z]{2}\d{2,4}\b/#).map { String($0.output).uppercased() })
        guard !railIDs.isEmpty, !flights.isEmpty || ["itinerary", "train", "rail", "notice", "board", "platform", "departure"].contains(where: q.contains) else { return nil }
        var result = Self(booking: railIDs.sorted().joined(separator: ", "))
        guard railIDs.count == 1, flights.count <= 1 else { result.summary = "Which rail booking should I use?"; return result }
        let policy = ItinerarySourceRequest.explicit(in: question)
        guard policy != .live else { result.summary = "Saved photos can’t confirm live train status."; return result }

        let mentionsBoard = q.contains("board") || q.contains("station display")
        let comparison = q.contains("compare") || q.contains("side by side") || q.contains("both")
        let adjacent = q.range(of: #"\b(?:notice|board) and (?:the |my )?(?:departure board|change notice)\b"#, options: .regularExpression) != nil
        let both = mentionsBoard && q.contains("notice") && (comparison || adjacent)
        let requiresPolicy = !both && (policy == .unspecified || policy == .savedCollection)
        if requiresPolicy && decision == nil {
            result.needsModel = true
            result.summary = "Checking your itinerary…"
            return result
        }
        if decision == .external {
            result.summary = "Saved photos can’t confirm live train status."
            return result
        }
        let original = policy == .original || (policy == .unspecified && decision == .archive)
        let full = q.contains("itinerary") || q.contains("hotel") || q.contains("lodging") ||
            !flights.isEmpty
        let records = photos.compactMap(Record.init)
        let booking = result.booking
        func append(_ kind: Document, key: String, value: String, details: [String]) -> Record? {
            let matches = records.filter { $0.kind == kind && $0.fields[key]?.caseInsensitiveCompare(value) == .orderedSame }
            guard matches.count == 1, let source = matches.first else {
                let message = matches.isEmpty ? "No matching photo found." : "Several photos match. The source is unclear."
                result.rows.append(Row(kind: kind, detail: message, photo: nil))
                return nil
            }
            let text = details.compactMap { field in source.fields[field].map { field.capitalized + " · " + $0 } }.joined(separator: "\n")
            result.rows.append(Row(kind: kind, detail: text.isEmpty ? "Detail unclear in this photo." : text, photo: source.photo))
            return source
        }
        let boardOnly = policy == .boardPhoto && !both
        var change: Record?
        if !boardOnly && !original {
            change = append(.notice, key: "booking", value: booking, details: ["new departure","platform"])
        }
        if policy == .amendment && change == nil && !both { return result }
        if boardOnly || both {
            _ = append(.board, key: "booking", value: booking, details: ["observed","platform"])
        }
        if (full && !boardOnly) || original {
            let ticket = append(.ticket, key: "booking", value: booking, details: ["to", "departure", "platform"])
            if ticket == nil && original { return result }
            if full, let city = ticket?.fields["to"] {
                _ = append(.hotel, key: "city", value: city, details: ["property"])
            }
            if full, flights.count == 1, let flight = flights.first {
                let inbound = append(.flight, key: "flight", value: flight, details: ["arrival"])
                let updates = records.filter { $0.kind == .notice && $0.fields["booking"]?.uppercased() == booking }
                let ticketAllowed = original || (updates.isEmpty && policy != .amendment)
                let departure = ticketAllowed ? ticket?.fields["departure"] : change?.fields["new departure"]
                if let arrival = inbound?.fields["arrival"], let departure {
                    let clock = DateFormatter()
                    clock.locale = Locale(identifier: "en_US_POSIX")
                    clock.timeZone = TimeZone(secondsFromGMT: 0)
                    clock.dateFormat = "yyyy-MM-dd HH:mm"
                    if let a = clock.date(from: arrival), let b = clock.date(from: departure), b >= a {
                        result.summary = "\(Int(b.timeIntervalSince(a) / 60)) minutes between the recorded arrival and departure."
                    }
                }
            }
        }
        return result
    }
}

private extension RailItinerary.Document {
    static func all(in lines: [String]) -> Self? {
        let kinds: [Self] = [.notice,.board,.ticket,.flight,.hotel]
        let found = kinds.filter { kind in lines.contains { $0.caseInsensitiveCompare(kind.rawValue) == .orderedSame } }
        return found.count == 1 ? found.first : nil
    }
}

