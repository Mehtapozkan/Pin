import Foundation

/// These are photo metadata periods, never the dates printed in a booking.
public enum PhotoCapturePeriod: String, Codable, Sendable {
    case all, today, yesterday, tomorrow, thisWeek, lastWeek, nextWeek, unsupported
}
public enum PhotoMediaSelection: String, Codable, Sendable {
    case any, screenshots, nonScreenshots
}
public struct PhotoQueryRequest: Codable, Equatable, Sendable {
    public var capturePeriod: PhotoCapturePeriod
    public var recognizedText: String?
    public var media: PhotoMediaSelection
    public init(capturePeriod: PhotoCapturePeriod = .all, recognizedText: String? = nil,
                media: PhotoMediaSelection = .any) {
        self.capturePeriod = capturePeriod; self.recognizedText = recognizedText; self.media = media
    }
}

/// A fixed native operation. The date range is resolved once for the submitted
/// answer; foreground reconciliation does not move it to a new day or week.
public struct PhotoQueryPlan: Equatable, Sendable {
    public let request: PhotoQueryRequest
    public let captureInterval: DateInterval?
    public let calendar: Calendar
    fileprivate init(request: PhotoQueryRequest, captureInterval: DateInterval?, calendar: Calendar) {
        self.request = request; self.captureInterval = captureInterval; self.calendar = calendar
    }
}
public enum PhotoQueryCompiler {
    public static func compile(_ request: PhotoQueryRequest, now: Date, calendar: Calendar) -> PhotoQueryPlan? {
        guard request.capturePeriod != .unsupported, now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        if let phrase = request.recognizedText {
            guard !PhotoQueryExecutor.normalizedText(phrase).isEmpty, phrase.utf8.count <= 4096 else { return nil }
        }
        let interval: DateInterval?
        switch request.capturePeriod {
        case .all: interval = nil
        case .today, .yesterday, .tomorrow:
            let offset = request.capturePeriod == .yesterday ? -1 : request.capturePeriod == .tomorrow ? 1 : 0
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let range = calendar.dateInterval(of: .day, for: day) else { return nil }
            interval = range
        case .thisWeek, .lastWeek, .nextWeek:
            let offset = request.capturePeriod == .lastWeek ? -1 : request.capturePeriod == .nextWeek ? 1 : 0
            guard let day = calendar.date(byAdding: .weekOfYear, value: offset, to: now),
                  let range = calendar.dateInterval(of: .weekOfYear, for: day) else { return nil }
            interval = range
        case .unsupported: return nil
        }
        if let interval {
            guard interval.start.timeIntervalSinceReferenceDate.isFinite,
                  interval.end.timeIntervalSinceReferenceDate.isFinite, interval.duration > 0 else { return nil }
        }
        return PhotoQueryPlan(request: request, captureInterval: interval, calendar: calendar)
    }
}

public struct PhotoQueryResult: Equatable, Sendable {
    public let hits: [RecallHit]
    /// Disjoint reasons that a read observation could not be checked. A missing
    /// field never becomes a guessed match. These are not library completeness.
    public let withoutRecognizedText: Int
    public let withoutScreenshotStatus: Int
    public let withoutPhotoDate: Int
}
public enum PhotoQueryExecutor {
    /// Literal OCR substring after canonical Unicode/whitespace normalization.
    /// Case is ignored, accents and punctuation are preserved; labels, inferred
    /// appointment fields and arbitrary search tokens are not text evidence.
    public static func normalizedText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ").lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    public static func execute(_ plan: PhotoQueryPlan, in memories: [PhotoMemory]) -> PhotoQueryResult {
        let phrase = plan.request.recognizedText.map(normalizedText)
        var matches: [PhotoMemory] = [], noText = 0, noType = 0, noDate = 0
        for memory in memories {
            let dateMatches: Bool?
            if let interval = plan.captureInterval {
                if let date = memory.photographedAt, date.timeIntervalSinceReferenceDate.isFinite {
                    // Adjacent query windows are explicitly half-open.
                    dateMatches = date >= interval.start && date < interval.end
                } else { dateMatches = nil }
            } else { dateMatches = true }
            guard dateMatches != false else { continue }
            let mediaMatches: Bool? = plan.request.media == .any ? true
                : memory.isScreenshot.map { $0 == (plan.request.media == .screenshots) }
            guard mediaMatches != false else { continue }
            let textMatches: Bool?
            if let phrase {
                let text = normalizedText(memory.text.joined(separator: "\n"))
                textMatches = text.isEmpty ? nil : text.contains(phrase)
            } else { textMatches = true }
            guard textMatches != false else { continue }
            // A known mismatch already excludes the source, even when another
            // field is unknown. Only potentially matching sources contribute
            // to the disjoint missing-detail counts.
            guard textMatches != nil else { noText += 1; continue }
            guard mediaMatches != nil else { noType += 1; continue }
            guard dateMatches != nil else { noDate += 1; continue }
            matches.append(memory)
        }
        let hits = matches.sorted {
            let a = $0.photographedAt.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil } ?? .distantPast
            let b = $1.photographedAt.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil } ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }.map { RecallHit(memory: $0, score: 1) }
        return PhotoQueryResult(hits: hits, withoutRecognizedText: noText,
            withoutScreenshotStatus: noType, withoutPhotoDate: noDate)
    }
}
extension MemoryStore {
    /// Start with the actor's current permitted, versioned, nonforgotten records.
    public func photos(matching plan: PhotoQueryPlan) -> PhotoQueryResult {
        PhotoQueryExecutor.execute(plan, in: all())
    }
}

