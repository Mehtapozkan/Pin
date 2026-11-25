import Foundation

enum ItinerarySourceRequest: String {
    case live, boardPhoto, amendment, original, savedCollection, effective, unspecified

    // Only for an already-established itinerary query. Other language keeps the
    // existing intent interpreter. The caller checks reference and source identity.
    static func explicit(in question: String) -> Self {
        let normalized = question.lowercased().replacingOccurrences(of: "’", with: "'")
        let clauses = normalized.components(separatedBy: CharacterSet(charactersIn: ".,;?!"))
        let board = #"\b(?:(?:station|platform|departure) (?:board|display|screen)s?|live board)\b"#
        let notice = #"\b(?:saved|change|updated|revised) (?:train |ticket )?(?:notice|amendment)s?\b"#
        let evidence = #"\b(?:use|using|read|from|according to|given in|printed on|stated in)\b"#
        var requests = Set<Self>()
        for (index, clause) in clauses.enumerated() {
            func has(_ pattern: String) -> Bool {
                clause.range(of: pattern, options: .regularExpression) != nil
            }
            let negated = has(#"\b(?:ignore|disregard|don't|do not|can't|cannot|even if|rather than|instead of)\b"#)
            // A current-world request takes precedence over a saved reference in
            // introductory material. Urgency ("I need this now") is insufficient.
            if !negated && has(#"\b(?:still correct|still accurate|still valid) (?:right )?now\b"#) {
                return .live
            }
            // A past notice cannot establish a change observed since it was saved.
            if has(#"\b(?:did|has|have)\b.*\b(?:changed?|moved?|delayed?|announced?)\b.*\b(?:since|after)\b.*\b(?:saved|screenshot|notice|announcement)\b"#)
                && !negated && !has(#"\b(?:according to|from my|from the|compare|using)\b"#) {
                return .live
            }
            // An operating-status question needs an observation made now.
            // "I need the itinerary today" does not request that observation.
            let operating = #"^\s*(?:is|are)\b[^;?!]*\b(?:running|operating) (?:on time|on schedule|to schedule)\b"#
            if !negated, has(operating), has(#"\b(?:still|today|now|at the moment|currently)\b"#) {
                let next = clauses.dropFirst(index + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let withdrawn = next?.range(of: #"^\s*(?:that is|that's|this is) not (?:what|my question)"#, options: .regularExpression) != nil
                if !withdrawn { return .live }
            }
            if has(board) && !negated {
                if has(#"\b(?:photo|screenshot|picture)\b"#) {
                    requests.insert(.boardPhoto)
                } else if has(#"\b(?:live|currently|this minute|right now|showing now|at the moment|as we speak)\b"#) {
                    return .live
                }
            }
            // An explicit instruction governs its own object, including when an
            // earlier phrase in the sentence tells us to ignore another version.
            if let action = clause.range(of: evidence, options: [.regularExpression, .backwards]) {
                let prefix = String(clause[..<action.lowerBound])
                let object = String(clause[action.upperBound...])
                let deniesAction = prefix.range(of: #"(?:do not|don't|never|cannot|can't)\s*$"#, options: .regularExpression) != nil
                if !deniesAction {
                    let end = object.range(of: #"\b(?:even if|instead of|rather than|and ignore|but ignore)\b"#,options:.regularExpression)?.lowerBound ?? object.endIndex
                    let source = String(object[..<end])
                    if source.range(of: notice, options: .regularExpression) != nil { requests.insert(.amendment) }
                    if source.range(of: #"\boriginal (?:rail |train )?ticket\b"#, options: .regularExpression) != nil { requests.insert(.original) }
                }
            }
        }
        if requests.count == 1, let source = requests.first { return source }
        let priorVersion = #"\b(?:original|initial|first|before|previous|prior|former|earlier|old|issued|purchase|bought|paid|historical|then|at the time|back then|as printed)\b"#
        // An instruction to incorporate the saved revisions selects the effective
        // documents. Historical, negated or live questions still need interpretation.
        let includeChanges = #"\b(?:with|including|incorporating|applying) (?:all |the |my )*(?:saved|documented|recorded) (?:changes|updates|revisions)\b"#
        let conflictingIntent = #"\b(?:without|not|never|exclude|excluded|excluding|ignore|ignored|ignoring|disregard|except|omit|live|currently|now)\b|n't\b"#
        if requests.isEmpty,
           normalized.range(of: includeChanges, options: .regularExpression) != nil,
           normalized.range(of: priorVersion, options: .regularExpression) == nil,
           normalized.range(of: conflictingIntent, options: .regularExpression) == nil {
            return .effective
        }
        if requests.isEmpty, normalized.contains("from what i saved"),
           normalized.range(of: priorVersion, options: .regularExpression) == nil {
            return .savedCollection
        }
        return .unspecified
    }
}
