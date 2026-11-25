import Foundation
import IBrain
import IBrainRetrieval
import PinCore

/// Recall of explicit plan evidence and current owner corrections on permitted photos.
public enum PinPersonPlans {
    public enum Request: Equatable, Sendable {
        case person(String)
        case confirmedSubset

        public init?(question: String) {
            let words = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let text = words.trimmingCharacters(in: CharacterSet(charactersIn: "?!"))
            if text.caseInsensitiveCompare("Which of those are confirmed") == .orderedSame {
                self = .confirmedSubset
                return
            }
            let prefix = "What plans did I save with "
            guard text.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else { return nil }
            let name = String(text.dropFirst(prefix.count))
            guard PinPersonPlans.isPersonName(name) else { return nil }
            self = .person(name)
        }
    }

    public struct Detail: Equatable, Sendable {
        public let value: String
        public let evidence: EvidenceAnchor
        public let supportingEvidence: [EvidenceAnchor]

        init(value: String, evidence: EvidenceAnchor, supportingEvidence: [EvidenceAnchor] = []) {
            self.value = value
            self.evidence = evidence
            self.supportingEvidence = supportingEvidence
        }
    }

    public struct Card: Identifiable, Equatable, Sendable {
        public typealias Status = SavedPlanDetailCorrection.Status

        public var id: SourceReference { source }
        public let source: SourceReference
        public let person: Detail
        public let title: Detail
        public let date: Detail?
        public let time: Detail?
        public let location: Detail?
        public fileprivate(set) var status: Status
        public let statusEvidence: Detail?
        public fileprivate(set) var ownerCorrections: [SavedPlanDetailCorrection.Field: String] = [:]

        public var correctionSources: Set<EvidenceSource> {
            Set(originalSources.filter { $0 != source }.map {
                EvidenceSource(id: $0.id, fingerprint: $0.fingerprint, revision: $0.revision)
            })
        }

        /// The editable value is separate from the exact text cited by the original photo.
        public func value(for field: SavedPlanDetailCorrection.Field) -> String? {
            if let corrected = ownerCorrections[field] { return corrected }
            switch field {
            case .title: return title.value
            case .date: return date?.value
            case .time: return time?.value
            case .location: return location?.value
            case .status: return status.rawValue
            }
        }

        /// The original participation update comes first when it changes the answer.
        public var originalSources: [SourceReference] {
            var seen = Set<SourceReference>()
            return ((statusEvidence?.supportingEvidence.map(\.source) ?? []) + [source])
                .filter { seen.insert($0).inserted }
        }
    }

    public struct Answer: Sendable {
        public let person: String
        public let cards: [Card]
        public let onlyConfirmed: Bool
        fileprivate let scope: MemoryScope
        public let photoInventory: PinPhotoInventory
    }

    public static func search(person: String, in evidence: PinEvidenceSnapshot,
                              interpretations: [SavedPhotoInterpretation] = []) throws -> Answer {
        guard isPersonName(person) else { throw PinEvidenceError.invalidSupport }
        return Answer(person: person, cards: cards(for: person, in: evidence, interpretations: interpretations),
                      onlyConfirmed: false, scope: evidence.scope, photoInventory: evidence.photoInventory)
    }

    public static func confirmedSubset(of prior: Answer, in evidence: PinEvidenceSnapshot,
                                       interpretations: [SavedPhotoInterpretation] = []) throws -> Answer {
        guard prior.scope == evidence.scope else { throw PinEvidenceError.staleRecord }
        let current = Dictionary(uniqueKeysWithValues: cards(for: prior.person, in: evidence,
                                                              interpretations: interpretations).map { ($0.source, $0) })
        // A live update can remove a confirmed plan, but this subset cannot add a new plan or revision.
        let cards = prior.cards.compactMap { previous -> Card? in
            guard previous.status == .confirmed, let refreshed = current[previous.source],
                  refreshed.status == .confirmed, refreshed == previous else { return nil }
            return refreshed
        }
        return Answer(person: prior.person, cards: cards, onlyConfirmed: true, scope: prior.scope, photoInventory: evidence.photoInventory)
    }

