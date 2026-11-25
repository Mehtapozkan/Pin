import Foundation

public struct VisualLabel: Codable, Equatable, Sendable {
    public var name: String
    public var confidence: Double
    public init(_ name: String, confidence: Double) { self.name = name; self.confidence = confidence }
}

public struct PhotoCoordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

/// A fact is a projection of a specific source version, never an authority for
/// access, sharing or action. Only application records bind current versions.
public struct EvidenceSource: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var fingerprint: String
    public var revision: Int
    public init(id:String,fingerprint:String,revision:Int) { self.id=id;self.fingerprint=fingerprint;self.revision=revision }
    public init(_ memory:PhotoMemory) { self.init(id:memory.id,fingerprint:memory.fingerprint,revision:memory.revision) }
    public func matches(_ memory:PhotoMemory) -> Bool { self == EvidenceSource(memory) }
}
public enum FactOrigin: String, Codable, Sendable { case observed, inferred, external }
/// A reader's bounded visual claim, kept separate from OCR and its confidence.
public struct VisualFactSupport:Codable,Equatable,Sendable {
    public let observationID:String
    public let kind:String
    public let value:String
    public let region:EvidenceRegion
    public let receiptSHA256:String
    public let requestSHA256:String
    public let originalSHA256:String
    public let frameSHA256:String
    public let provider:String
    public let model:String
    public var isValid:Bool {
        kind=="visualLabel" && !value.isEmpty && region.isValid && !provider.isEmpty && !model.isEmpty &&
        observationID.hasPrefix("pin-visual-v1:") && observationID.hasSuffix(":"+receiptSHA256) &&
        [receiptSHA256,requestSHA256,originalSHA256,frameSHA256].allSatisfy{$0.count==64 && $0.allSatisfy{"0123456789abcdef".contains($0)}}
    }
}
public struct FieldFact: Codable, Equatable, Sendable {
    public var field: String
    public var value: String
    public var origin: FactOrigin
    public var source: EvidenceSource
    /// Exact local OCR lines and their image regions, not rewritten quotations.
    public var support: [CardLine]
    public var visualSupport:[VisualFactSupport]?
    public var confidence: Float
    public var extractorVersion: String
    /// Required for external directory claims; never represented as printed text.
    public var reference: String?
    public var referenceVersion: String?
    public var lookedUpAt: String?
    public init(field:String,value:String,origin:FactOrigin,source:EvidenceSource,support:[CardLine],extractorVersion:String,reference:String?=nil,referenceVersion:String?=nil,lookedUpAt:String?=nil,visualSupport:[VisualFactSupport]?=nil) {
        self.field=field;self.value=value;self.origin=origin;self.source=source;self.support=support
        self.visualSupport=visualSupport?.isEmpty == false ? visualSupport:nil
        self.confidence=self.visualSupport == nil ? (support.map(\.confidence).min() ?? 0):0
        self.extractorVersion=extractorVersion;self.reference=reference;self.referenceVersion=referenceVersion;self.lookedUpAt=lookedUpAt
    }
}

/// Derived observations, never a user-authored tagging or note system.
public struct PhotoMemory: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var fingerprint: String
    public var photographedAt: Date?
    public var coordinate: PhotoCoordinate?
    public var text: [String]
    public var labels: [VisualLabel]
    public var textEvidence: [CardLine]?
    public var visualReading:PhotoVisualReading?
    public var isScreenshot: Bool?
    public var imageRecognitionAvailable: Bool?
    public var revision: Int
    public init(id: String, fingerprint: String, photographedAt: Date? = nil, coordinate: PhotoCoordinate? = nil, text: [String] = [], labels: [VisualLabel] = [], revision: Int = 1, imageRecognitionAvailable: Bool? = nil, textEvidence: [CardLine]? = nil, isScreenshot: Bool? = nil, visualReading:PhotoVisualReading? = nil) {
        self.id = id; self.fingerprint = fingerprint; self.photographedAt = photographedAt
        self.coordinate = coordinate; self.text = text; self.labels = labels; self.revision = revision; self.imageRecognitionAvailable = imageRecognitionAvailable; self.textEvidence=textEvidence; self.isScreenshot=isScreenshot;self.visualReading=visualReading
    }
    public var isFootwear: Bool { labels.contains { $0.confidence >= 0.35 && Self.shoeTerms.contains(where: $0.name.lowercased().contains) } }
    public var title: String { isFootwear ? "The shoes you photographed" : "From your photos" }
    public static let shoeTerms = ["shoe", "sneaker", "footwear", "boot", "sandal", "slipper", "loafer"]
}

public struct RecallHit: Equatable, Sendable, Identifiable {
    public var memory: PhotoMemory
    public var score: Double
    public var id: String { memory.id }
    public init(memory: PhotoMemory, score: Double) { self.memory=memory; self.score=score }
}