/// A bounded compositional grammar for explicit photo date/literal-text
/// requests. It consumes every outside-quote word. It is not a general question
/// interpreter, a topic recognizer, or a semantic rescue of model output.
public enum PhotoQuestion {
    public enum ExplicitRequest: Equatable, Sendable {
        case photos(PhotoQueryRequest)
        case unsupported
    }
    /// An explicit object-photo lookup keeps the existing native recall route.
    /// Qualified date/text requests are handled by explicitRequest, including
    /// unsupported combinations; this never routes an appointment fact query.
    public static func isExplicitObjectRecall(_ question:String)->Bool {
        guard explicitRequest(question)==nil else{return false}
        return match(#"^(?:(?:find|show|show me|find me|look for)\s+)?(?:(?:my|the|all)\s+)?(?:photos?|pictures?|images?)\s+(?:of|showing)\s+\S.*$"#,question.trimmingCharacters(in:.whitespacesAndNewlines)) != nil
    }
    public static func explicitRequest(_ question: String) -> ExplicitRequest? {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let subject = match(#"^(?:(?:find|show|show me|find me|which|what|look for)\s+)?(?:(?:my|the|all)\s+)?(photos?|pictures?|screenshots?|images?)\b(.*)$"#, value) else { return nil }
        let media: PhotoMediaSelection = subject[1].lowercased().hasPrefix("screenshot") ? .screenshots : .any
        var rest = subject[2].trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the existing object recall path for ordinary, unqualified photo
        // questions. Once this grammar's conditions are requested, no leftover
        // word may disappear into that lexical fallback.
        let dateCue = rest.range(of: #"\b(?:today|yesterday|tomorrow|week|month|year|taken|captured|dated|saved|took|since|until|before|after|between|recent|recently|January|February|March|April|May|June|July|August|September|October|November|December|[12][0-9]{3})\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let quoteCue = rest.contains("\"") || rest.contains("“") || rest.contains("”") || rest.filter { $0 == "'" }.count >= 2
        let textCue = rest.range(of: #"\b(?:containing|contains?|saying)\b|\b(?:with|whose)\s+(?:the\s+)?(?:text|words|phrase)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        // A plain "photo with <phrase>" searches for the whole unquoted phrase.
        // Explicit text or date clauses still go through the compositional grammar.
        if !quoteCue, !dateCue, !textCue,
           let phrase = match(#"^with\s+(\S.*?)\s*\??$"#, rest)?[1],
           phrase.rangeOfCharacter(from: .alphanumerics) != nil {
            return .photos(PhotoQueryRequest(recognizedText: phrase, media: media))
        }
        guard media != .any || dateCue || quoteCue || textCue else { return nil }
        var phrase: String?
        if quoteCue {
            let pattern = #"\b(?:containing(?:\s+(?:the\s+)?(?:words|text|phrase))?|with(?:\s+(?:the\s+)?(?:words|phrase|text(?:\s+containing)?))?|(?:that|which)\s+(?:says?|contains?)|saying)\s+(?:"([^"]+)"|“([^”]+)”|'([^']+)')"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return .unsupported }
            let matches = regex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest))
            guard matches.count == 1, let found = matches.first else { return .unsupported }
            let ns = rest as NSString
            guard let range = (1...3).map({ found.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { return .unsupported }
            phrase = ns.substring(with: range)
            rest = ns.replacingCharacters(in: found.range, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.contains("\""), !rest.contains("“"), !rest.contains("”") else { return .unsupported }
        }
        let trimmed = rest.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        let period: PhotoCapturePeriod
        if trimmed.isEmpty { period = .all }
        else {
            let pattern = #"^(?:and\s+)?(?:(?:(?:that\s+)?I\s+(?:took|saved)|did\s+I\s+take|(?:that\s+)?(?:were|are)\s+(?:taken|saved)|taken|captured|saved|dated|from)(?:\s+(?:on|in))?\s+)?(today|yesterday|tomorrow|this\s+week|last\s+week|next\s+week)(?:\s+and)?$"#
            guard let date = match(pattern, trimmed) else { return .unsupported }
            switch date[1].lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") {
            case "today": period = .today
            case "yesterday": period = .yesterday
            case "tomorrow": period = .tomorrow
            case "this week": period = .thisWeek
            case "last week": period = .lastWeek
            case "next week": period = .nextWeek
            default: return .unsupported
            }
        }
        return .photos(PhotoQueryRequest(capturePeriod: period, recognizedText: phrase, media: media))
    }
    private static func match(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let result = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let ns = value as NSString
        return (0..<result.numberOfRanges).map { result.range(at: $0).location == NSNotFound ? "" : ns.substring(with: result.range(at: $0)) }
    }
}