    /// Keep the visible membership and order when an explicit edit updates the answer.
    public static func refresh(_ prior: Answer, in evidence: PinEvidenceSnapshot,
                               interpretations: [SavedPhotoInterpretation]) throws -> Answer {
        guard prior.scope == evidence.scope else { throw PinEvidenceError.staleRecord }
        let current = Dictionary(uniqueKeysWithValues: cards(for: prior.person, in: evidence,
                                                              interpretations: interpretations).map { ($0.source, $0) })
        let cards = prior.cards.compactMap { current[$0.source] }
            .filter { !prior.onlyConfirmed || $0.status == .confirmed }
        return Answer(person: prior.person, cards: cards, onlyConfirmed: prior.onlyConfirmed, scope: prior.scope, photoInventory: evidence.photoInventory)
    }

    private static func cards(for person: String, in evidence: PinEvidenceSnapshot,
                              interpretations: [SavedPhotoInterpretation]) -> [Card] {
        let sources = evidence.authority.sources
        let messages = sources.compactMap { datedMessage(person: person, from: $0) }
        let messageSources = Set(messages.map(\.source))
        let resolved = PersonPlanMessageResolution.resolve(messages, scope: evidence.scope,
            currentSources: Set(sources.map(\.reference)))
        let datedCards = Dictionary(uniqueKeysWithValues: resolved.compactMap { value in
            datedCard(value).map { ($0.source, $0) }
        })
        let interpretationBySource = Dictionary(grouping: interpretations, by: \.source)
        let personKey = SavedPlanDetailCorrection.personKey(person)
        return sources.compactMap { source in
            guard var row = messageSources.contains(source.reference) ? datedCards[source.reference] : card(for: person, from: source)
            else { return nil }
            let key = EvidenceSource(id: row.source.id, fingerprint: row.source.fingerprint, revision: row.source.revision)
            guard let matches = interpretationBySource[key], matches.count == 1 else { return row }
            let dependencies = row.correctionSources
            for edit in matches[0].planCorrections ?? []
                where edit.person == personKey && edit.additionalSources == dependencies {
                row.ownerCorrections[edit.field] = edit.value
                if edit.field == .status, let status = Card.Status(rawValue: edit.value) { row.status = status }
            }
            return row
        }
    }

    /// Start only with a heading whose complete text recurs in the body.
    /// The iBrain contract still has to read and prove the person, occurrence and status.
    private static func datedMessage(person: String, from source: SourceSnapshot) -> PersonPlanMessage? {
        let lines = source.observations.filter { $0.kind == .text }.map(\.value)
        guard (3...40).contains(lines.count) else { return nil }
        var proposals: [PersonPlanMessage] = []
        for index in lines.indices where (4...90).contains(lines[index].count) {
            let heading = normalized(lines[index])
            let phrase = PersonPlanMessage.occurrenceTitle(inAdministrativeHeading: heading) ?? heading
            guard phrase.count >= 4 else { continue }
            guard lines[index].rangeOfCharacter(from: CharacterSet(charactersIn: ":.!?")) == nil,
                  lines.indices.contains(where: { bodyIndex in
                      guard bodyIndex != index else { return false }
                      let adjacent = lines[bodyIndex...].prefix(3).enumerated().prefix { bodyIndex + $0.offset != index }
                      return normalized(adjacent.map(\.element).joined(separator: " ")).contains(phrase)
                  }),
                  let message = PersonPlanMessage.read(proposedTitle: lines[index], person: person, from: source)
            else { continue }
            proposals.append(message)
            if proposals.count > 1 { return nil }
        }
        return proposals.first
    }

    private static func datedCard(_ current: CurrentPersonPlan) -> Card? {
        let initial = current.initial
        guard let role = initial.participationEvidence.first, let title = detail(initial.title) else { return nil }
        let support = current.currentEvidence
        return Card(source: initial.source, person: Detail(value: initial.person, evidence: role),
                    title: title, date: detail(initial.eventDate), time: initial.eventTime.flatMap(detail),
                    location: nil, status: Card.Status(rawValue: current.participation.rawValue) ?? .unclear,
                    statusEvidence: support.first.map {
                        Detail(value: $0.quote, evidence: $0, supportingEvidence: support)
                    })
    }

    private static func detail(_ field: PersonPlanText) -> Detail? {
        field.evidence.first.map {
            Detail(value: field.value, evidence: $0, supportingEvidence: field.evidence)
        }
    }