/// Initial documented baseline: lexical recall over real Vision observations.
/// This is deliberately not labelled Jev or gbrain retrieval.
public enum LocalRecall {
    private static let colourTerms:Set<String>=["yellow","red","blue","green","cream","pink","white","black","brown","beige","orange","purple","gray","grey","gold","silver","navy"]
    private static func words(_ text:String)->[String] {
        text.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    public static func requestsShoeColour(_ question:String)->Bool {
        let tokens=words(question)
        return tokens.contains { word in PhotoMemory.shoeTerms.contains(where:word.hasPrefix) } && !Set(tokens).isDisjoint(with:colourTerms)
    }
    public static func find(_ question: String, in memories: [PhotoMemory], now: Date) -> [RecallHit] {
        let words = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let wantsShoes = words.contains { w in PhotoMemory.shoeTerms.contains(where: w.hasPrefix) }
        let requestedColours=Set(words).intersection(colourTerms).map { $0 == "grey" ? "gray" : $0 }
        let requestedKinds=Set(words.compactMap { word in PhotoMemory.shoeTerms.first(where:word.hasPrefix) }).subtracting(["shoe","footwear"])
        // Negative shoe constraints are not implemented by the lexical reader.
        // Hold them instead of returning the very item a person excluded.
        if wantsShoes && !Set(words).isDisjoint(with:["not","without","except","excluding"]) { return [] }
        let stop: Set<String> = ["the", "those", "that", "these", "a", "an", "i", "my", "me", "was", "were", "where", "what", "when", "did", "do", "is", "it", "they", "them", "took", "take", "taken", "photo", "photos", "photograph", "photographed", "picture", "pictures", "other", "day", "recent", "recently", "liked", "like", "find", "show", "remember", "and", "of", "in", "on", "at", "for", "some", "from"]
        let meaningful = words.filter { !stop.contains($0) }
        guard wantsShoes || !meaningful.isEmpty else { return [] }
        return memories.compactMap { memory -> RecallHit? in
            let corpus = (memory.text + memory.labels.filter { $0.confidence >= 0.35 }.map(\.name)).joined(separator: " ").lowercased()
            let matches = meaningful.filter { corpus.contains($0) }.count
            guard wantsShoes ? memory.isFootwear : matches > 0 else { return nil }
            if wantsShoes {
                let observed=Set(Self.words(corpus).map { $0 == "grey" ? "gray" : $0 })
                guard requestedColours.allSatisfy(observed.contains),
                      requestedKinds.allSatisfy({ kind in observed.contains(where: { token in token == kind || token == kind + "s" }) }) else { return nil }
            }
            var score = Double(matches) + (wantsShoes && memory.isFootwear ? 3 : 0)
            if let date = memory.photographedAt {
                let age = now.timeIntervalSince(date)
                if age >= 0 { score += max(0, 1 - age / (30 * 86400)) }
            }
            return RecallHit(memory: memory, score: score)
        }.sorted { a, b in a.score == b.score ? a.id < b.id : a.score > b.score }
    }
}

public enum PinStoreError: Error { case unsupportedSchema, staleImport, staleResult }

public enum PhotoReadIssue: String, Codable, Sendable { case needsDownload, photoUnavailable, analysisFailed }
public struct PhotoReadAttempt: Codable, Equatable, Sendable {
    public var fingerprint:String
    public var issue:PhotoReadIssue
}
public struct PhotoReadSummary: Equatable, Sendable {
    public var total=0
    public var read=0
    public var unread=0
    public var needsDownload=0
    public var unavailable=0
    public var failed=0
    // Subset of unread: retained observations await confirmed source details.
    public var sourceMetadataPending=0
    // Subsets of read, not extra photos. Reading is not proof of understanding.
    public var withoutUsableDetails=0
    public var partialRecognition=0
    public var incomplete:Int { unread + needsDownload + unavailable + failed }
    /// Use durable categories, rather than counters from only the latest pass.
    public var completionStatus: String {
        guard total > 0 else { return "No photos available to read in Pin." }
        var parts = ["\(read) photos read"]
        if unread > 0 { parts.append("\(unread) unread") }
        if needsDownload > 0 { parts.append("\(needsDownload) awaiting iCloud download") }
        if unavailable > 0 { parts.append("\(unavailable) couldn’t be opened") }
        if failed > 0 { parts.append("\(failed) couldn’t be analyzed") }
        return parts.joined(separator: " · ")
    }
}

/// Interpretation of the existing native vision-v4 signature. The format and
/// stored bytes do not change. While protected source details are unconfirmed,
/// metadata-only differences must not cause completed pixel analysis to repeat.
public enum SourceMetadataPolicy {
    public static func changedFields(previous:String,current:String)->Set<String> {
        guard previous != current else { return [] }
        let a=previous.split(separator:"|",omittingEmptySubsequences:false).map(String.init)
        let b=current.split(separator:"|",omittingEmptySubsequences:false).map(String.init)
        guard a.count == 6,b.count == 6,a[0] == "vision-v4",a[0] == b[0],a[1] == b[1] else { return ["opaque"] }
        let names=[2:"modified",3:"captured",4:"pixels",5:"location"]
        return Set(names.compactMap { index,name in a[index] == b[index] ? nil : name })
    }
    public static func needsConfirmation(previous:String,current:String)->Bool {
        let fields=changedFields(previous:previous,current:current)
        guard !fields.isEmpty,!fields.contains("opaque") else { return false }
        let b=current.split(separator:"|",omittingEmptySubsequences:false).map(String.init)
        // Unknown pixel-version metadata also waits for unlock. A positive new
        // modification version or size is a real image change, never deferred.
        let unknownModified=fields.contains("modified") && Double(b[2]) == 0
        let dimensions=b[4].split(separator:"x").compactMap { Int($0) }
        let unknownPixels=fields.contains("pixels") && dimensions.count == 2 && dimensions.contains(0)
        if fields.contains("modified") && !unknownModified { return false }
        if fields.contains("pixels") && !unknownPixels { return false }
        if unknownModified || unknownPixels { return true }
        return fields.isSubset(of:["captured","location"])
    }
}
public struct SourceReconciliationAudit: Equatable, Sendable {
    public var retained=0
    public var changed=0
    public var metadataDeferred=0
    /// Overlapping component counts, not extra photos or source values.
    public var changedFields:[String:Int]=[:]
}

public struct ImportPermit: Sendable { let epoch: Int; let owner:UUID }

/// Process-local CAS authority for replacing one current photo's text
/// observations. It is not an image-read grant or a model-dispatch permit.
public struct PhotoTextRereadTicket:Sendable {
    public let source:EvidenceSource
    fileprivate let owner:UUID
    fileprivate let epoch:Int
    fileprivate let previous:PhotoMemory
    fileprivate let previousInterpretation:SavedPhotoInterpretation?
}

/// A checked, immutable candidate observation. This is not current source
/// authority until the owning MemoryStore accepts its original CAS ticket.
public struct PreparedPhotoReread:Sendable {
    public let before:PhotoMemory
    public let after:PhotoMemory
    fileprivate let ticket:PhotoTextRereadTicket
}

/// A person's saved interpretation of one exact photo revision. It never
/// replaces the copied text or changes the source's identity.
public struct SavedPhotoInterpretation: Codable, Equatable, Sendable {
    public let source: EvidenceSource
    public let recordRevision: Int
    public let correction: String?
    public let placeCorrections: [SavedPlaceDetailCorrection]?
    public let planCorrections: [SavedPlanDetailCorrection]?
    public init(source: EvidenceSource, recordRevision: Int, correction: String?,
                placeCorrections: [SavedPlaceDetailCorrection]? = nil,
                planCorrections: [SavedPlanDetailCorrection]? = nil) {
        self.source=source;self.recordRevision=recordRevision;self.correction=correction
        self.placeCorrections = placeCorrections
        self.planCorrections = planCorrections
    }
}

/// A person edited a field for one place mention on this photo. The enclosing
/// interpretation supplies the current source revision and compare-and-swap ticket.
public struct SavedPlaceDetailCorrection: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable {
        case name, city, neighborhood, branch, address, reason
    }
    public let mentionID: String
    public let field: Field
    public let value: String

