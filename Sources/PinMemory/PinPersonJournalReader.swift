import Foundation
import IBrain
import IBrainRetrieval

enum PinPersonJournalReader {
    private static let datePattern =
        #"\b[0-9]{1,2}\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+[0-9]{4}\b"#

    static func read(person: String, from source: SourceSnapshot) -> PersonPlanEvidence? {
        let lines = source.observations.filter { $0.kind == .text }
        guard lines.count <= 35, lines.first?.value.caseInsensitiveCompare("Journal") == .orderedSame else { return nil }
        let name = NSRegularExpression.escapedPattern(for: person)
        let boundary = #"(?![\p{L}\p{M}\p{N}'’-])"#
        let patterns: [(String, Bool, PersonPlanRole)] = [
            ("^(" + name + ")" + boundary + #" and (?:I|we) (?:are going to|planned) (?:the )?(.+?)(?: on "# +
                datePattern + #"|[.!])"#, true, .included),
            (#"^I (?:suggested|proposed|planned) (.+?) with ("# + name + ")" + boundary +
                #"(?:\s+on\s+"# + datePattern + #"|[.!]|$)"#, false, .conditional)
        ]
        let expressions = patterns.compactMap { pattern, nameFirst, role in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, nameFirst, role) }
        }
        let proposals = lines.indices.dropFirst().compactMap { index -> PersonPlanProposal? in
            let adjacent = Array(lines[index...].prefix(2))
            let joined = adjacent.map(\.value).joined(separator: " ")
            let fullRange = NSRange(joined.startIndex..., in: joined)
            for (expression, nameFirst, role) in expressions {
                guard let match = expression.firstMatch(in: joined, range: fullRange) else { continue }
                let nameSpan = match.range(at: nameFirst ? 1 : 2)
                let titleSpan = match.range(at: nameFirst ? 2 : 1)
                guard let personRange = Range(nameSpan, in: joined), let titleRange = Range(titleSpan, in: joined)
                else { continue }
                let title = String(joined[titleRange])
                guard (3...90).contains(title.count), title.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!")) == nil
                else { continue }
                let personAnchors = anchors(of: nameSpan, in: adjacent, source: source.reference)
                let titleAnchors = anchors(of: titleSpan, in: adjacent, source: source.reference)
                return PersonPlanProposal(person: PersonPlanText(String(joined[personRange]), evidence: personAnchors),
                    role: role, roleEvidence: personAnchors,
                    title: PersonPlanText(title, evidence: titleAnchors),
                    printedDate: printedDate(lines, source: source.reference), statusEvidence: [])
            }
            return nil
        }
        guard proposals.count == 1, let proposal = proposals.first else { return nil }
        return PersonPlanEvidence.admit(proposal, requestedPerson: person, on: source)
    }

    private static func printedDate(_ lines: [SourceObservation], source: SourceReference) -> PersonPlanText? {
        guard let regex = try? NSRegularExpression(pattern: datePattern, options: .caseInsensitive) else { return nil }
        let candidates = lines.flatMap { line in
            regex.matches(in: line.value, range: NSRange(line.value.startIndex..., in: line.value)).compactMap { match -> PersonPlanText? in
                guard let range = Range(match.range, in: line.value) else { return nil }
                return PersonPlanText(String(line.value[range]),
                    evidence: [EvidenceAnchor(source: source, observationID: line.id, quote: line.value)])
            }
        }
        guard Set(candidates.map { $0.value.lowercased() }).count == 1 else { return nil }
        return candidates.first
    }

    private static func anchors(of span: NSRange, in lines: [SourceObservation], source: SourceReference) -> [EvidenceAnchor] {
        var offset = 0
        return lines.compactMap { line in
            let lineRange = NSRange(location: offset, length: line.value.utf16.count)
            offset += lineRange.length + 1
            guard NSIntersectionRange(span, lineRange).length > 0 else { return nil }
            return EvidenceAnchor(source: source, observationID: line.id, quote: line.value)
        }
    }
}