    private static func card(for person: String, from source: SourceSnapshot) -> Card? {
        var fields: [String: [Detail]] = [:]
        let observations = source.observations.filter { $0.kind == .text }
        let ownNote = observations.first.map { ["my plans", "my notes", "my planning notes"].contains(normalized($0.value)) } ?? false
        for observation in observations {
            let proof = EvidenceAnchor(source: source.reference, observationID: observation.id, quote: observation.value)
            for (field, value) in planSentence(observation.value, ownNote: ownNote) {
                fields[field, default: []].append(Detail(value: value, evidence: proof))
            }
            let parts = observation.value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = normalized(String(parts[0]))
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            fields[key, default: []].append(Detail(value: value, evidence: proof))
        }
        // A photo with more than one titled plan cannot establish which plan a participant belongs to.
        guard let title = unique(fields["plan"]),
              let participant = ((fields["participant"] ?? []) + (fields["attendee"] ?? [])).first(where: {
                  normalized($0.value) == normalized(person)
              }) else {
            guard fields["plan"] == nil, let journal = PinPersonJournalReader.read(person: person, from: source),
                  let participant = journal.proposal.person.evidence.first,
                  let title = journal.title.evidence.first else { return nil }
            let status = Card.Status(rawValue: journal.status.rawValue) ?? .unclear
            let statusSupport = journal.admittedStatusEvidence.first(where: { $0.status == journal.status })?.support
            return Card(source: source.reference,
                person: Detail(value: journal.proposal.person.value, evidence: participant),
                title: Detail(value: journal.title.value, evidence: title, supportingEvidence: journal.title.evidence),
                date: journal.printedDate.flatMap { field in
                    field.evidence.first.map { Detail(value: field.value, evidence: $0) }
                }, time: nil, location: nil, status: status,
                statusEvidence: statusSupport.flatMap { field in
                    field.evidence.first.map { Detail(value: field.value, evidence: $0) }
                })
        }
        let statusEvidence = unique(fields["status"])
        let status = statusEvidence.flatMap { Card.Status(rawValue: normalized($0.value)) } ?? .unclear
        return Card(source: source.reference, person: participant, title: title, date: unique(fields["date"]),
                    time: unique(fields["time"]), location: unique(fields["location"]),
                    status: status, statusEvidence: statusEvidence)
    }

    private static func planSentence(_ text: String, ownNote: Bool) -> [(String, String)] {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributed = line.lowercased().hasPrefix("me:")
        guard attributed || ownNote else { return [] }
        let body = attributed ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : line
        let patterns: [(String, Bool, Card.Status?)] = [
            (#"^I(?:'m|’m| am) meeting (.+?) for (.+?)[.!]$"#, true, nil),
            (#"^I might meet (.+?) for (.+?)[.!]$"#, true, .tentative),
            (#"^I confirmed (.+?) with (.+?)[.!]$"#, false, .confirmed),
            (#"^I cancel(?:l)?ed (.+?) with (.+?)[.!]$"#, false, .cancelled),
            (#"^I(?:'m|’m| am) planning (.+?) with (.+?)[.!]$"#, false, .tentative)
        ]
        for (pattern, personFirst, status) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let first = Range(match.range(at: 1), in: body), let second = Range(match.range(at: 2), in: body)
            else { continue }
            let name = String(body[personFirst ? first : second])
            let title = String(body[personFirst ? second : first])
            guard isPersonName(name), (3...90).contains(title.count),
                  title.range(of: #"\b(?:and then|or|except|instead|unless|never|not)\b"#,
                              options: [.regularExpression, .caseInsensitive]) == nil,
                  title.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!")) == nil else { return [] }
            var fields = [("participant", name), ("plan", title)]
            if let status { fields.append(("status", status.rawValue)) }
            return fields
        }
        return []
    }

    private static func unique(_ observations: [Detail]?) -> Detail? {
        guard let observations, Set(observations.map { normalized($0.value) }).count == 1 else { return nil }
        return observations.first
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isPersonName(_ name: String) -> Bool {
        let parts = normalized(name).split(separator: " ")
        let nonNames = Set(["and", "or", "with", "this", "next", "on", "in"])
        return name.count <= 80 && (1...5).contains(parts.count) &&
            parts.allSatisfy { !nonNames.contains(String($0)) &&
                $0.range(of: #"^[\p{L}\p{M}][\p{L}\p{M}.'’\-]*$"#, options: .regularExpression) != nil }
    }
}
