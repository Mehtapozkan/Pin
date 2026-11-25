import Foundation
import IBrainRetrieval

/// The explicit English saved-place requests Pin can execute without asking a
/// model to choose an operation. A contextual phrase requires a displayed
/// result and never becomes a new city search.
public enum PinSavedPlaceIntent: Equatable, Sendable {
    case saved(city: String, category: String?)
    case savedExcluding(city: String, category: String?, name: String)
    case neighborhoodExcluding(String, name: String)
    case filterDisplayed(area: String, category: String, excluding: String)
    case visited(city: String, category: String?)
    case neighborhood(String)
    case priorVisits
    case needsDisplayedPlaces

    private static let retainDisplayedPrefix =
        #"^(?:keep|show|list) (?:(?:just|only) )?(?:the ones|those|these results) (?:in|around) "#
    private static let displayedSource =
        #"(?:from (?:that list|(?:those|these) (?:places|results))|of the places you just listed)"#

    public static func targetsDisplayedPlaces(_ question: String) -> Bool {
        let text = normalized(question)
        return matches(text, "^" + displayedSource + "[,:]") != nil ||
            matches(text, #"^which(?: of (?:these|those))? (?:are\b|did i visit\b)"#) != nil ||
            matches(text, retainDisplayedPrefix) != nil
    }

    public static func explicit(_ question: String, hasDisplayedPlaces: Bool) -> Self? {
        let text = normalized(question)
        if let parts = matches(text, retainDisplayedPrefix +
                #"(.+?)(?:,?\s+(?:and|but) (?:leave out|omit|skip|exclude) (.+))?$"#),
           let area = location(parts[0]),
           matches(area, #"\b(?:before|after|last|next|closest|nearest|open now)\b"#) == nil {
            if parts[1].isEmpty { return hasDisplayedPlaces ? .neighborhood(area) : .needsDisplayedPlaces }
            guard let name = location(parts[1]) else { return nil }
            return hasDisplayedPlaces ? .neighborhoodExcluding(area, name: name) : .needsDisplayedPlaces
        }
        if let parts = matches(text, "^" + displayedSource +
                #"[,:] keep (?:the )?(.+?) (caf[eé]s|restaurants) and (?:leave out|omit|exclude) (.+)$"#),
           let area = location(parts[0]), let category = category(parts[1]), let name = location(parts[2]) {
            return hasDisplayedPlaces ? .filterDisplayed(area: area, category: category, excluding: name) : .needsDisplayedPlaces
        }
        let clauses = [
            #"^(.+?),?\s+except\s+(.+)$"#,
            #"^(.+?[.!?])\s+(?:leave\s+(.+?)\s+out)$"#,
            #"^(.+?[.!?])\s+(?:omit|exclude)\s+(.+)$"#
        ]
        for pattern in clauses {
            guard let parts = matches(text, pattern) else { continue }
            guard let name = location(parts[1]), let base = explicitBase(parts[0], hasDisplayedPlaces: hasDisplayedPlaces)
            else { return nil }
            switch base {
            case .saved(let city, let category): return .savedExcluding(city: city, category: category, name: name)
            case .neighborhood(let area): return .neighborhoodExcluding(area, name: name)
            case .needsDisplayedPlaces: return base
            default: return nil
            }
        }
        return explicitBase(text, hasDisplayedPlaces: hasDisplayedPlaces)
    }

    private static func explicitBase(_ question: String, hasDisplayedPlaces: Bool) -> Self? {
        let text = normalized(question)
        if matches(text, #"^which of (?:these|those) did i visit\??$"#) != nil {
            return hasDisplayedPlaces ? .priorVisits : .needsDisplayedPlaces
        }
        if let parts = matches(text, "^(?:" + displayedSource +
                #"[,:]\s+)?which(?: of (?:these|those))? are (?:in|around) (.+?)\??$"#),
           let named = location(parts[0]) {
            return hasDisplayedPlaces ? .neighborhood(named) : .needsDisplayedPlaces
        }
        if let parts = matches(text, #"^which (restaurants|caf[eé]s|places) (?:did i (?:actually )?visit|do my photos say i actually went to) in (.+?)\??$"#),
           let named = location(parts[1]) {
            return .visited(city: named, category: category(parts[0]))
        }
        if let parts = matches(text, #"^(?:what|which) (?:(restaurants|caf[eé]s|places) )?(?:did i save|have i saved) in (.+?)\??$"#),
           let named = location(parts[1]) {
            return .saved(city: named, category: category(parts[0]))
        }
        if let parts = matches(text, #"^(?:show me|show|pull up) (?:the |my )?(restaurants|caf[eé]s|places) i (?:saved in (.+?)|put on my (.+?) shortlist)\.?$"#),
           let named = location(parts[1].isEmpty ? parts[2] : parts[1]) {
            return .saved(city: named, category: category(parts[0]))
        }
        return nil
    }

    private static func normalized(_ question: String) -> String {
        question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
    }

    public func answer(in catalog: SavedPlaceCatalog, displayed: SavedPlaceDisplayedContext?, requestID: UUID) throws -> SavedPlaceAnswer {
        switch self {
        case .saved(let city, let category):
            return try catalog.savedPlaces(in: city, category: category, requestID: requestID)
        case .savedExcluding(let city, let category, let name):
            return try catalog.savedPlaces(in: city, category: category, excluding: name, requestID: requestID)
        case .neighborhoodExcluding(let area, let name):
            guard let displayed else { throw SavedPlaceError.staleDisplayedContext }
            return try catalog.refine(displayed, parentRequestID: displayed.answerRequestID,
                                      neighborhood: area, excluding: name, requestID: requestID)
        case .visited(let city, let category):
            return try catalog.visits(in: city, category: category, requestID: requestID)
        case .neighborhood(let name):
            guard let displayed else { throw SavedPlaceError.staleDisplayedContext }
            return try catalog.refine(displayed, parentRequestID: displayed.answerRequestID,
                                      neighborhood: name, requestID: requestID)
        case .filterDisplayed(let area, let category, let name):
            guard let displayed else { throw SavedPlaceError.staleDisplayedContext }
            return try catalog.refine(displayed, parentRequestID: displayed.answerRequestID,
                                      neighborhood: area, category: category, excluding: name, requestID: requestID)
        case .priorVisits:
            guard let displayed else { throw SavedPlaceError.staleDisplayedContext }
            return try catalog.visits(in: displayed, parentRequestID: displayed.answerRequestID, requestID: requestID)
        case .needsDisplayedPlaces:
            throw SavedPlaceError.staleDisplayedContext
        }
    }

    private static func location(_ text: String) -> String? {
        guard text.count <= 80,
              matches(text, #"^[\p{L}\p{M}][\p{L}\p{M}\p{Nd} .'’\-]*$"#) != nil,
              matches(text, #"\b(?:and|or|with|without|within|near|except|that|which|under|over)\b"#) == nil else {
            return nil
        }
        return text
    }

    private static func category(_ text: String) -> String? {
        switch text.lowercased() {
        case "restaurants": "restaurant"
        case "cafes", "cafés": "cafe"
        default: nil
        }
    }

    private static func matches(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
