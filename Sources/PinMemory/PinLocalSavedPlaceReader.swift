import Foundation
import IBrain
import IBrainRetrieval
import PinCore
#if canImport(FoundationModels)
import FoundationModels

public actor PinLocalSavedPlaceReader {
    public enum ReaderError: Error {
        case modelUnavailable
        case noReadableSources
    }

    private struct Cached {
        let source: SourceSnapshot
        let reading: LocalPlaceReading
    }

    private var readings: [SourceReference: Cached] = [:]

    public init() {}

    @available(iOS 26.0, macOS 26.0, *)
    public func catalog(memories: [PhotoMemory], interpretations: [SavedPhotoInterpretation]) async throws -> SavedPlaceCatalog {
        let model = SystemLanguageModel.default
        let scope = MemoryScope(ownerID: "local-photo-owner", namespace: "saved-places")
        let authority = try PinEvidenceSnapshot(memories: memories, records: [], scope: scope).authority
        let references = Set(authority.sources.map(\.reference))
        readings = readings.filter { references.contains($0.key) }
        var mentions = [SavedPlaceMention]()
        var unresolved = 0
        var failures = 0
        for source in authority.sources {
            try Task.checkCancellation()
            let cached = readings[source.reference]
            do {
                let reading: LocalPlaceReading
                if let cached, cached.source == source {
                    reading = cached.reading
                } else if let structured = PinStructuredPlaceReading.read(source) {
                    reading = LocalPlaceReading(mentions: structured.mentions, unresolved: structured.unresolved)
                    readings[source.reference] = Cached(source: source, reading: reading)
                } else {
                    guard model.isAvailable else { throw ReaderError.modelUnavailable }
                    reading = try await LocalSavedPlaceReader.read(source, model: model)
                    try Task.checkCancellation()
                    // Retry transient partial reads on a subsequent request.
                    if reading.reusable { readings[source.reference] = Cached(source: source, reading: reading) }
                }
                mentions.append(contentsOf: reading.mentions)
                if reading.unresolved { unresolved += 1 }
            } catch {
                try Task.checkCancellation()
                failures += 1
                unresolved += 1
            }
        }
        guard failures == 0 || failures < authority.sources.count else { throw ReaderError.noReadableSources }
        let records = mentions.map { mention in
            let source = mention.source
            return PinRecordPin(id: mention.recordID, revision: mention.recordRevision,
                sources: [EvidenceSource(id: source.id, fingerprint: source.fingerprint, revision: source.revision)])
        }
        return try PinSavedPlaceSourceBinding.catalog(scope: scope, memories: memories, records: records,
            mentions: mentions, interpretations: interpretations,
            coverage: SavedPlaceCoverage(pendingSourceCount: 0, unresolvedSourceCount: unresolved))
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct PlaceSpanChoices {
    @Guide(description: "ID of the establishment name; 0 if missing")
    let name: Int
    @Guide(description: "ID of the explicitly named branch; 0 if missing")
    let branch: Int
    @Guide(description: "ID of the complete street address; 0 if missing")
    let address: Int
    @Guide(description: "ID of the useful saved recommendation detail; 0 if missing")
    let reason: Int
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct PlaceLocationChoices {
    @Guide(description: "The list number of the city named in the text, or zero when absent")
    let city: Int
    @Guide(description: "The list number of a neighborhood within that city named in the text, or zero when absent")
    let neighborhood: Int
}

private struct LocalPlaceReading {
    let mentions: [SavedPlaceMention]
    let unresolved: Bool
    let reusable: Bool

    init(mentions: [SavedPlaceMention], unresolved: Bool, reusable: Bool = true) {
        self.mentions = mentions
        self.unresolved = unresolved
        self.reusable = reusable
    }

    init(mention: SavedPlaceMention?, unresolved: Bool, reusable: Bool = true) {
        self.init(mentions: mention.map { [$0] } ?? [], unresolved: unresolved, reusable: reusable)
    }
}

@available(iOS 26.0, macOS 26.0, *)
private enum LocalSavedPlaceReader {
    private struct Span {
        let value: String
        let line: SourceObservation
        let fields: Set<SavedPlaceField>
        let direct: Bool
        var continuation: [SourceObservation] = []
    }

    static func read(_ source: SourceSnapshot, model: SystemLanguageModel) async throws -> LocalPlaceReading {
        let observations = source.observations.filter { $0.kind == .text }
        guard observations.count <= 35 else { return .init(mention: nil, unresolved: true) }
        if observations.contains(where: {
            contains(#"\b(?:transit map|transit directions|nearby(?:\s+\p{L}+)? map labels?)\b"#, in: lower($0)) ||
            exclusionClause(lower($0))
        }) {
            return .init(mention: nil, unresolved: true)
        }
        // This fallback proposes one venue. Several named save clauses or a conflict with a
        // printed venue label must not turn one place's recommendation into another's.
        let namedRecommendations = Set(observations.compactMap { recommendationSubject($0.value)?.lowercased() })
        let venueLabels = Set(observations.compactMap {
            capture(#"^(?:name|place):\s*(.+)$"#, in: $0.value)?.lowercased()
        })
        guard namedRecommendations.count <= 1,
              namedRecommendations.isEmpty || venueLabels.isEmpty || namedRecommendations == venueLabels,
              let role = roleEvidence(observations) else { return .init(mention: nil, unresolved: true) }
        var choices = observations.flatMap { spans($0, role: role.0) }
        if let compactName = compactDocumentName(observations, role: role.0) {
            choices.append(compactName)
        }
        if role.0 == .listing, let title = structuredListingTitle(observations) {
            choices.append(.init(value: title.value, line: title, fields: [.name], direct: true))
        }
        guard !choices.isEmpty else { return .init(mention: nil, unresolved: true) }
        let fields: [SavedPlaceField] = [.name, .branch, .address, .reason]
        var values: [SavedPlaceField: Span] = [:]
        for field in fields {
            let direct = choices.filter { $0.direct && $0.fields.contains(field) }
            if Set(direct.map(\.value)).count == 1 { values[field] = direct.first }
        }
        var unresolved = false
        var reusable = true
        if fields.contains(where: { field in values[field] == nil && choices.contains { $0.fields.contains(field) } }) {
            do {
                let proposal = try await chooseFields(choices, model: model)
                let requested: [(SavedPlaceField, Int)] = [
                    (.name, proposal.name), (.branch, proposal.branch), (.address, proposal.address), (.reason, proposal.reason)
                ]
                for (field, selected) in requested where values[field] == nil && selected != 0 {
                    if selected > 0, choices.indices.contains(selected - 1), choices[selected - 1].fields.contains(field) {
                        values[field] = choices[selected - 1]
                    } else {
                        unresolved = true
                    }
                }
            } catch {
                try Task.checkCancellation()
                unresolved = true
                reusable = false
            }
        }
        if role.0 == .recommendation {
            if values[.reason] == nil { values[.reason] = recommendationDetail(observations) }
        } else {
            values.removeValue(forKey: .reason)
        }
        guard let name = values[.name] else { return .init(mention: nil, unresolved: true, reusable: reusable) }
        do {
            let geography = try await locations(choices, observations: observations,
                                                 for: name, detail: values[.reason], model: model)
            values.merge(geography) { original, _ in original }
        } catch {
            // A provider refusal leaves the supported non-location facts intact.
            try Task.checkCancellation()
            unresolved = true
            reusable = false
        }
        if let city = values[.city], let neighborhood = values[.neighborhood],
           city.value.caseInsensitiveCompare(neighborhood.value) == .orderedSame {
            values.removeValue(forKey: .neighborhood)
            unresolved = true
        }
        if role.0 == .listing, let address = values[.address], let city = values[.city],
           let neighborhood = values[.neighborhood],
           let index = observations.firstIndex(where: { $0.id == address.line.id }) {
            let next = observations.dropFirst(index + 1).prefix(2)
            let printed = next.map(\.value).joined(separator: " ")
            if !address.value.contains(city.value),
               printed.contains(neighborhood.value), printed.contains(city.value),
               next.allSatisfy({ line in line.value.split(separator: ",").allSatisfy {
                   isLocationPhrase($0.trimmingCharacters(in: .whitespaces))
               } }) {
                values[.address] = Span(value: address.value + " " + printed, line: address.line,
                    fields: [.address], direct: true, continuation: Array(next))
            }
        }
        if role.0 == .visit { values[.visitDate] = visitDate(observations) }
        var facts = SavedPlaceField.allCases.compactMap { field in
            values[field].map { fact(field, $0.value, [$0.line] + $0.continuation, source) }
        }
        facts.append(fact(.subjectRole, role.0.rawValue, role.1, source))
        let categories = observations.compactMap { line -> (String, SourceObservation)? in
            if contains(#"\b(?:café|cafe|coffee shop)s?\b"#, in: lower(line)) { return ("cafe", line) }
            if contains(#"\b(?:restaurant|restaurants|dining room)\b"#, in: lower(line)) { return ("restaurant", line) }
            return nil
        }
        if Set(categories.map(\.0)).count == 1, let category = categories.first {
            facts.append(fact(.category, category.0, [category.1], source))
        }
        return .init(mention: SavedPlaceMention(recordID: "pin.saved-place|" + source.reference.id,
            recordRevision: source.reference.revision, source: source.reference, facts: facts), unresolved: unresolved,
            reusable: reusable)
    }

    private static func chooseFields(_ choices: [Span], model: SystemLanguageModel) async throws -> PlaceSpanChoices {
        let options = choices.enumerated().map { index, span in
            "\(index + 1): \(span.value) [\(span.fields.map(\.rawValue).sorted().joined(separator: "/"))]"
        }
        let input = (["Use the numbers from the evidence list. Assign 0 to unsupported fields.",
                      "Context below each field is in original reading order.", "Evidence:"] + options).joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: """
            Resolve a single named place in a saved document. Return evidence IDs only.
            Each ID has an allowed field list. Follow those lists exactly. Do not reuse the same name for a city or neighborhood.
            Geographic labels printed in a branch heading alone do not establish a neighborhood.
            A recommendation reason is a preference or useful factual detail about why to save this place.
            """)
        return try await session.respond(to: input, generating: PlaceSpanChoices.self,
                                         options: .init(sampling: .greedy)).content
    }

    private static func compactDocumentName(_ observations: [SourceObservation], role: SavedPlaceRole) -> Span? {
        let headings = observations.indices.filter {
            contains(#"^(?:try this (?:restaurant|caf[eé])|(?:restaurants|caf[eé]s) to try|(?:restaurant|caf[eé]) listing)$"#,
                     in: observations[$0].value)
        }
        guard headings.count == 1, let heading = headings.first, observations.indices.contains(heading + 2) else { return nil }
        let name = observations[heading + 1]
        let tails = observations[(heading + 2)...].map { spans($0, role: role) }
        guard isLocationPhrase(name.value),
              !tails.contains(where: \.isEmpty),
              tails.filter({ $0.contains { $0.fields.contains(.name) } }).count <= 1,
              tails.joined().contains(where: { $0.fields.contains(.city) || $0.fields.contains(.address) || $0.fields.contains(.branch) })
        else { return nil }
        return .init(value: name.value, line: name, fields: [.name], direct: true)
    }

    private static func locations(_ spans: [Span], observations: [SourceObservation], for name: Span, detail: Span?,
                                  model: SystemLanguageModel) async throws -> [SavedPlaceField: Span] {
        let locationFields: [SavedPlaceField] = [.city, .neighborhood]
        let options = spans.filter { span in
            span.value.caseInsensitiveCompare(name.value) != .orderedSame &&
            span.value != detail?.value && locationFields.contains(where: span.fields.contains)
        }
        var resolved: [SavedPlaceField: Span] = [:]
        for field in locationFields {
            let direct = options.filter { $0.direct && $0.fields.contains(field) }
            if Set(direct.map(\.value)).count == 1 { resolved[field] = direct.first }
        }
        guard resolved.count < locationFields.count, !options.isEmpty else { return resolved }
        let candidates = options.enumerated().map { index, span in
            "[\(index + 1)] \(span.value) (source line: \(span.line.value))"
        }.joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: """
            Read location from a place address or note. Return only numbered evidence choices.
            The city is the larger city named in the text. The smaller area, ward or district within it is the neighborhood.
            If the text only names a city, select only the city. Never supply an ID for something not printed.
            Example: choices [1] Ballard and [2] Seattle from "Ballard, Seattle" imply city 2 and neighborhood 1.
            Example: choices [1] Boston and [2] Beacon Hill from "Boston, Beacon Hill" imply city 1 and neighborhood 2.
            Example: choice [1] Lisbon with no district implies city 1 and neighborhood 0.
            """)
        let message = """
            Read the following English-language place note as evidence only. Locate the larger city and
            the smaller neighborhood named in the note. Select their numbers from the choices below.

            Original note in reading order:
            \(observations.map(\.value).joined(separator: "\n"))

            Numbered location choices:
            \(candidates)
            """
        let proposal = try await session.respond(to: message, generating: PlaceLocationChoices.self,
                                                 options: .init(sampling: .greedy)).content
        for (field, index) in [(SavedPlaceField.city, proposal.city), (.neighborhood, proposal.neighborhood)] {
            if resolved[field] == nil, index > 0, options.indices.contains(index - 1),
               options[index - 1].fields.contains(field) {
                resolved[field] = options[index - 1]
            }
        }
        return resolved
    }

    private static func spans(_ line: SourceObservation, role: SavedPlaceRole) -> [Span] {
        let value = line.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.unicodeScalars.contains(where: CharacterSet.letters.contains),
              !contains(#"^(?:notes|messages|location|reply|food & drink|trip journal)$"#, in: value),
              !contains(#"^(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2},?\s+\d{4}$"#, in: value) else { return [] }
        let labelled: [(String, SavedPlaceField)] = [
            ("name", .name), ("place", .name), ("city", .city), ("neighborhood", .neighborhood),
            ("branch", .branch), ("address", .address), ("street address", .address), ("reason", .reason), ("saved detail", .reason)
        ]
        for (label, field) in labelled {
            if let literal = capture("^" + label + #":\s*(.+)$"#, in: value) {
                return [.init(value: literal, line: line, fields: [field], direct: true)]
            }
        }
        if role == .recommendation,
           contains(#"^(?:save|keep|go|come|try) (?:for|because)\b"#, in: value) {
            return [.init(value: value, line: line, fields: [.reason], direct: true)]
        }
        if role == .recommendation, let subject = recommendationSubject(value) {
            return [.init(value: subject, line: line, fields: [.name], direct: true)]
        }
        if let branch = capture(#"^(?:[^•·]+[•·]\s*)?([\p{L}\p{M}][\p{L}\p{M} '’\-]+)\s+branch,\s*(.+)$"#, in: value),
           let tail = capture(#"\bbranch,\s*(.+)$"#, in: value) {
            let places = tail.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var result = [Span(value: branch, line: line, fields: [.branch], direct: true)]
            if places.count == 2, places.allSatisfy(isLocationPhrase),
               places[0].caseInsensitiveCompare(branch) == .orderedSame {
                result.append(.init(value: places[0], line: line, fields: [.neighborhood], direct: true))
                result.append(.init(value: places[1], line: line, fields: [.city], direct: true))
            } else {
                result += places.filter(isLocationPhrase).map {
                    .init(value: $0, line: line, fields: [.city, .neighborhood], direct: false)
                }
            }
            return result
        }
        if let inLocation = capture(#"^(?:dinner|lunch|brunch|a meal)\s+when\s+(?:we(?:'re| are)|i(?:'m| am))\s+in\s+([^.!?,]+)[.!?]?$"#, in: value),
           isLocationPhrase(inLocation) {
            return [.init(value: inLocation, line: line, fields: [.city, .neighborhood], direct: false)]
        }
        if let branch = capture(#"^(.+?)\s+branch[.]?$"#, in: value) {
            return [.init(value: branch, line: line, fields: [.branch], direct: true)]
        }
        if let name = capture(#"^(?:try|save|add|(?:i|we) (?:ate at|dined at|went to|visited))\s+(.+?)(?:\s+(?:in|for|to (?:my|our|the))\s+|\s+[—–(]|[,.]|$)"#, in: value),
           !contains(#"^(?:this|the|a|an)\s+"#, in: name) {
            var parts = [Span(value: name, line: line, fields: [.name], direct: true)]
            if let place = capture(#"\s+in\s+(.+?)(?:\s+for(?:\s+|$)|[,.]|$)"#, in: value),
               isLocationPhrase(place) {
                parts.append(.init(value: place, line: line, fields: [.city, .neighborhood], direct: false))
            }
            if let branch = capture(#"(?:[—–(]\s*)(.+?)\s+branch\b"#, in: value) {
                parts.append(.init(value: branch, line: line, fields: [.branch], direct: true))
            }
            return parts
        }
        if role == .listing,
           let title = capture(#"^([^/]+?)\s*/\s*[^/]+$"#, in: value),
           let qualifier = capture(#"^[^/]+/\s*(.+)$"#, in: value) {
            return [.init(value: title, line: line, fields: [.name], direct: true),
                    .init(value: qualifier, line: line, fields: [.branch, .neighborhood], direct: false)]
        }
        if contains(#"^(?:good for|excellent|known for|try the|reason to save)\b"#, in: value) {
            return [.init(value: value, line: line, fields: [.reason], direct: true)]
        }
        if let place = capture(#"^([\p{L}][\p{L}\p{M} '’\-]+)\)"#, in: value),
           isLocationPhrase(place) {
            return [.init(value: place, line: line, fields: [.city, .neighborhood], direct: false)]
        }
        let street = contains(#"^[\p{Nd}]+(?:-[\p{Nd}]+)?\s+.+\b(?:street|road|avenue|lane|way|dori|boulevard|plaza|walk)\b"#, in: value)
        if street || value.contains(",") {
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let geography = (street ? parts.dropFirst() : ArraySlice(parts)).filter { isLocationPhrase($0) }
                .map { Span(value: $0, line: line, fields: [.city, .neighborhood], direct: false) }
            return (street ? [Span(value: value, line: line, fields: [.address], direct: true)] : []) + geography
        }
        if roleEvidence([line]) != nil || contains(#"\b(?:printed|fictional|draft|weekend notes)\b"#, in: value) {
            return []
        }
        if let first = capture(#"^([\p{L}][\p{L}\p{M} '’\-]+)\.\s+\p{Lu}"#, in: value),
           isLocationPhrase(first) {
            return [.init(value: first, line: line, fields: [.city, .neighborhood], direct: false)]
        }
        guard isLocationPhrase(value) else { return [] }
        return [.init(value: value, line: line, fields: [.name, .city, .neighborhood], direct: false)]
    }

    private static func roleEvidence(_ lines: [SourceObservation]) -> (SavedPlaceRole, [SourceObservation])? {
        let matches: [(SavedPlaceRole, String)] = [
            (.visit, #"^(?:i|we) (?:ate at|dined at|went to|visited)\s"#),
            (.recommendation, #"\b(?:saved recommendation|shortlist|places to try|restaurants to try|cafés to try|cafes to try)\b|^(?:try|save)\s"#),
            (.listing, #"\b(?:restaurant listing|café listing|cafe listing|listing page|branch listing|food guide)\b"#)
        ]
        var hits = matches.compactMap { role, regex in
            lines.first(where: { contains(regex, in: lower($0)) }).map { (role, [$0]) }
        }
        if !hits.contains(where: { $0.0 == .listing }), let title = structuredListingTitle(lines) {
            hits.append((.listing, [title]))
        }
        if !hits.contains(where: { $0.0 == .recommendation }),
           let note = lines.first(where: { recommendationSubject($0.value) != nil }) {
            hits.append((.recommendation, [note]))
        }
        if !hits.contains(where: { $0.0 == .recommendation }), let note = diningListNote(lines) {
            hits.append((.recommendation, [note]))
        }
        if !hits.contains(where: { $0.0 == .recommendation }),
           let index = lines.indices.dropLast().first(where: { index in
               contains(#"^add\s.+\bto (?:my|our) .+\blist\b"#, in: lower(lines[index]) + " " + lower(lines[index + 1]))
           }) {
            hits.append((.recommendation, [lines[index], lines[index + 1]]))
        }
        return hits.count == 1 ? hits.first : nil
    }

    private static func recommendationSubject(_ value: String) -> String? {
        let patterns = [
            #"^(?:add|keep|put|save|include)\s+(.+?)\s+(?:on|in|to)\s+(?:my|our|the)\s+(?:(?:breakfast|brunch|lunch|dinner|restaurant|dining)\s+list|shortlist)[.!]?$"#,
            #"^(?:(?:i|we)(?:'d|’d| would) try|suggest|recommend)\s+(.+?)(?:\s+(?:next time|for|when|in)(?:\s|[.!?]|$)|[.!?]?$)"#
        ]
        guard !exclusionClause(value) else { return nil }
        return patterns.compactMap { capture($0, in: value) }.first(where: isLocationPhrase)
    }

    private static func exclusionClause(_ value: String) -> Bool {
        contains(#"^\s*(?:(?:please\s+)?(?:do not|don['’]t|never)\s+(?:add|save|include|keep|put|try)|(?:remove|exclude|skip)\s+)"#, in: value)
    }

    private static func structuredListingTitle(_ lines: [SourceObservation]) -> SourceObservation? {
        let categoryRows = lines.indices.filter {
            contains(#"^(?:restaurant|caf[eé]|coffee shop)$"#, in: lines[$0].value)
        }
        guard categoryRows.count == 1, let category = categoryRows.first, category > 0,
              lines[..<category].contains(where: { contains(#"\b(?:directory|listing|venue guide)\b"#, in: $0.value) }),
              lines[(category+1)...].contains(where: { contains(#"^\p{Nd}+(?:-\p{Nd}+)?\s+.+\b(?:street|road|avenue|lane|way|dori|boulevard|plaza|walk)\b"#, in: $0.value) })
        else { return nil }
        let title = lines[category - 1]
        return isLocationPhrase(title.value) ? title : nil
    }

    private static func diningListNote(_ lines: [SourceObservation]) -> SourceObservation? {
        let names = Set(lines.compactMap { line in
            capture(#"^(?:name|place):\s*(.+)$"#, in: line.value).map { $0.lowercased() }
        })
        guard names.count == 1, let name = names.first else { return nil }
        // The note must refer to the establishment described by the rest of the source.
        let pattern = #"^put\s+(.+?)\s+on\s+(?:the|my|our)\s+(?:breakfast|brunch|lunch|dinner|restaurant)\s+list[.!]?$"#
        let notes = lines.compactMap { line in capture(pattern, in: line.value).map { ($0.lowercased(), line) } }
        guard Set(notes.map(\.0)) == [name] else { return nil }
        return notes.first?.1
    }

    private static func recommendationDetail(_ lines: [SourceObservation]) -> Span? {
        for index in lines.indices {
            let line = lines[index]
            if contains(#"^(?:(?:ask for|order|try|look for) (?:the|a|an)\s+|(?:their|the)\s+.+\b(?:sounds?|looks?)\s+(?:good|great|excellent)\b)"#, in: line.value),
               contains(#"[.!?]$"#, in: line.value) {
                return .init(value: line.value, line: line, fields: [.reason], direct: true)
            }
            if let lead = capture(#"^for\s+(?:the\s+)?([^.!?]+)[.!?]"#, in: line.value),
               index > 0, contains(#"\b(?:save|try)\b"#, in: lines[index - 1].value) {
                return .init(value: lead, line: line, fields: [.reason], direct: true)
            }
            if let note = capture(#"(?:^|\.\s+)(ask for .+|(?:their|the)\s+[^.!?]+|i hear the(?:\s+.+)?)$"#, in: line.value),
               index + 1 < lines.count, !contains(#"[.!?]$"#, in: line.value) {
                let continuation = lines[index + 1]
                guard let end = capture(#"^([^.!?]+[.!?])"#, in: continuation.value) else { continue }
                return .init(value: note + " " + end, line: line, fields: [.reason],
                             direct: true, continuation: [continuation])
            }
        }
        return nil
    }

    private static func visitDate(_ lines: [SourceObservation]) -> Span? {
        let month = "(?:January|February|March|April|May|June|July|August|September|October|November|December)"
        guard let body = lines.first(where: { contains("\\bon " + month + #"\s+\d{1,2}\b"#, in: $0.value) }),
              let day = capture("\\bon (" + month + #"\s+\d{1,2})\b"#, in: body.value),
              let header = lines.first(where: { contains("^" + NSRegularExpression.escapedPattern(for: day) + #",?\s+\d{4}$"#, in: $0.value) })
        else { return nil }
        return .init(value: header.value, line: header, fields: [.visitDate], direct: true, continuation: [body])
    }

    private static func isLocationPhrase(_ value: String) -> Bool {
        value.split(whereSeparator: \.isWhitespace).count <= 5 &&
        contains(#"^[\p{L}\p{M}][\p{L}\p{M} '’\-]*$"#, in: value) &&
        !contains(#"\b(?:at|in|for|try|guide|list|weekend|branch|dinner|dining|saved|recommendation)\b"#, in: value)
    }

    private static func fact(_ field: SavedPlaceField, _ value: String, _ lines: [SourceObservation],
                             _ source: SourceSnapshot) -> SavedPlaceFact {
        .init(field, value: value,
              anchors: lines.map { .init(source: source.reference, observationID: $0.id, quote: $0.value) },
              extractorVersion: "ibrain-isolated-place-speech-act-v1")
    }

    private static func lower(_ line: SourceObservation) -> String { line.value.lowercased() }
    private static func contains(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range]).trimmingCharacters(in: .whitespaces)
    }
}
#endif
