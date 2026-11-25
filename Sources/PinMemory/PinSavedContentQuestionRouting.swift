import Foundation

/// Claims requests about saved ideas and follow-ups to the current saved answer.
/// Interpretation and evidence admission still belong to the saved-content engine.
public enum PinSavedContentQuestionRouting {
    public static func owns(_ question: String, hasDisplayedAnswer: Bool) -> Bool {
        let text = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!")).lowercased()
        if matches(#"^(?:(?:can|could|would) you )?(?:show|list|find|recall) (?:me )?(?:the |my )?(?:saved ideas\b|ideas i (?:saved|kept)\b)"#, in: text) ||
            matches(#"^(?:what|which)\b.*\bideas\b.*\b(?:did i (?:save|keep)|have i (?:saved|kept)|are in my saved photos)\b"#, in: text) {
            return true
        }
        guard hasDisplayedAnswer else { return false }
        return matches(#"^(?:(?:which|any) (?:one |ones )?of (?:those|these)|(?:of|from|among) (?:those|these)\b|(?:open|show) (?:me )?(?:(?:that|this|the) (?:photo|original)|all (?:the )?(?:photos|originals)))\b"#, in: text)
    }

    /// Recognizes the operation for a single explicit request to recall saved ideas.
    /// The original question still goes to the evidence reader with every topic word.
    static func isExplicitIdeaSearch(_ question: String) -> Bool {
        let text = question.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let word = #"\p{L}+(?:-\p{L}+)*"#
        let pattern = #"^(?:what|which) ((?:"# + word + #" ){0,5})ideas did i (?:save|keep)(?: for ((?:"# + word + #" ){0,7}"# + word + #"))?\??$"#
        guard text.utf8.count <= 600,
              let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return false }
        let topicParts = (1...2).compactMap { group -> Substring? in
            Range(match.range(at: group), in: text).map { text[$0] }
        }
        let contextualOrComplex: Set<Substring> = [
            "and", "or", "but", "with", "without", "except", "excluding", "not", "no", "only",
            "from", "since", "before", "after", "between", "during", "on", "in", "until",
            "this", "that", "these", "those", "same", "previous", "other", "them", "it", "my", "our",
            "all", "any", "each", "first", "last", "latest", "earliest", "recent", "past", "next",
            "today", "yesterday", "tomorrow", "when", "where", "how", "compare", "count", "literally"
        ]
        return topicParts.flatMap { $0.split(separator: " ") }
            .allSatisfy { !contextualOrComplex.contains($0) }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
