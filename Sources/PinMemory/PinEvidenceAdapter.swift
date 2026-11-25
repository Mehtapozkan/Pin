import Foundation
import CryptoKit
import PinCore
import IBrain

public enum PinEvidenceError: Error, Equatable, Sendable {
    case invalidSource, duplicateSource, invalidRecord, staleRecord, invalidSupport
}

/// Identity/revision supplied by Pin's domain writer. A reference match or model
/// proposal cannot create this identity or establish that two photos are one event.
public struct PinRecordPin: Equatable, Sendable {
    public let id: String
    public let revision: Int
    public let sources: Set<PinCore.EvidenceSource>
    public init(id: String, revision: Int, sources: Set<PinCore.EvidenceSource>) {
        self.id = id; self.revision = revision; self.sources = sources
    }
}

/// Both confidences remain available: semantic-provider support and actual OCR.
/// A native FieldFact never relabels provider confidence as Vision confidence.
public struct PinFieldBinding: Sendable {
    public let semanticSupport: FieldSupport
    public let nativeFacts: [PinCore.FieldFact]
}

/// Mechanical binding only. This neither approves field meaning nor writes an
/// appointment. Pin must admit meaning through its domain writer, recheck this
/// complete authority snapshot, and publish in the same native authority turn.
public struct PinEvidenceBinding: Sendable {
    public let projection: MemoryProjection
    public let fields: [PinFieldBinding]
    public let authorityDigest: String
}

/// The permitted photo revisions that contributed to a library-wide answer,
/// including photos that yielded no card. New evidence can contradict a match.
public struct PinPhotoInventory: Sendable {
    private let revisions: Set<PinCore.EvidenceSource>

    init(_ photos: some Collection<PinCore.PhotoMemory>) {
        revisions = Set(photos.map(PinCore.EvidenceSource.init))
    }

    public func matches(_ photos: [PinCore.PhotoMemory]) -> Bool {
        photos.count == revisions.count && Set(photos.map(PinCore.EvidenceSource.init)) == revisions
    }
}

/// A complete Pin-owned inventory for ONE private projection scope, never a page
/// of an index. This is an immutable adapter value, not a second source store.
public struct PinEvidenceSnapshot: Sendable {
    public let scope: MemoryScope
    public let authority: AuthoritySnapshot
    public let authorityDigest: String
    public var photoInventory: PinPhotoInventory { PinPhotoInventory(memories.values) }
    private let memories: [String: PinCore.PhotoMemory]
    private let lines: [String: [String: PinCore.CardLine]]
    private let pins: [String: PinRecordPin]

    public init(memories input: [PinCore.PhotoMemory], records: [PinRecordPin], scope: MemoryScope, pendingSourcePreparations:Set<PinCore.EvidenceSource> = []) throws {
        guard !scope.ownerID.isEmpty, !scope.namespace.isEmpty else { throw PinEvidenceError.invalidSource }
        var memories: [String: PinCore.PhotoMemory] = [:]
        var lines: [String: [String: PinCore.CardLine]] = [:]
        var snapshots: [SourceSnapshot] = []
        for memory in input.sorted(by: { $0.id < $1.id }) {
            guard memories[memory.id] == nil else { throw PinEvidenceError.duplicateSource }
            guard !memory.id.isEmpty, !memory.fingerprint.isEmpty, memory.revision > 0 else { throw PinEvidenceError.invalidSource }
            var observations: [SourceObservation] = []
            var sourceLines: [String: PinCore.CardLine] = [:]
            for (offset, line) in (memory.textEvidence ?? []).enumerated() {
                guard !line.text.isEmpty, line.confidence.isFinite, (0...1).contains(line.confidence),
                      line.region?.isValid ?? true else { throw PinEvidenceError.invalidSource }
                let id = try PinOCRObservationID.make(line, offset: offset)
                sourceLines[id] = line
                observations.append(.init(id: id, value: line.text))
            }
            memories[memory.id] = memory; lines[memory.id] = sourceLines
            snapshots.append(try PinVisualReadingProjection.source(memory:memory,scope:scope,textObservations:observations))
        }
        var pins: [String: PinRecordPin] = [:]
        for pin in records {
            guard !pin.id.isEmpty, pin.revision > 0, !pin.sources.isEmpty, pins[pin.id] == nil,
                  pin.sources.allSatisfy({ source in memories[source.id].map { PinCore.EvidenceSource($0) == source } == true })
            else { throw PinEvidenceError.invalidRecord }
            pins[pin.id] = pin
        }
        let domain = records.sorted { $0.id < $1.id }.map {
            DomainRecordPin(id: $0.id, revision: $0.revision, sources: Set($0.sources.map(Self.reference)))
        }
        self.scope = scope; self.memories = memories; self.lines = lines; self.pins = pins
        guard pendingSourcePreparations.isSubset(of:Set(input.map(PinCore.EvidenceSource.init)))else{throw PinEvidenceError.staleRecord}
        let pending=Set(pendingSourcePreparations.map(Self.reference))
        authority = .init(sources: snapshots, records: domain,pendingSourcePreparations:pending)
        // Set encoding is unordered; encode canonical native pins explicitly.
        struct PinDigest: Encodable { let id: String; let revision: Int; let sources: [SourceReference] }
        struct Inventory: Encodable { let sources: [SourceSnapshot]; let records: [PinDigest];let pendingSourcePreparations:[SourceReference]? }
        let canonical = domain.map { pin in PinDigest(id: pin.id, revision: pin.revision, sources: pin.sources.sorted { $0.id < $1.id }) }
        authorityDigest = try Self.digest(Inventory(sources: snapshots, records: canonical,pendingSourcePreparations:pending.isEmpty ? nil:pending.sorted{$0.id<$1.id}))
    }

