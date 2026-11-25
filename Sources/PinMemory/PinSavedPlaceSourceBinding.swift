import IBrain
import IBrainRetrieval
import PinCore

/// Resolves semantic references against Pin's current native catalogue. It
/// does not establish access on its own. The PhotoKit owner supplies the
/// current catalogue and checks the asset again before showing an original.
public enum PinSavedPlaceSourceBinding {
    public static func catalog(
        scope: MemoryScope, memories: [PhotoMemory], records: [PinRecordPin],
        mentions: [SavedPlaceMention], interpretations: [SavedPhotoInterpretation],
        coverage: SavedPlaceCoverage
    ) throws -> SavedPlaceCatalog {
        let snapshot = try PinEvidenceSnapshot(memories: memories, records: records, scope: scope)
        let pins = Dictionary(uniqueKeysWithValues: snapshot.authority.records.map { ($0.id, $0) })
        let saved = Dictionary(grouping: interpretations, by: { $0.source.id })
        guard saved.values.allSatisfy({ $0.count == 1 }) else { throw PinEvidenceError.invalidRecord }
        for interpretation in interpretations {
            let source = interpretation.source
            _ = try resolve([SourceReference(id: source.id, revision: source.revision,
                                              fingerprint: source.fingerprint)], in: memories)
        }

        let current = try mentions.map { mention -> SavedPlaceMention in
            guard let pin = pins[mention.recordID], pin.revision == mention.recordRevision,
                  pin.sources == [mention.source],
                  mention.facts.allSatisfy({ $0.origin != .domainCorrection }) else {
                throw PinEvidenceError.invalidRecord
            }
            guard let interpretation = saved[mention.source.id]?.first else { return mention }
            var facts = mention.facts
            for correction in interpretation.placeCorrections ?? [] where correction.mentionID == mention.recordID {
                guard let field = SavedPlaceField(rawValue: correction.field.rawValue) else {
                    throw PinEvidenceError.invalidSupport
                }
                let anchors = facts.filter { $0.field == field }.flatMap(\.anchors)
                facts.removeAll { $0.field == field }
                facts.append(SavedPlaceFact(field, value: correction.value, origin: .domainCorrection,
                                             anchors: anchors, extractorVersion: "pin-place-correction-v1"))
            }
            return SavedPlaceMention(recordID: mention.recordID,
                                     recordRevision: max(mention.recordRevision, interpretation.recordRevision),
                                     source: mention.source, facts: facts)
        }

        let authority = AuthoritySnapshot(
            sources: snapshot.authority.sources,
            records: current.map {
                DomainRecordPin(id: $0.recordID, revision: $0.recordRevision,
                                sources: [$0.source], recordKind: .worldEntity)
            }
        )
        return try SavedPlaceCatalog(scope: scope, authority: authority, mentions: current, coverage: coverage)
    }

    public static func originalReferences(
        cardID: String, field: SavedPlaceField?, answer: SavedPlaceAnswer,
        displayed: SavedPlaceDisplayedContext, catalog: SavedPlaceCatalog
    ) throws -> [SourceReference] {
        let originals = try catalog.originals(for: cardID, in: displayed, parentRequestID: answer.requestID)
        guard let field else { return originals }
        guard let card = answer.cards.first(where: { $0.id == cardID }) else {
            throw PinEvidenceError.staleRecord
        }
        let supporting = Set(card.members.filter { member in
            member.facts.contains { $0.field == field && $0.origin != .inferred }
        }.map(\.source))
        guard !supporting.isEmpty, supporting.isSubset(of: Set(originals)) else {
            throw PinEvidenceError.invalidSupport
        }
        return originals.filter { supporting.contains($0) }
    }

    /// PhotoKit provides one fingerprint per accessible ID requested for this selection.
    public static func validateCurrentReadings(_ readings: [PhotoMemory], visible: [PhotoMemory],
                                               fingerprints: [String: String]) throws {
        guard fingerprints.count == readings.count,
              readings.allSatisfy({ fingerprints[$0.id] == $0.fingerprint }) else {
            throw PinStoreError.staleResult
        }
        if readings == visible { return }
        let byID = Dictionary(grouping: visible, by: \.id)
        for reading in readings {
            guard let matches = byID[reading.id], matches.count == 1, matches.first == reading else {
                throw PinStoreError.staleResult
            }
        }
    }

    public static func resolve(
        _ references: [SourceReference],
        in memories: [PhotoMemory]
    ) throws -> [PhotoMemory] {
        guard !references.isEmpty else { throw PinEvidenceError.staleRecord }
        let byID = Dictionary(grouping: memories, by: \.id)
        var resolved = [PhotoMemory]()
        var included = Set<String>()
        for reference in references {
            let expected = EvidenceSource(
                id: reference.id,
                fingerprint: reference.fingerprint,
                revision: reference.revision
            )
            guard let matches = byID[reference.id],
                  matches.count == 1,
                  let memory = matches.first,
                  expected.matches(memory) else {
                throw PinEvidenceError.staleRecord
            }
            if included.insert(reference.id).inserted {
                resolved.append(memory)
            }
        }
        return resolved
    }
}
