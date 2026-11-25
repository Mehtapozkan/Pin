import Foundation
/// A bounded continuation of a displayed appointment list. Only question words reach the model.
public enum PinAppointmentClockSearch {
    public struct Request: Sendable {
        public let subject: String
        public let comparison: String
        public let minute: Int?
        public let excludedProvider: String
        public let screenshotsOnly: Bool
        public let role: Role
    }
    public enum Issue: Error { case ambiguousTime, unsupported, unclearClock }
    public enum Role: String, Sendable { case visit, capture }
    public struct Row: Sendable {
        public let sourceID: String
        public let provider: String?
        public let visitMinute: Int?
        public let captureMinute: Int?
        public let screenshot: Bool?
        public init(sourceID: String, provider: String?, visitMinute: Int?, captureMinute: Int?, screenshot: Bool?) {
            self.sourceID = sourceID; self.provider = provider; self.visitMinute = visitMinute
            self.captureMinute = captureMinute; self.screenshot = screenshot
        }
    }
    public static func owns(_ question: String) -> Bool {
        question.range(of: #"^\s*(?:of|among)\s+(?:those|these)\s+appointments\b"#, options: [.regularExpression, .caseInsensitive]) != nil &&
        question.range(of: #"\b(?:before|after|later|earlier)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Unconsumed clauses do not execute. Known practice names come from the displayed records.
    public static func parse(_ question: String, providers: [String]) throws -> Request {
        let pattern = #"^\s*(?:of|among) (?:those|these) appointments,?\s+(?:which|what) (.+?) (before|after|at or before|at or after|no later than|no earlier than) (1[0-2]|0?[1-9]):([0-5][0-9])\s*(am|pm)?\s*,\s*(?:excluding|except) ([^?!.]+?)\s*[?!.]\s*(?:show (?:me )?(?:the|their) originals[.!]?)?\s*$"#
        let source = question as NSString
        guard let match = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            .firstMatch(in: question, range: NSRange(location: 0, length: source.length)) else { throw Issue.unsupported }
        func group(_ i: Int) -> String {
            match.range(at: i).location == NSNotFound ? "" : source.substring(with: match.range(at: i)).lowercased()
        }
        let subject = group(1), name = group(6).trimmingCharacters(in: .whitespaces)
        guard let role = clock(of: subject), providers.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw Issue.unsupported
        }
        let hour = Int(group(3))!, minute = Int(group(4))!
        let cutoff = group(5).isEmpty ? nil : (hour % 12 + (group(5) == "pm" ? 12 : 0)) * 60 + minute
        return Request(subject: subject, comparison: group(2), minute: cutoff, excludedProvider: name,
                       screenshotsOnly: subject.contains("screenshot"), role: role)
    }
    // Accept a complete, explicit clock expression. A second condition cannot hide in the subject.
    private static func clock(of phrase: String) -> Role? {
        let capture = #"^(?:(?:screenshots?|photos?|pictures?|images?) (?:did i (?:take|capture)|(?:were|was) (?:taken|captured))|(?:i )?(?:took|captured) (?:the )?(?:screenshots?|photos?|pictures?|images?))$"#
        let visit = #"^(?:(?:visits?|appointments?|bookings?) (?:start(?:s|ed)?|begin(?:s)?|began)|(?:were|are) scheduled to (?:start|begin))$"#
        if phrase.range(of: capture, options: [.regularExpression, .caseInsensitive]) != nil { return .capture }
        if phrase.range(of: visit, options: [.regularExpression, .caseInsensitive]) != nil { return .visit }
        return nil
    }
    public static func select(_ rows: [Row], request: Request, role: Role) throws -> (ids: [String], unresolved: Int) {
        guard let cutoff = request.minute else { throw Issue.ambiguousTime }
        guard role == clock(of: request.subject) else { throw Issue.unclearClock }
        var ids: [String] = [], seen = Set<String>(), unresolved = 0
        for row in rows {
            if request.screenshotsOnly && row.screenshot == false { continue }
            if row.provider?.caseInsensitiveCompare(request.excludedProvider) == .orderedSame { continue }
            guard let provider = row.provider, !provider.isEmpty, !request.screenshotsOnly || row.screenshot == true,
                  let value = role == .visit ? row.visitMinute : row.captureMinute else { unresolved += 1; continue }
            let matches: Bool
            switch request.comparison {
            case "before": matches = value < cutoff
            case "after": matches = value > cutoff
            case "at or before", "no later than": matches = value <= cutoff
            case "at or after", "no earlier than": matches = value >= cutoff
            default: throw Issue.unsupported
            }
            if matches && seen.insert(row.sourceID).inserted { ids.append(row.sourceID) }
        }
        return (ids, unresolved)
    }
}