    /// Raw legacy OCR strings do not become region/confidence evidence. A source
    /// with no textEvidence remains in the current inventory with no observations.
    public func observationID(sourceID: String, lineOffset: Int) -> String? {
        guard let source = authority.sources.first(where: { $0.reference.id == sourceID }), source.observations.indices.contains(lineOffset) else { return nil }
        return source.observations[lineOffset].id
    }

    public func bindEvidence(for projection: MemoryProjection) throws -> PinEvidenceBinding {
        guard projection.scope == scope, let pin = pins[projection.recordID], pin.revision == projection.recordRevision,
              Set(pin.sources.map(Self.reference)) == projection.sources else { throw PinEvidenceError.staleRecord }
        let a = projection.appointment
        guard !(a.date.certainty == .explicit && projection.support.contains(where:{$0.field == .date && $0.origin == .inferred})) else{throw PinEvidenceError.invalidSupport}
        var required: Set<AppointmentField> = [.title, .date, .kind, .status]
        if a.provider != nil { required.insert(.provider) }
        if a.venue != nil { required.insert(.venue) }
        if a.performer != nil { required.insert(.performer) }
        if a.venueAddress != nil { required.insert(.venueAddress) }
        if projection.documentOnlyWithoutDate == true {
            guard a.date.year == nil, a.date.month == nil, a.date.day == nil, a.date.hour == nil,
                  a.date.minute == nil, a.date.timeZoneID == nil, a.date.utcOffsetSeconds == nil else { throw PinEvidenceError.invalidSupport }
            required.remove(.date)
        }
        guard Set(projection.support.map(\.field)) == required,
              projection.support.count == required.count else { throw PinEvidenceError.invalidSupport }
        var bindings: [PinFieldBinding] = []
        for support in projection.support.sorted(by: { $0.field.rawValue < $1.field.rawValue }) {
            guard !support.anchors.isEmpty, !support.extractorVersion.isEmpty,
                  support.confidence.isFinite, (0...1).contains(support.confidence) else { throw PinEvidenceError.invalidSupport }
            let value: String
            switch support.field {
            case .title: value = a.title
            case .provider: value = a.provider ?? ""
            case .venue: value = a.venue ?? ""
            case .performer: value = a.performer ?? ""
            case .venueAddress: value = a.venueAddress ?? ""
            case .kind: value = a.kind.rawValue
            case .status: value = a.status.rawValue
            case .date: value = String(decoding: try Self.data(a.date), as: UTF8.self)
            }
            guard !value.isEmpty else { throw PinEvidenceError.invalidSupport }
            var bySource: [String: [PinCore.CardLine]] = [:]
            var visualBySource:[String:[PinCore.VisualFactSupport]]=[:]
            for anchor in support.anchors {
                guard let memory = memories[anchor.source.id], Self.reference(PinCore.EvidenceSource(memory)) == anchor.source,
                      !anchor.quote.isEmpty else { throw PinEvidenceError.invalidSupport }
                if let line=lines[memory.id]?[anchor.observationID],Data(line.text.utf8).range(of:Data(anchor.quote.utf8)) != nil {
                    if bySource[memory.id]?.contains(line) != true {bySource[memory.id,default:[]].append(line)}
                } else if [.kind,.status].contains(support.field),let reading=memory.visualReading,
                          let visual=try reading.visualSupports().first(where:{$0.observationID==anchor.observationID && $0.value==anchor.quote}) {
                    if visualBySource[memory.id]?.contains(visual) != true {visualBySource[memory.id,default:[]].append(visual)}
                } else {throw PinEvidenceError.invalidSupport}
            }
            let facts = Set(bySource.keys).union(visualBySource.keys).sorted().map { sourceID -> PinCore.FieldFact in
                let proof = bySource[sourceID] ?? []
                // Civil components and classification are interpreted values.
                // The entire semantic origin remains on semanticSupport.
                let literal = ![AppointmentField.date, .kind, .status].contains(support.field) &&
                    support.origin == .observed && proof.contains { Data($0.text.utf8).range(of: Data(value.utf8)) != nil }
                return PinCore.FieldFact(field: support.field == .date ? "eventDate" : support.field.rawValue,
                    value: value, origin: literal ? .observed : .inferred,
                    source: PinCore.EvidenceSource(memories[sourceID]!), support: proof, extractorVersion: support.extractorVersion,visualSupport:visualBySource[sourceID])
            }
            bindings.append(.init(semanticSupport: support, nativeFacts: facts))
        }
        return PinEvidenceBinding(projection: projection, fields: bindings, authorityDigest: authorityDigest)
    }

    private static func reference(_ s: PinCore.EvidenceSource) -> SourceReference {
        .init(id: s.id, revision: s.revision, fingerprint: s.fingerprint)
    }
    private static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try data(value)).map { String(format: "%02x", $0) }.joined()
    }
}
