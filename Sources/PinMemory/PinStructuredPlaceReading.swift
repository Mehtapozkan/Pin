import Foundation
import IBrain
import IBrainRetrieval

/// Reads explicit source-local layouts. Each list entry owns its own title
/// and details. Only an unambiguous shortlist heading supplies shared facts.
struct PinStructuredPlaceReading {
    let mentions: [SavedPlaceMention]
    let unresolved: Bool
    private static let version = "pin-structured-place-reading-v6"

    static func read(_ source: SourceSnapshot) -> Self? {
        let lines = source.observations.filter { $0.kind == .text }
        if let list = shortlist(lines, source: source) { return list }
        if let list = proseShortlist(lines, source: source) { return list }
        if let note = labelledSavedVenue(lines, source: source) { return note }
        if let listing = directory(lines, source: source) { return listing }
        if let note = scopedRecommendation(lines, source: source) { return note }
        if let note = headedSingleSave(lines, source: source) { return note }
        if let note = branchSave(lines, source: source) { return note }
        if let note = namedSaveWithLocation(lines, source: source) { return note }
        return nil
    }

    private static let itemPattern = #"^(?:[0-9]{1,3}[.)]|[•·])\s+(.+)$"#
    private static let headlinePattern =
        #"^([^.!?,:]+?)\s+(caf[eé]s?|restaurants?|coffee shops?)\s+(?:shortlist|to try|to save)[:.]?$"#