    fileprivate var isValid: Bool {
        !mentionID.isEmpty && mentionID.utf8.count <= 1024 &&
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 12_000
    }
}

/// An owner edit for a single participant and occurrence on a current photo.
public struct SavedPlanDetailCorrection: Codable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case title, date, time, location, status
    }
    public enum Status: String, Codable, CaseIterable, Sendable {
        case confirmed, tentative, cancelled, unclear, withdrawn
    }

    public let person: String
    public let field: Field
    public let value: String
    public let additionalSources: Set<EvidenceSource>

    public static func personKey(_ person: String) -> String {
        person.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    fileprivate var isValid: Bool {
        !person.isEmpty && person.utf8.count <= 320 && Self.personKey(person) == person &&
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512 &&
        (field != .status || Status(rawValue: value) != nil) &&
        additionalSources.allSatisfy { !$0.id.isEmpty && !$0.fingerprint.isEmpty && $0.revision > 0 }
    }
}

/// Authoritative local source catalogue. Only derived observations are stored;
/// originals remain in Photos. Visibility is re-established each launch.
public actor MemoryStore {
    struct State: Codable {
        var schema = 1
        var memories: [PhotoMemory] = []
        var forgotten: Set<String> = []
        var attempts: [String:PhotoReadAttempt]?
        var savedInterpretations: [String:SavedPhotoInterpretation]?
    }
    private var state: State
    private var visibleIDs: Set<String> = []
    private var sourceFingerprints: [String:String] = [:]
    private var metadataDeferredIDs:Set<String>=[]
    private var reconciliationAudit=SourceReconciliationAudit()
    private var epoch = 0
    private let owner=UUID()
    private var confirmedSourceEpoch:Int?
    private let file: URL
    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard [1,2].contains(decoded.schema),decoded.schema==2 || decoded.memories.allSatisfy({$0.visualReading==nil}) else { throw PinStoreError.unsupportedSchema }
            for memory in decoded.memories {try memory.visualReading?.validate(for:memory)}
            for (id,value) in decoded.savedInterpretations ?? [:] {
                let corrections = value.placeCorrections ?? []
                let plans = value.planCorrections ?? []
                guard id==value.source.id,value.recordRevision>0,
                      let memory=decoded.memories.first(where:{$0.id==id}),value.source.matches(memory),
                      value.recordRevision>=memory.revision,
                      value.correction.map({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.utf8.count<=12_000}) ?? true,
                      corrections.allSatisfy(\.isValid),
                      plans.allSatisfy({ $0.isValid && !$0.additionalSources.contains(where: { $0.id == id }) }),
                      Dictionary(grouping: plans, by: \.person).values.allSatisfy({
                          $0.count == Set($0.map(\.field)).count
                      }),
                      Dictionary(grouping: corrections, by: \.mentionID).values.allSatisfy({
                          $0.count == Set($0.map(\.field)).count
                      })
                else{throw PinStoreError.staleResult}
            }
            state = decoded
            #if os(iOS)
            // Validate before changing protection; never rewrite or reset old bytes.
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            #endif
        } else { state = State() }
    }
    private func commit(_ next: State) throws {
        var next=next
        for memory in next.memories {try memory.visualReading?.validate(for:memory)}
        if next.memories.contains(where:{$0.visualReading != nil}){next.schema=2}
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: [.atomic])
        #endif
        state = next
    }
    public func synchronizeAccess(_ ids: Set<String>, restartingImport: Bool = false) throws -> ImportPermit {
        // Access withdrawal remains immediate; an unchanged resume is read-only
        // and must not invalidate an indexing run already in progress.
        var next = state; next.memories.removeAll { !ids.contains($0.id) }
        next.attempts=next.attempts?.filter { ids.contains($0.key) && !next.forgotten.contains($0.key) }
        next.savedInterpretations=next.savedInterpretations?.filter {ids.contains($0.key) && !next.forgotten.contains($0.key)}
        if next.memories.count != state.memories.count {
            try retirePlanDependencies(in: &next, withdrawn: Set(state.memories.map(\.id)).subtracting(ids))
        }
        if next.memories.count != state.memories.count || next.attempts != state.attempts || next.savedInterpretations != state.savedInterpretations { try commit(next) }
        let retainedDeferrals=metadataDeferredIDs.intersection(ids)
        if ids != visibleIDs || restartingImport || retainedDeferrals != metadataDeferredIDs { epoch += 1 }
        visibleIDs = ids;metadataDeferredIDs=retainedDeferrals
        return ImportPermit(epoch: epoch,owner:owner)
    }
    /// Native PhotoKit supplies current source versions. While locked its
    /// catalogue may be partial: absence hides a source immediately but cannot
    /// authorize deletion of saved bytes. A full unlocked check confirms removals.
    public func synchronizeSources(_ fingerprints: [String:String], confirmingAccess: Bool = true, restartingImport: Bool = false) throws -> ImportPermit {
        let ids=Set(fingerprints.keys)
        let oldFingerprints=sourceFingerprints
        if confirmingAccess {
            _ = try synchronizeAccess(ids,restartingImport:restartingImport)
        } else {
            if ids != visibleIDs || restartingImport { epoch += 1 }
            visibleIDs=ids
        }
        var audit=SourceReconciliationAudit();audit.retained=state.memories.count
        let known=Dictionary(uniqueKeysWithValues:state.memories.map { ($0.id,$0.fingerprint) })
        var deferred:Set<String>=[]
        for (id,current) in fingerprints where !state.forgotten.contains(id) {
            guard let previous=known[id],previous != current else { continue }
            audit.changed += 1
            for field in SourceMetadataPolicy.changedFields(previous:previous,current:current) { audit.changedFields[field,default:0] += 1 }
            if !confirmingAccess && SourceMetadataPolicy.needsConfirmation(previous:previous,current:current) { deferred.insert(id) }
        }
        audit.metadataDeferred=deferred.count
        if oldFingerprints != fingerprints || metadataDeferredIDs != deferred { epoch += 1 }
        sourceFingerprints=fingerprints;metadataDeferredIDs=deferred;reconciliationAudit=audit
        confirmedSourceEpoch=confirmingAccess ? epoch:nil
        return ImportPermit(epoch:epoch,owner:owner)
    }
    public func sourceReconciliationAudit() -> SourceReconciliationAudit { reconciliationAudit }
    private func matchesSource(_ id:String, fingerprint:String) -> Bool {
        sourceFingerprints[id].map { $0 == fingerprint } ?? true
    }
    /// New/changed and interrupted reads remain incremental work. A durable
    /// issue for this exact source version is not a fresh read on every launch;
    /// only the corresponding explicit local retry/download action selects it.
    public func pendingSourceIDs(_ fingerprints: [String: String], retrying issues: [PhotoReadIssue] = []) -> Set<String> {
        let known = Dictionary(uniqueKeysWithValues: state.memories.map { ($0.id, $0.fingerprint) })
        return Set(fingerprints.compactMap { id, fingerprint in
            guard visibleIDs.contains(id), !state.forgotten.contains(id), known[id] != fingerprint, !metadataDeferredIDs.contains(id), matchesSource(id,fingerprint:fingerprint) else { return nil }
            if let previous = state.attempts?[id], previous.fingerprint == fingerprint,
               !issues.contains(previous.issue) { return nil }
            return id
        })
    }
    /// Only current unread sources already classified as cloud-only may use
    /// PhotoKit network access after an explicit foreground user action.
    public func sourcesNeedingDownload(_ fingerprints: [String: String]) -> Set<String> {
        let pending = pendingSourceIDs(fingerprints, retrying: [.needsDownload])
        return Set(pending.filter { id in
            guard let attempt = state.attempts?[id], let fingerprint = fingerprints[id] else { return false }
            return attempt.fingerprint == fingerprint && attempt.issue == .needsDownload
        })
    }
    public func upsert(_ memory: PhotoMemory, permit: ImportPermit) throws {
        // Visual provenance enters only through the image-bound native CAS.
        guard memory.visualReading==nil else{throw PinStoreError.staleImport}
        guard permit.epoch == epoch, visibleIDs.contains(memory.id), !state.forgotten.contains(memory.id), !metadataDeferredIDs.contains(memory.id), matchesSource(memory.id,fingerprint:memory.fingerprint) else { throw PinStoreError.staleImport }
        var next = state
        next.attempts?.removeValue(forKey:memory.id)
        if let index = next.memories.firstIndex(where: { $0.id == memory.id }) {
            guard next.memories[index].fingerprint != memory.fingerprint else { return }
            guard next.memories[index].revision<Int.max else{throw PinStoreError.staleImport}
            var updated = memory; updated.revision = next.memories[index].revision + 1
            try retireSavedInterpretation(in:&next,for:updated)
            next.memories[index] = updated
        } else { next.memories.append(memory) }
        try commit(next)
    }
    /// Explicitly separate from ordinary same-fingerprint import. Native
    /// acquisition must independently check foreground/access/request and
    /// bind immutable bytes before supplying any reader observations.
    public func prepareTextReread(_ source:EvidenceSource,permit:ImportPermit)throws->PhotoTextRereadTicket {
        try Task.checkCancellation()
        guard permit.owner==owner,permit.epoch==epoch,confirmedSourceEpoch==epoch,
              visibleIDs.contains(source.id),!state.forgotten.contains(source.id),!metadataDeferredIDs.contains(source.id),
              sourceFingerprints[source.id]==source.fingerprint,
              let previous=state.memories.first(where:{$0.id==source.id}),source.matches(previous) else{throw PinStoreError.staleImport}
        return PhotoTextRereadTicket(source:source,owner:owner,epoch:epoch,previous:previous,
                                    previousInterpretation:state.savedInterpretations?[source.id])
    }
    /// Whole text-observation replacement, never a patch to interpreted
    /// appointment fields. Photo identity/metadata and other observations are
    /// preserved. Changed text advances native revision and invalidates old
    /// source-bound facts; canonical recompilation and a fresh query follow.
    @discardableResult public func commitTextReread(_ lines:[CardLine],ticket:PhotoTextRereadTicket)throws->PhotoMemory {
        try commitReread(lines,visualReading:nil,ticket:ticket)
    }
    public func stageTextReread(_ lines:[CardLine],ticket:PhotoTextRereadTicket)throws->PreparedPhotoReread {
        let after=try rereadCandidate(lines,visualReading:nil,ticket:ticket)
        return PreparedPhotoReread(before:ticket.previous,after:after,ticket:ticket)
    }
    public func stageVisualReread(_ reading:PhotoVisualReading,ticket:PhotoTextRereadTicket)throws->PreparedPhotoReread {
        guard reading.sourceBeforeRead==ticket.source else{throw PinStoreError.staleImport}
        let after=try rereadCandidate(reading.textLines(),visualReading:reading,ticket:ticket)
        try reading.validate(for:after)
        return PreparedPhotoReread(before:ticket.previous,after:after,ticket:ticket)
    }
    @discardableResult public func commitPreparedReread(_ prepared:PreparedPhotoReread)throws->PhotoMemory {
        if let visual=prepared.after.visualReading {
            guard visual.sourceBeforeRead==prepared.ticket.source else{throw PinStoreError.staleImport}
            try visual.validate(for:prepared.after)
        }
        let candidate=try rereadCandidate(prepared.after.textEvidence ?? [],visualReading:prepared.after.visualReading,ticket:prepared.ticket)
        guard prepared.before==prepared.ticket.previous,candidate==prepared.after else{throw PinStoreError.staleImport}
        return try commitReread(prepared.after.textEvidence ?? [],visualReading:prepared.after.visualReading,ticket:prepared.ticket)
    }
    @discardableResult public func commitVisualReread(_ reading:PhotoVisualReading,ticket:PhotoTextRereadTicket)throws->PhotoMemory {
        guard reading.sourceBeforeRead==ticket.source else{throw PinStoreError.staleImport}
        return try commitReread(reading.textLines(),visualReading:reading,ticket:ticket)
    }
    private func commitReread(_ lines:[CardLine],visualReading:PhotoVisualReading?,ticket:PhotoTextRereadTicket)throws->PhotoMemory {
        let updated=try rereadCandidate(lines,visualReading:visualReading,ticket:ticket)
        guard updated != ticket.previous else{return ticket.previous}
        guard let index=state.memories.firstIndex(where:{$0.id==ticket.source.id})else{throw PinStoreError.staleImport}
        var next=state;next.memories[index]=updated;next.attempts?.removeValue(forKey:updated.id)
        try retireSavedInterpretation(in:&next,for:updated)
        try commit(next)
        return updated
    }
    private func rereadCandidate(_ lines:[CardLine],visualReading:PhotoVisualReading?,ticket:PhotoTextRereadTicket)throws->PhotoMemory {
        try Task.checkCancellation()
        guard ticket.owner==owner,ticket.epoch==epoch,confirmedSourceEpoch==epoch,
              visibleIDs.contains(ticket.source.id),!state.forgotten.contains(ticket.source.id),!metadataDeferredIDs.contains(ticket.source.id),
              sourceFingerprints[ticket.source.id]==ticket.source.fingerprint,
              state.savedInterpretations?[ticket.source.id]==ticket.previousInterpretation,
              let index=state.memories.firstIndex(where:{$0.id==ticket.source.id}),state.memories[index]==ticket.previous else{throw PinStoreError.staleImport}
        guard lines.count<=4096,lines.reduce(0,{$0+$1.text.utf8.count})<=1_048_576,
              lines.allSatisfy({line in
                  guard line.confidence.isFinite,(0...1).contains(line.confidence) else{return false}
                  return line.region?.isValid ?? true
              }) else{throw PinStoreError.staleImport}
        var updated=ticket.previous
        updated.text=lines.map(\.text);updated.textEvidence=lines;updated.visualReading=visualReading
        if updated==ticket.previous{return ticket.previous}
        guard updated.revision<Int.max else{throw PinStoreError.staleImport}
        updated.revision += 1
        return updated
    }
    public func recordReadIssue(id:String, fingerprint:String, issue:PhotoReadIssue, permit:ImportPermit) throws {
        guard permit.epoch == epoch, visibleIDs.contains(id), !state.forgotten.contains(id), !metadataDeferredIDs.contains(id), matchesSource(id,fingerprint:fingerprint) else { throw PinStoreError.staleImport }
        guard !state.memories.contains(where:{ $0.id == id && $0.fingerprint == fingerprint }) else { return }
        let attempt=PhotoReadAttempt(fingerprint:fingerprint,issue:issue)
        guard state.attempts?[id] != attempt else { return }
        var next=state
        if next.attempts == nil { next.attempts=[:] }
        next.attempts?[id]=attempt
        try commit(next)
    }
    public func readSummary(_ fingerprints:[String:String]) -> PhotoReadSummary {
        let known=Dictionary(uniqueKeysWithValues:state.memories.map { ($0.id,$0) })
        var result=PhotoReadSummary()
        for (id,fingerprint) in fingerprints where visibleIDs.contains(id) && !state.forgotten.contains(id) && matchesSource(id,fingerprint:fingerprint) {
            result.total += 1
            if metadataDeferredIDs.contains(id) {
                result.unread += 1;result.sourceMetadataPending += 1;continue
            }
            if let memory=known[id],memory.fingerprint == fingerprint {
                result.read += 1
                if memory.text.isEmpty && !memory.labels.contains(where:{ $0.confidence >= 0.35 }) { result.withoutUsableDetails += 1 }
                if memory.imageRecognitionAvailable == false { result.partialRecognition += 1 }
            } else if let attempt=state.attempts?[id],attempt.fingerprint == fingerprint {
                switch attempt.issue {
                case .needsDownload: result.needsDownload += 1
                case .photoUnavailable: result.unavailable += 1
                case .analysisFailed: result.failed += 1
                }
            } else { result.unread += 1 }
        }
        return result
    }
    public func all() -> [PhotoMemory] {
        state.memories.filter { visibleIDs.contains($0.id) && !state.forgotten.contains($0.id) && matchesSource($0.id,fingerprint:$0.fingerprint) }.sorted { ($0.photographedAt ?? .distantPast) > ($1.photographedAt ?? .distantPast) }
    }
    public func validatedHits(_ hits:[RecallHit]) -> [RecallHit] {
        let known=Dictionary(uniqueKeysWithValues:state.memories.map { ($0.id,$0) })
        return hits.filter { hit in
            visibleIDs.contains(hit.id) && !state.forgotten.contains(hit.id)
                && matchesSource(hit.id,fingerprint:hit.memory.fingerprint)
                && known[hit.id]?.revision == hit.memory.revision && known[hit.id]?.fingerprint == hit.memory.fingerprint
        }
    }
    public func current(_ hit: RecallHit) throws -> PhotoMemory {
        guard visibleIDs.contains(hit.id), !state.forgotten.contains(hit.id), matchesSource(hit.id,fingerprint:hit.memory.fingerprint),
              let memory = state.memories.first(where: { $0.id == hit.id }), memory.revision == hit.memory.revision, memory.fingerprint == hit.memory.fingerprint else { throw PinStoreError.staleResult }
        return memory
    }
    public func find(_ question: String, now: Date = Date()) -> [RecallHit] { LocalRecall.find(question, in: all(), now: now) }
    /// Validate and withdraw the exact displayed revision in one actor operation.
    public func forget(_ hit: RecallHit) throws {
        _ = try current(hit)
        try forget(hit.id)
    }
    public func forget(_ id: String) throws {
        var next = state; next.memories.removeAll { $0.id == id }; next.forgotten.insert(id); next.attempts?.removeValue(forKey:id);next.savedInterpretations?.removeValue(forKey:id)
        try retirePlanDependencies(in: &next, withdrawn: [id])
        try commit(next)
        // Late asynchronous analysis cannot resurrect a forgotten observation.
        epoch += 1
    }
    /// The complete current correction set is read from this same native store.
    /// A partial/locked catalogue hides entries without erasing retained bytes.
    public func savedPhotoInterpretations() -> [SavedPhotoInterpretation] {
        let current=Dictionary(uniqueKeysWithValues:all().map{($0.id,EvidenceSource($0))})
        return (state.savedInterpretations ?? [:]).values.filter{current[$0.source.id]==$0.source}
            .sorted{$0.source.id<$1.source.id}
    }
    /// Compare the exact source and prior correction before committing. Two
    /// editors cannot silently overwrite one another, even with the same photo.
    @discardableResult public func savePhotoInterpretation(source:EvidenceSource,correction:String?,expected:SavedPhotoInterpretation?)throws->SavedPhotoInterpretation? {
        try validateInterpretationEdit(source: source, expected: expected)
        let text=correction?.trimmingCharacters(in:.whitespacesAndNewlines)
        let value=text?.isEmpty == false ? text:nil
        guard value.map({$0.utf8.count<=12_000}) ?? true else{throw PinStoreError.staleResult}
        if expected?.correction==value{return expected}
        return try commitInterpretation(source: source, value: value, placeCorrections: expected?.placeCorrections, planCorrections: expected?.planCorrections, expected: expected)
    }

    @discardableResult public func savePlaceDetail(
        source: EvidenceSource, mentionID: String, field: SavedPlaceDetailCorrection.Field,
        value: String?, expected: SavedPhotoInterpretation?
    ) throws -> SavedPhotoInterpretation? {
        try validateInterpretationEdit(source: source, expected: expected)
        guard !mentionID.isEmpty, mentionID.utf8.count <= 1024 else { throw PinStoreError.staleResult }
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = expected?.placeCorrections ?? []
        let existing = previous.first { $0.mentionID == mentionID && $0.field == field }
        if (existing?.value ?? "") == text { return expected }
        var updated = previous.filter { $0.mentionID != mentionID || $0.field != field }
        if !text.isEmpty {
            let edit = SavedPlaceDetailCorrection(mentionID: mentionID, field: field, value: text)
            guard edit.isValid else { throw PinStoreError.staleResult }
            updated.append(edit)
        }
        updated.sort { ($0.mentionID, $0.field.rawValue) < ($1.mentionID, $1.field.rawValue) }
        return try commitInterpretation(source: source, value: expected?.correction,
                                        placeCorrections: updated.isEmpty ? nil : updated,
                                        planCorrections: expected?.planCorrections, expected: expected)
    }

    @discardableResult public func savePlanDetail(
        source: EvidenceSource, person: String, field: SavedPlanDetailCorrection.Field,
        value: String?, additionalSources: Set<EvidenceSource>, expected: SavedPhotoInterpretation?
    ) throws -> SavedPhotoInterpretation? {
        try validateInterpretationEdit(source: source, expected: expected)
        let person = SavedPlanDetailCorrection.personKey(person)
        guard !person.isEmpty, person.utf8.count <= 320,
              additionalSources.allSatisfy({ dependency in
                  dependency.id != source.id && visibleIDs.contains(dependency.id) &&
                  !state.forgotten.contains(dependency.id) && !metadataDeferredIDs.contains(dependency.id) &&
                  sourceFingerprints[dependency.id] == dependency.fingerprint &&
                  state.memories.contains(where: dependency.matches)
              }) else { throw PinStoreError.staleResult }
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = expected?.planCorrections ?? []
        var updated = previous.filter { $0.person != person || $0.field != field }
        if !text.isEmpty {
            let edit = SavedPlanDetailCorrection(person: person, field: field, value: text,
                                                 additionalSources: additionalSources)
            guard edit.isValid else { throw PinStoreError.staleResult }
            updated.append(edit)
        }
        updated.sort { ($0.person, $0.field.rawValue) < ($1.person, $1.field.rawValue) }
        if updated == previous { return expected }
        return try commitInterpretation(source: source, value: expected?.correction,
                                        placeCorrections: expected?.placeCorrections,
                                        planCorrections: updated.isEmpty ? nil : updated, expected: expected)
    }

    private func validateInterpretationEdit(source: EvidenceSource, expected: SavedPhotoInterpretation?) throws {
        try Task.checkCancellation()
        guard confirmedSourceEpoch==epoch,visibleIDs.contains(source.id),!state.forgotten.contains(source.id),
              !metadataDeferredIDs.contains(source.id),sourceFingerprints[source.id]==source.fingerprint,
              let memory=state.memories.first(where:{$0.id==source.id}),source.matches(memory),
              memory.text.contains(where:{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}),
              state.savedInterpretations?[source.id]==expected else{throw PinStoreError.staleResult}
    }

    private func commitInterpretation(source: EvidenceSource, value: String?,
                                      placeCorrections: [SavedPlaceDetailCorrection]?,
                                      planCorrections: [SavedPlanDetailCorrection]?,
                                      expected: SavedPhotoInterpretation?) throws -> SavedPhotoInterpretation {
        let previous=max(source.revision,expected?.recordRevision ?? 0)
        guard previous<Int.max else{throw PinStoreError.staleResult}
        let updated=SavedPhotoInterpretation(source:source,recordRevision:previous+1,correction:value,
                                             placeCorrections:placeCorrections,planCorrections:planCorrections)
        var next=state
        if next.savedInterpretations==nil{next.savedInterpretations=[:]}
        next.savedInterpretations?[source.id]=updated
        try commit(next)
        return updated
    }
    private func retireSavedInterpretation(in next:inout State,for memory:PhotoMemory)throws {
        try retirePlanDependencies(in: &next, withdrawn: [memory.id])
        guard let previous=next.savedInterpretations?[memory.id] else{return}
        guard previous.recordRevision<Int.max else{throw PinStoreError.staleImport}
        next.savedInterpretations?[memory.id]=SavedPhotoInterpretation(source:EvidenceSource(memory),recordRevision:max(previous.recordRevision+1,memory.revision),correction:nil)
    }
    private func retirePlanDependencies(in next: inout State, withdrawn: Set<String>) throws {
        for (id, entry) in next.savedInterpretations ?? [:] {
            guard let edits = entry.planCorrections else { continue }
            let remaining = edits.filter { edit in
                !edit.additionalSources.contains { withdrawn.contains($0.id) }
            }
            guard remaining.count != edits.count else { continue }
            guard entry.recordRevision < Int.max else { throw PinStoreError.staleResult }
            next.savedInterpretations?[id] = SavedPhotoInterpretation(
                source: entry.source, recordRevision: entry.recordRevision + 1, correction: entry.correction,
                placeCorrections: entry.placeCorrections, planCorrections: remaining.isEmpty ? nil : remaining
            )
        }
    }

    public func fingerprint(for id: String) -> String? {
        guard visibleIDs.contains(id), !state.forgotten.contains(id) else { return nil }
        return state.memories.first(where: { $0.id == id && matchesSource(id,fingerprint:$0.fingerprint) })?.fingerprint
    }
    public func isForgotten(_ id: String) -> Bool { state.forgotten.contains(id) }
}

/// Remote providers may suggest candidates; native source/access checks remain
/// authoritative. Deliberately no API keys, URLs or live provider calls here.
public protocol PhotoDecisionProvider: Sendable {
    func classify(observation: PhotoMemory) async throws -> [VisualLabel]
}
public protocol MemoryRetriever: Sendable {
    func candidates(question: String, allowed: [PhotoMemory]) async throws -> [RecallHit]
}
