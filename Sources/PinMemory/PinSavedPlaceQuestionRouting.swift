import Foundation

/// Owns recognized saved-place requests even when a requested constraint cannot be applied.
public enum PinSavedPlaceQuestionRouting {
    public static func owns(_ question: String, hasDisplayedPlaces: Bool) -> Bool {
        if PinSavedPlaceIntent.explicit(question, hasDisplayedPlaces: hasDisplayedPlaces) != nil { return true }
        if hasDisplayedPlaces, PinSavedPlaceIntent.targetsDisplayedPlaces(question) { return true }

        let text = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let savedQuestion = #"^(?:what|which) (?:caf[eé]s|restaurants|places) (?:did i save|have i saved)(?: to (?:try|visit))? in\b"#
        let savedCommand = #"^(?:show me|show|pull up) (?:the |my )?(?:caf[eé]s|restaurants|places) i (?:saved(?: to (?:try|visit))? in|put on my)\b"#
        let shortlist = #"^(?:(?:can|could|would) you )?(?:pull up|show(?: me)?|find) (?:the |my )?(?:caf[eé]s|restaurants|places) i (?:meant|wanted|saved) to try\s+in\b"#
        let previous = #"^(?:from|of|among) (?:those|these|that|the previous)(?: [\p{L}\p{M}.'’-]+){0,3} (?:results|places|list|picks|caf[eé]s|restaurants)\b"#
        if text.range(of: previous, options: [.regularExpression, .caseInsensitive]) != nil {
            return hasDisplayedPlaces
        }
        return [savedQuestion, savedCommand, shortlist].contains {
            text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    public static func usesScreenshotScope(_ question: String) -> Bool {
        question.range(of: #"\bscreenshots?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