    private static func labelledSavedVenue(_ lines: [SourceObservation], source: SourceSnapshot) -> Self? {
        let headingPattern = #"^saved (caf[eé]|coffee shop|restaurant)$"#
        let headings = lines.indices.filter { capture(headingPattern, lines[$0].value) != nil }
        let frame: (heading: Int, title: Int, category: String, city: String?)
        if !headings.isEmpty {
            guard headings.count == 1, let index = headings.first, index + 1 < lines.count,
                  let type = capture(headingPattern, lines[index].value)?.first.flatMap(category) else { return nil }
            frame = (index, index + 1, type, nil)
        } else {
            let compact = #"^(caf[eé]|coffee shop|restaurant) to (?:try|save) in ([^.!?,:]+)[.!:]?$"#
            let roles = lines.indices.dropFirst().prefix(4).compactMap { index -> (Int, String, String)? in
                guard let parts = capture(compact, lines[index].value), let type = category(parts[0]),
                      label(parts[1]) else { return nil }
                return (index, type, parts[1])
            }
            guard roles.count == 1, let (index, type, city) = roles.first else { return nil }
            frame = (index, index - 1, type, city)
        }
        let title = lines[frame.title]
        let heading = lines[frame.heading]
        guard label(title.value),
              capture(#"^(?:notes?|messages|photos?|photographed note|saved recommendation|saved places)$"#, title.value) == nil,
              !hasNegativeSave(lines.map(\.value).joined(separator: " ")),
              !lines.contains(where: {
                capture(#"^(?:I|we) (?:already )?(?:visited|went to|dined at|ate at)\b"#, $0.value) != nil
              }) else { return Self(mentions: [], unresolved: true) }
        let fields = Array(lines.dropFirst(max(frame.heading, frame.title) + 1))
        func labels(_ heading: String) -> [(String, SourceObservation)] {
            fields.compactMap { line in
                capture("^" + heading + #":\s*(.+)$"#, line.value)?.first.map { ($0, line) }
            }
        }
        func uniqueLabel(_ heading: String) -> (String, SourceObservation)? {
            let values = labels(heading)
            return values.count == 1 ? values.first : nil
        }
        let cityField = frame.city.map { ($0, heading) } ?? uniqueLabel("city")
        guard let (city, cityAnchor) = cityField, label(city),
              labels("city").allSatisfy({ $0.0.caseInsensitiveCompare(city) == .orderedSame }) else {
            return Self(mentions: [], unresolved: true)
        }
        let categories = labels("category")
        guard categories.allSatisfy({ category($0.0) == frame.category }),
              labels("(?:name|place)").allSatisfy({ $0.0.caseInsensitiveCompare(title.value) == .orderedSame })
        else { return Self(mentions: [], unresolved: true) }
        var facts = [
            fact(.name, title.value, [title], source), fact(.city, city, [cityAnchor], source),
            fact(.category, frame.category, [categories.first?.1 ?? heading], source),
            fact(.subjectRole, "recommendation", [heading, title], source)
        ]
        for (key, field) in [("branch", SavedPlaceField.branch), ("neighborhood", .neighborhood)] {
            if let (value, anchor) = uniqueLabel(key), label(value),
               capture(#"^(?:not listed|unknown|unspecified|not stated|none)$"#, value) == nil {
                facts.append(fact(field, value, [anchor], source))
            }
        }
        if let (address, anchor) = uniqueLabel("(?:street )?address"),
           address.count <= 180, capture(#"\p{L}"#, address) != nil,
           capture(#"^(?:not listed|unknown|unspecified|not stated|none)$"#, address) == nil {
            facts.append(fact(.address, address, [anchor], source))
        }
        if let detail = reason(in: fields, titleBody: fields.first?.value ?? "") {
            facts.append(fact(.reason, detail.value, detail.lines, source))
        }
        return Self(mentions: [single(facts, source: source)], unresolved: false)
    }

    private static func shortlist(_ lines: [SourceObservation], source: SourceSnapshot) -> Self? {
        let starts = lines.indices.filter { entryBody(lines[$0].value) != nil }
        guard let first = starts.first else { return nil }
        guard let frame = listFrame(Array(lines[..<first])) else { return nil }
        // Stop inheritance at a section boundary that is explicitly unrelated.
        // In an uncertain layout leave the affected entries unadmitted.
        let negativeHeading = #"\b(?:skip|remove[d]?|do not|don't|cross(?:ed)? off|avoid)\b"#
        guard !lines[..<first].contains(where: { capture(negativeHeading, $0.value) != nil })
        else { return Self(mentions: [], unresolved: true) }

        var mentions: [SavedPlaceMention] = []
        var unresolved = false
        for (ordinal, start) in starts.enumerated() {
            let end = ordinal + 1 < starts.count ? starts[ordinal + 1] : lines.endIndex
            let entry = Array(lines[start..<end])
            let line = lines[start]
            guard let entryStart = entryBody(line.value) else { continue }
            if !entryStart.keep { continue }
            let body = entryStart.text
            guard let identity = listIdentity(body), label(identity.name) else {
                unresolved = true
                continue
            }
            if entry.contains(where: { capture(negativeHeading, $0.value) != nil }) {
                unresolved = true
                continue
            }
            var facts = [
                fact(.name, identity.name, [line], source),
                fact(.city, frame.city, [frame.cityLine], source),
                fact(.category, frame.category, [frame.categoryLine], source),
                fact(.subjectRole, "recommendation", [frame.categoryLine, line], source)
            ]
            if let area = identity.area {
                facts.append(fact(.neighborhood, area, [line], source))
            } else if let area = frame.neighborhood, let areaLine = frame.neighborhoodLine,
                      !entry.contains(where: {
                         capture(#"\b(?:neighborhood|area)\s+(?:is\s+)?(?:unknown|not listed|unconfirmed)\b"#, $0.value) != nil
                      }) {
                facts.append(fact(.neighborhood, area, [areaLine], source))
            }
            if let reason = reason(in: entry, titleBody: body) {
                facts.append(fact(.reason, reason.value, reason.lines, source))
            }
            // The slot follows the entry's exact OCR anchor. Array order is
            // display order only and never identifies a correction target.
            let id = "pin.saved-place.entry|\(source.reference.id.utf8.count)|\(source.reference.id)|\(line.id)"
            mentions.append(SavedPlaceMention(recordID: id, recordRevision: source.reference.revision,
                                              source: source.reference, facts: facts))
        }
        return Self(mentions: mentions, unresolved: unresolved)
    }

    private struct ListFrame {
        let city: String
        let cityLine: SourceObservation
        let category: String
        let categoryLine: SourceObservation
        var neighborhood: String? = nil
        var neighborhoodLine: SourceObservation? = nil
    }

    private static func entryBody(_ line: String) -> (keep: Bool, text: String)? {
        if let flags = capture(#"^(KEEP|SKIP)\s+(.+)$"#, line),
           line.hasPrefix(flags[0].uppercased() + " ") {
            return (flags[0] == "KEEP", flags[1])
        }
        if let body = capture(itemPattern, line)?.first { return (true, body) }
        return nil
    }

    private static func listFrame(_ headers: [SourceObservation]) -> ListFrame? {
        if let frame = hierarchicalListFrame(headers) { return frame }
        if let frame = neighborhoodAboveCityFrame(headers) { return frame }
        if let frame = cityAboveNeighborhoodFrame(headers) { return frame }
        let oneLine = headers.compactMap { line -> ListFrame? in
            guard let parts = capture(headlinePattern, line.value), label(parts[0]), let type = category(parts[1])
            else { return nil }
            return ListFrame(city: parts[0], cityLine: line, category: type, categoryLine: line)
        }
        if let frame = oneLine.first, oneLine.count == 1 { return frame }
        let categoryRows = headers.compactMap { line in
            capture(#"^(coffee stops|coffee shops|caf[eé]s|restaurants) to (?:keep|save|try)$"#, line.value)
                .flatMap { category($0[0]) }.map { (line, $0) }
        }
        let cityRows = headers.compactMap { line in
            capture(#"^([^•·]+)\s+[•·]\s+(?:weekend|trip|travel|food) (?:email|notes?|list|planner)$"#, line.value)?
                .first.flatMap { label($0) ? (line, $0) : nil }
        }
        guard categoryRows.count == 1, cityRows.count == 1,
              let (categoryLine, category) = categoryRows.first, let (cityLine, city) = cityRows.first
        else { return nil }
        return ListFrame(city: city, cityLine: cityLine, category: category, categoryLine: categoryLine)
    }

    private static func hierarchicalListFrame(_ headers: [SourceObservation]) -> ListFrame? {
        guard (headers.count == 3 || headers.count == 4),
              headers.count == 3 || capture(#"^(?:notes|messages|email|food & drink)$"#, headers[0].value) != nil,
              let section = headers.last,
              let sectionFields = capture(headlinePattern, section.value), label(sectionFields[0]),
              let type = category(sectionFields[1]) else { return nil }
        let cityLine = headers[headers.count - 2]
        let city = capture(#"^City:\s*(.+)$"#, cityLine.value)?.first ?? cityLine.value
        let categoryLine = headers[headers.count - 3]
        guard label(city), city.caseInsensitiveCompare(sectionFields[0]) != .orderedSame,
              let listType = capture(#"^(caf[eé]s|restaurants|coffee shops) to (?:keep|save|try)[:.]?$"#,
                                     categoryLine.value)?.first.flatMap(category), listType == type
        else { return nil }
        return ListFrame(city: city, cityLine: cityLine, category: type, categoryLine: categoryLine,
                         neighborhood: sectionFields[0], neighborhoodLine: section)
    }

    private static func neighborhoodAboveCityFrame(_ headers: [SourceObservation]) -> ListFrame? {
        guard headers.count == 3,
              let section = capture(#"^(?:my |our )?saved (coffee|caf[eé]s?|coffee shops?|restaurants?) (?:shortlist|list|picks)[:.]?$"#,
                                    headers[0].value)?.first,
              let type = section.lowercased() == "coffee" ? "cafe" : category(section),
              let city = corroboratedListCity(headers[2].value, category: type),
              label(city) else { return nil }
        let areaLine = headers[1]
        let area = capture(#"^(?:Neighborhood|Area):\s*(.+)$"#, areaLine.value)?.first ?? areaLine.value
        guard label(area), area.caseInsensitiveCompare(city) != .orderedSame else { return nil }
        return ListFrame(city: city, cityLine: headers[2], category: type, categoryLine: headers[0],
                         neighborhood: area, neighborhoodLine: areaLine)
    }

    /// The separate saved-list heading already establishes the category.
    /// If the city heading repeats it with a small OCR error, keep the
    /// literal city and cite the two original headings with their own facts.
    private static func corroboratedListCity(_ line: String, category expected: String) -> String? {
        if let exact = capture(headlinePattern, line) {
            return category(exact[1]) == expected ? exact[0] : nil
        }
        guard let fields = capture(
            #"^([^.!?,:]+?)\s+([\p{L}\p{M}]+)\s+(?:shortlist|to try|to save)[:.]?$"#, line) else { return nil }
        let observed = Array(fields[1].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        let expectedWords = expected == "cafe" ? ["cafe", "cafes"] : ["restaurant", "restaurants"]
        guard expectedWords.contains(where: { word in
            let letters = Array(word)
            return observed.count == letters.count && zip(observed, letters).filter { $0.0 != $0.1 }.count == 1
        }) else { return nil }
        return fields[0]
    }

    private static func cityAboveNeighborhoodFrame(_ headers: [SourceObservation]) -> ListFrame? {
        let context = headers.count == 3 &&
            capture(#"^(?:notes|messages|email|food & drink)$"#, headers[0].value) != nil
        guard headers.count == 2 || context else { return nil }
        let cityLine = headers[headers.count - 2]
        let areaLine = headers[headers.count - 1]
        guard let city = capture(headlinePattern, cityLine.value), label(city[0]), let type = category(city[1]) else {
            return nil
        }
        let explicitArea = capture(#"^(?:Neighborhood|Area|District):\s*(.+)$"#, areaLine.value)?.first
        let area = explicitArea ?? areaLine.value
        let standaloneHeading = area.split(whereSeparator: \.isWhitespace).allSatisfy { $0.first?.isUppercase == true }
        guard label(area), explicitArea != nil || standaloneHeading,
              capture(#"\b(?:draft|unknown|notes|reminder|recommendations|shortlist|opening hours)\b"#, area) == nil,
              area.caseInsensitiveCompare(city[0]) != .orderedSame else { return nil }
        return ListFrame(city: city[0], cityLine: cityLine, category: type, categoryLine: cityLine,
                         neighborhood: area, neighborhoodLine: areaLine)
    }

    private static func listIdentity(_ text: String) -> (name: String, area: String?)? {
        if let pair = capture(#"^(.+?)\s+[—–-]\s+([^.!?]+)(?:[.!?]|$)"#, text), label(pair[0]) {
            // A title-cased suffix in an explicit scoped shortlist is the
            // area column. A prose suffix remains an unclassified note.
            let area = pair[1]
            let isFacet = label(area) && area.split(whereSeparator: \.isWhitespace)
                .allSatisfy { $0.first?.isUppercase == true }
            return (pair[0], isFacet ? area : nil)
        }
        guard let name = capture(#"^([^.!?]+)(?:[.!?]|$)"#, text)?.first else { return nil }
        return (name, nil)
    }

    private static func reason(in entry: [SourceObservation], titleBody: String)
        -> (value: String, lines: [SourceObservation])? {
        let detail = #"(?:^|[.!?]\s+)((?:save for|go for|try|order|get the|ask for|pick this for|good for|known for)\s+[^.!?]+[.!?]?)$"#
        let dash = #"\s+[—–-]\s+(for\s+[^.!?]+[.!?]?)$"#
        for i in entry.indices {
            let line = entry[i]
            let body = i == 0 ? titleBody : line.value
            let one = capture(detail, body)?.first ?? (i == 0 ? capture(dash, body)?.first : nil)
            if let one, one.last.map({ ".!?".contains($0) }) == true { return (one, [line]) }
            if i + 1 < entry.count,
               entry[i + 1].value.first?.isLowercase == true {
                let combined = body + " " + entry[i + 1].value
                let both = capture(detail, combined)?.first ?? (i == 0 ? capture(dash, combined)?.first : nil)
                if let both { return (both, [line, entry[i + 1]]) }
            }
            if let one, i != 0 { return (one, [line]) }
        }
        return nil
    }

    private static func directory(_ lines: [SourceObservation], source: SourceSnapshot) -> Self? {
        guard lines.contains(where: { capture(#"\b(?:directory|listing|(?:place|shop|venue|business) profile)\b"#, $0.value) != nil })
        else { return nil }
        let categories = lines.indices.compactMap { i in
            let type = capture(#"^category:\s*(.+)$"#, lines[i].value)
                ?? capture(#"^([^•·]+)\s+[•·]\s+([^•·]+)$"#, lines[i].value)
            return (type.flatMap { category($0[0]) } ?? category(lines[i].value)).map { (i, $0) }
        }
        guard categories.count == 1, let (i, categoryValue) = categories.first, i >= 2,
              let area = capture(#"^(.+?)\s+(?:location|branch)$"#, lines[i - 1].value)?.first, label(area),
              label(lines[i - 2].value),
              lines.indices.contains(i + 2),
              capture(#"^\p{Nd}+(?:-\p{Nd}+)?\s+\p{L}[^,]+$"#, lines[i + 1].value) != nil,
              let geography = capture(#"^([^,]+),\s+([^,]+)$"#, lines[i + 2].value),
              geography[0].caseInsensitiveCompare(area) == .orderedSame, label(geography[1])
        else { return nil }
        let city = geography[1]
        let facts = [
            fact(.name, lines[i - 2].value, [lines[i - 2]], source),
            fact(.branch, area, [lines[i - 1]], source),
            fact(.neighborhood, area, [lines[i + 2]], source),
            fact(.city, city, [lines[i + 2]], source),
            fact(.address, lines[i + 1].value + " " + lines[i + 2].value, [lines[i + 1], lines[i + 2]], source),
            fact(.category, categoryValue, [lines[i]], source),
            fact(.subjectRole, "listing", [lines[i], lines[i + 1]], source)
        ]
        let mention = SavedPlaceMention(recordID: "pin.saved-place|" + source.reference.id,
                                        recordRevision: source.reference.revision,
                                        source: source.reference, facts: facts)
        return Self(mentions: [mention], unresolved: false)
    }

    /// A one-place note may put the city in its heading and the
    /// recommendation in the message body. A branch reference needs an
    /// explicit save act for that same branch, rather than a venue mention.
    private static func scopedRecommendation(_ lines: [SourceObservation], source: SourceSnapshot) -> Self? {
        let cityPatterns = [
            #"^(?:ideas|food plans|places to try) (?:for|in) (.+)$"#,
            #"^(?:weekend|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) in (.+)$"#
        ]
        let headers = lines.enumerated().compactMap { i, line in
            cityPatterns.compactMap { capture($0, line.value)?.first }
                .first(where: label).map { (i, $0) }
        }
        guard headers.count == 1, let (i, city) = headers.first, i + 1 < lines.count else { return nil }
        let body = Array(lines.dropFirst(i + 1))
        if body.contains(where: {
            capture(#"\b(?:(?:do not|don't|never)\s+(?:save|add|try|put|keep)|remove|skip|avoid|cross off)\b"#, $0.value) != nil
        }) { return Self(mentions: [], unresolved: true) }
        let text = body.map(\.value).joined(separator: " ")
        var name: String
        var area: String
        var type: String
        var detail: String?
        var roleProof: [SourceObservation]
        var typeProof: [SourceObservation]
        var namedBranch = false
        if let parts = capture(#"\b((?:save|add|try)\s+(.+?)\s+in\s+([^.!?,]+?))\s+for\s+([^.!?]+[.!?])"#, text),
           label(parts[1]), label(parts[2]), let suffix = categorySuffix(parts[1]),
           let anchors = literal(parts[0], in: body) {
            name = parts[1]
            area = parts[2]
            type = suffix
            detail = parts[3]
            roleProof = anchors
            typeProof = literal(name, in: body) ?? anchors
        } else if let parts = anotherBranch(in: body),
                  label(parts[0]), label(parts[2]), let category = category(parts[1]),
                  let quote = capture(#"((?:put|add|keep|save) (?:the )?"# +
                    NSRegularExpression.escapedPattern(for: parts[2]) +
                    #" branch (?:on|to|in) (?:our|my|the) (?:[\p{L}]+ )?list(?: too)?[.!?])"#, text)?.first,
                  let anchors = literal(quote, in: body) {
            name = parts[0]
            area = parts[2]
            type = category
            namedBranch = true
            roleProof = anchors
            typeProof = literal(name + " has another " + parts[1], in: body)
                ?? literal(parts[1] + " in " + parts[2], in: body) ?? anchors
            detail = capture(#"\b((?:they have|it has)\s+[^.!?]+[.!?])"#, text)?.first
        } else { return nil }
        guard let titleLines = literal(name, in: body), let areaLines = literal(area, in: body) else { return nil }
        var facts = [
            fact(.name, name, titleLines, source), fact(.neighborhood, area, areaLines, source),
            fact(.city, city, [lines[i]], source), fact(.category, type, typeProof, source),
            fact(.subjectRole, "recommendation", roleProof, source)
        ]
        if namedBranch { facts.append(fact(.branch, area, roleProof, source)) }
        if let detail, let anchors = literal(detail, in: body) {
            facts.append(fact(.reason, detail, anchors, source))
        }
        return Self(mentions: [.init(recordID: "pin.saved-place|" + source.reference.id,
                                     recordRevision: source.reference.revision,
                                     source: source.reference, facts: facts)], unresolved: false)
    }

    private struct ProseEntry {
        let index: Int
        let name: String
        let neighborhood: String?
        let detail: String?
    }

    /// A declared geographic shortlist may express separate positive
    /// recommendations as sentences rather than bullets. Their reasons and
    /// neighborhood clauses are not shared with neighboring recommendations.
    private static func proseShortlist(_ lines: [SourceObservation], source: SourceSnapshot) -> Self? {
        let headers: [(index: Int, city: String, type: String)] = lines.enumerated().compactMap { i, line in
            guard let fields = capture(#"^(?:(?:my|our) )?([^.!?,:]+?) (caf[eé]s?|restaurants?|coffee shops?) (?:picks|ideas|shortlist|to try)$"#, line.value),
                  label(fields[0]), let type = category(fields[1]) else { return nil }
            return (i, fields[0], type)
        }
        guard headers.count == 1, let frame = headers.first else { return nil }
        let nouns = #"(?:caf[eé]s|restaurants|coffee shops)"#
        let entries: [ProseEntry] = lines.indices.dropFirst(frame.index + 1).compactMap { i in
            guard let fields = capture(#"^(?:of the ([^,.!?]+?) "# + nouns +
                #", )?(?:try|save|add|recommend) ([^,.!?]+?)(?: for ([^.!?]+))?[.!?]?$"#, lines[i].value),
                  label(fields[1]), categorySuffix(fields[1]) == frame.type else { return nil }
            let area = fields[0].isEmpty || !label(fields[0]) ? nil : fields[0]
            return ProseEntry(index: i, name: fields[1], neighborhood: area,
                              detail: fields[2].isEmpty ? nil : fields[2])
        }
        // A single unscoped recommendation still goes through the ordinary
        // reader. This path needs clear evidence of separate list entries.
        guard entries.count >= 2 else { return nil }
        let mentions = entries.enumerated().compactMap { index, entry -> SavedPlaceMention? in
            let end = index + 1 < entries.count ? entries[index + 1].index : lines.count
            let block = Array(lines[entry.index..<end]).prefix(while: { line in
                capture(#"^(?:(?:do not|don't|never) (?:add|save|try)|skip|exclude|cross off)\b"#, line.value) == nil
            })
            guard let sourceLine = block.first else { return nil }
            var facts = [
                fact(.name, entry.name, [sourceLine], source), fact(.city, frame.city, [lines[frame.index]], source),
                fact(.category, frame.type, [lines[frame.index]], source),
                fact(.subjectRole, "recommendation", [lines[frame.index], sourceLine], source)
            ]
            if let area = entry.neighborhood { facts.append(fact(.neighborhood, area, [sourceLine], source)) }
            if let detail = entry.detail { facts.append(fact(.reason, detail, [sourceLine], source)) }
            else if let detailLine = block.dropFirst().first,
                    let detail = capture(#"^(for\s+[^.!?]+[.!?]?)$"#, detailLine.value)?.first {
                facts.append(fact(.reason, detail, [detailLine], source))
            }
            let recordID = "pin.saved-place.entry|\(source.reference.id.utf8.count)|\(source.reference.id)|\(sourceLine.id)"
            return .init(recordID: recordID, recordRevision: source.reference.revision, source: source.reference, facts: facts)
        }
        return Self(mentions: mentions, unresolved: false)
    }

    private static func namedSaveWithLocation(_ lines: [SourceObservation], source: SourceSnapshot) -> Self? {
        let text = lines.map(\.value).joined(separator: " ")
        guard !hasNegativeSave(text),
              let save = capture(#"((?:also )?(?:add|put|save) ([^.!?,]+) (?:to|on) (?:the|my|our) list)\."#, text),
              label(save[1]), let type = categorySuffix(save[1]),
              let identity = literal(save[1], in: lines), let role = literal(save[0], in: lines),
              let location = capture(#"(?:(?:it is|it's) in) ([^.!?,]+), ([^.!?,]+)[.!?]"#, text),
              label(location[0]), label(location[1]),
              let area = literal(location[0], in: lines), let city = literal(location[1], in: lines)
        else { return nil }
        var facts = [
            fact(.name, save[1], identity, source), fact(.city, location[1], city, source),
            fact(.neighborhood, location[0], area, source), fact(.category, type, identity, source),
            fact(.subjectRole, "recommendation", role, source)
        ]
        if let detail = capture(#"((?:want to go for|look forward to|try) the [^.!?]+[.!?])"#, text)?.first,
           let anchors = literal(detail, in: lines) {
            facts.append(fact(.reason, detail, anchors, source))
        }
        return Self(mentions: [single(facts, source: source)], unresolved: false)
    }

    private static func headedSingleSave(_ lines: [SourceObservation], source: SourceSnapshot) -> Self? {
        let headers: [(i: Int, city: String, type: String)] = lines.enumerated().compactMap { i, line in
            guard let parts = capture(#"^([^.!?,:]+?)\s+(caf[eé]s?|restaurants?|coffee shops?)\s+(?:ideas|shortlist|to try)$"#, line.value),
                  label(parts[0]), let type = category(parts[1]) else { return nil }
            return (i, parts[0], type)
        }
        guard headers.count == 1, let frame = headers.first else { return nil }
        let body = Array(lines.dropFirst(frame.i + 1))
        let text = body.map(\.value).joined(separator: " ")
        guard !hasNegativeSave(text),
              let parts = capture(#"((?:save|try)\s+([^.!?,]+?))\s+for\s+([^.!?]+[.!?])"#, text),
              label(parts[1]), let identity = literal(parts[1], in: body),
              let role = literal(parts[0], in: body), let reason = literal(parts[2], in: body) else { return nil }
        let statementCount = ["save ", "try ", "add ", "recommend "].reduce(0) { count, verb in
            count + body.filter { $0.value.lowercased().hasPrefix(verb) }.count
        }
        guard statementCount == 1 else { return Self(mentions: [], unresolved: true) }
        let heading = lines[frame.i]
        var facts = [
            fact(.name, parts[1], identity, source), fact(.city, frame.city, [heading], source),
            fact(.category, frame.type, [heading], source), fact(.subjectRole, "recommendation", role, source),
            fact(.reason, parts[2], reason, source)
        ]
        if let area = capture(#"\bkeep it on (?:my|our|the) ([^.!?,]+?) list[.!?]"#, text)?.first,
           label(area), let anchors = literal(area, in: body) {
            facts.append(fact(.neighborhood, area, anchors, source))
        }
        return Self(mentions: [single(facts, source: source)], unresolved: false)
    }

    private static func branchSave(_ lines: [SourceObservation], source: SourceSnapshot) -> Self? {
        let text = lines.map(\.value).joined(separator: " ")
        guard !hasNegativeSave(text),
              let parts = explicitBranchPhrases(in: lines),
              label(parts[1]), label(parts[2]), let type = categorySuffix(parts[2]),
              let city = capture(#"\b(?:a separate location|another location|the location|this branch) in ([^.!?,]+)[.!?]"#, text)?.first
                ?? lines.lazy.compactMap({ capture(#"^Places to try in ([^.!?,]+)$"#, $0.value)?.first }).first,
              label(city), let named = literal(parts[2], in: lines),
              let role = literal(parts[0], in: lines), let cityAnchors = literal(city, in: lines)
        else { return nil }
        var facts = [
            fact(.name, parts[2], named, source), fact(.city, city, cityAnchors, source),
            fact(.category, type, named, source), fact(.branch, parts[1], role, source),
            fact(.subjectRole, "recommendation", role, source)
        ]
        let place = city + " " + parts[1] + " location"
        if let areaProof = literal(place, in: lines) { facts.append(fact(.neighborhood, parts[1], areaProof, source)) }
        if let detail = capture(#"(?:^|[.!?]\s+)((?:try|order|ask for)\s+(?:the|their)\s+[^.!?]+[.!?])"#, text)?.first,
           let anchors = literal(detail, in: lines) {
            facts.append(fact(.reason, detail, anchors, source))
        }
        return Self(mentions: [single(facts, source: source)], unresolved: false)
    }

    private static func explicitBranchPhrases(in lines: [SourceObservation]) -> [String]? {
        let pattern = #"^((?:keep|save|try|add) (?:the )?([^.!?,]+?) branch of ([^.!?,]+?))(?: too)?[.!?]"#
        let phrases = lines.indices.compactMap { i -> [String]? in
            let next = i + 1 < lines.count ? " " + lines[i+1].value : ""
            return capture(pattern, lines[i].value + next)
        }
        return phrases.count == 1 ? phrases.first : nil
    }

    private static func hasNegativeSave(_ text: String) -> Bool {
        capture(#"\b(?:(?:do not|don't|never)\s+(?:save|add|try|put|keep)|crossed off|removed from)\b"#, text) != nil
    }

    private static func single(_ facts: [SavedPlaceFact], source: SourceSnapshot) -> SavedPlaceMention {
        .init(recordID: "pin.saved-place|" + source.reference.id, recordRevision: source.reference.revision,
              source: source.reference, facts: facts)
    }

    private static func anotherBranch(in lines: [SourceObservation]) -> [String]? {
        let pattern = #"^([\p{L}\p{M}][\p{L}\p{M} '’\-]+?)\s+(?:has|runs|opened) another (caf[eé]|coffee shop|restaurant) in ([^.!?,]+)[.!?]"#
        let options = lines.indices.compactMap { i -> [String]? in
            let next = i + 1 < lines.count ? " " + lines[i + 1].value : ""
            return capture(pattern, lines[i].value + next)
        }
        return options.count == 1 ? options.first : nil
    }

    private static func literal(_ value: String, in lines: [SourceObservation]) -> [SourceObservation]? {
        if let line = lines.first(where: { $0.value.contains(value) }) { return [line] }
        for i in lines.indices.dropLast() {
            if (lines[i].value + " " + lines[i + 1].value).contains(value) { return [lines[i], lines[i + 1]] }
        }
        return nil
    }

    private static func categorySuffix(_ name: String) -> String? {
        for type in ["cafe", "café", "coffee shop", "restaurant"] where name.lowercased().hasSuffix(" " + type) {
            return category(type)
        }
        return nil
    }

    private static func category(_ value: String) -> String? {
        switch value.lowercased() {
        case "cafe", "cafes", "café", "cafés", "coffee shop", "coffee shops", "coffee stops": "cafe"
        case "restaurant", "restaurants": "restaurant"
        default: nil
        }
    }

    private static func label(_ value: String) -> Bool {
        value.count <= 80 && capture(#"^[\p{L}\p{M}][\p{L}\p{M}\p{N} '&’\-]*$"#, value) != nil
    }

    private static func fact(_ field: SavedPlaceField, _ value: String,
                             _ observations: [SourceObservation], _ source: SourceSnapshot) -> SavedPlaceFact {
        SavedPlaceFact(field, value: value, anchors: observations.map {
            EvidenceAnchor(source: source.reference, observationID: $0.id, quote: $0.value)
        }, extractorVersion: version)
    }

    private static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }
}
