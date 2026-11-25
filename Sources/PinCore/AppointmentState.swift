import Foundation
import CryptoKit

public struct AppointmentSource: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let fingerprint: String
    public let revision: Int
    public init(_ memory: PhotoMemory) { id = memory.id; fingerprint = memory.fingerprint; revision = memory.revision }
    public init(_ source: EvidenceSource) { id=source.id;fingerprint=source.fingerprint;revision=source.revision }
}
public struct AppointmentItem: Codable, Equatable, Identifiable, Sendable {
    /// Legacy cards retain their source ID. Multi-event documents retain a
    /// printed reference or an explicitly opted-in exact-source anchor identity.
    public var id: String { canonicalRecordID ?? eventID.map { "event.\(source.id.utf8.count).\(source.id).\($0)" } ?? source.id }
    public var sourceID: String { source.id }
    public var canonicalRecordID: String?
    public var canonicalRevision: Int?
    public var additionalSources: [AppointmentSource]?
    public var semanticSupport: [AppointmentSemanticField]?
    public var previousEvidence: AppointmentPreviousEvidence?
    public var bookingLinkEvidence:AppointmentBookingLinkEvidence?
    public var allSources: [AppointmentSource] { [source] + (additionalSources ?? []) }
    public var source: AppointmentSource
    public var eventID: String?
    public var observation: AppointmentObservation
    public var dismissed = false
    public var remindersApproved = false
    public var readerVersion = AppointmentCardReader.version
    public init(source: AppointmentSource, observation: AppointmentObservation, eventID: String? = nil) {
        self.source = source; self.observation = observation; self.eventID = eventID
    }
    /// Reminder approval is mutable action state, not a change to evidence.
    /// Callers must still check current visibility/dismissal before rebinding.
    public func hasSameEvidence(as other: AppointmentItem) -> Bool {
        id == other.id && source == other.source && additionalSources == other.additionalSources && observation == other.observation && semanticSupport == other.semanticSupport && readerVersion == other.readerVersion && bookingLinkEvidence == other.bookingLinkEvidence
    }

}
/// A newly recognized non-holder source may have a row from an older rule
/// pass. Cleanup must never act on another revision or a semantic row.
public enum AppointmentRuleReconciliation {
    public static func shouldWithdraw(_ item: AppointmentItem, current: PhotoMemory?) -> Bool {
        guard let current else { return false }
        return item.observation.semanticVersion == nil &&
            item.source == AppointmentSource(current) &&
            AppointmentCardReader.sourceDisposition(current.text) != .notExcluded
    }
}
/// Source-bound negative meaning in the existing native domain file. Exact
/// observation IDs include text, order, confidence and regions. This is not an
/// appointment or a claim that the owner has no events.
public struct AppointmentSourceRejection:Codable,Equatable,Sendable {
    public static let readerVersion="pin-ibrain-source-rejection-v1"
    public let source:AppointmentSource
    public let observationIDs:[String]
    public let taskSHA256:String
    public let version:String
    public init(source:AppointmentSource,observationIDs:[String],taskSHA256:String){self.source=source;self.observationIDs=observationIDs;self.taskSHA256=taskSHA256;version=Self.readerVersion}
}
public struct AppointmentPermit: Sendable { fileprivate let epoch: Int }
public struct AppointmentReminder: Equatable, Sendable {
    public var key: String
    public var date: Date
    public var timeZoneID: String
}
public enum AppointmentReminderPlanner {
    public static func plan(_ item: AppointmentItem, now: Date) -> [AppointmentReminder] {
        guard item.remindersApproved, !item.dismissed, item.observation.cancelled != true, item.observation.reviewReason == nil,
              let date = item.observation.date, date > now,
              let zone = TimeZone(identifier: item.observation.timeZoneID) else { return [] }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let day = cal.startOfDay(for: date)
        let prior = cal.date(byAdding: .day, value: -1, to: day)!
        let before = cal.date(bySettingHour: 9, minute: 0, second: 0, of: prior)!
        let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
        var dates = [("before", before), ("day", morning)]
        if !dates.contains(where: { $0.1 > now && $0.1 < date }) { dates = [("hour", date.addingTimeInterval(-3600))] }
        return dates.filter { $0.1 > now && $0.1 < date }.map { AppointmentReminder(key: $0.0, date: $0.1, timeZoneID: zone.identifier) }
    }
}
public struct CanonicalWriteTicket: Sendable {
    fileprivate let session:UUID
    public let id:String
    public var nextRevision:Int{(expectedRevision ?? 0)+1}
    fileprivate let expectedRevision:Int?
    fileprivate let previous:AppointmentItem?
    fileprivate var initialReadID:UUID?=nil
}
/// Native work identity only; no semantic facts or transport authority.
public struct AppointmentInitialReadTicket:Sendable {
    public let id:UUID
    public let resumed:Bool
    fileprivate let owner:UUID
    fileprivate let epoch:Int
}
public enum AppointmentGroupReplacementPhase:String,Codable,Sendable {case sourcePrepared,sourceAdvanced,readyToCommit,completed,invalidated}
public struct AppointmentGroupReplacementTicket:Sendable {
    public let id:UUID
    fileprivate let owner:UUID
    fileprivate let epoch:Int
}
public struct AppointmentGroupReplacementStatus:Sendable {
    public let id:UUID
    public let phase:AppointmentGroupReplacementPhase
    public let sourceBefore:AppointmentSource
    public let sourceAfter:AppointmentSource
    public let retainedRecordIDs:[String]
    public let allocatedRecordIDs:[String]
}
/// Separate, version-bound appointment state; the existing photo index stays unchanged.
public enum AppointmentTemporalAdmissionPolicy:Sendable {case screenshotOnly,labelledOriginalCaptureV1}
public actor AppointmentStore {
    private struct GroupReplacement:Codable,Equatable {
        let id:UUID;let before:AppointmentSource;let after:AppointmentSource
        let beforeMemorySHA256:String;let afterMemorySHA256:String
        var phase:AppointmentGroupReplacementPhase
        var previous:[AppointmentItem]
        var childIDs:[String]=[]
        var groupingTaskSHA256:String?
        var staged:[AppointmentItem]=[]
    }
    private struct InitialChild:Codable,Equatable {
        let assessmentSHA256:String;let ordinal:Int;let recordID:String
    }
    private struct InitialRead:Codable,Equatable {
        let id:UUID;let source:AppointmentSource;let memorySHA256:String
        let originalSHA256:String;let contractSHA256:String
        var children:[InitialChild]=[];var completed=false
    }
    private struct State: Codable { var schema = 2; var items: [AppointmentItem] = []; var canonicalRevisions:[String:Int]?; var canonicalSourceCoverage:[AppointmentSource]?; var sourceRejections:[AppointmentSourceRejection]?;var pendingSemanticSources:[AppointmentSource]?;var retiredCanonicalSourceSHA256:[String]?;var groupReplacements:[GroupReplacement]?;var retiredCanonicalRecordIDs:[String]?;var groupReplacementRetirementSHA256:[String]?;var ownerCorrections:[AppointmentOwnerCorrectionTransition]?;var initialReads:[InitialRead]? }
    private let file: URL
    private let temporalAdmissionPolicy:AppointmentTemporalAdmissionPolicy
    private let canonicalSession=UUID()
    private var state: State
    private var visible: [String: AppointmentSource] = [:]
    private var currentObservations:[String:[CardLine]] = [:]
    private var currentVisualSupport:[String:[VisualFactSupport]] = [:]
    private var currentCaptureDates:[String:Date] = [:]
    private var currentScreenshotKinds:[String:Bool] = [:]
    private var currentMemories:[String:PhotoMemory]=[:]
    private var epoch = 0
    public init(file: URL,temporalAdmissionPolicy:AppointmentTemporalAdmissionPolicy = .screenshotOnly) throws {
        self.temporalAdmissionPolicy=temporalAdmissionPolicy
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard (1...9).contains(decoded.schema),(decoded.groupReplacements==nil && decoded.retiredCanonicalRecordIDs==nil && decoded.groupReplacementRetirementSHA256==nil) || decoded.schema>=7 else { throw PinStoreError.unsupportedSchema }
            guard decoded.ownerCorrections==nil || decoded.schema>=8,
                  Self.validOwnerCorrectionHistory(decoded.ownerCorrections ?? []) else{throw PinStoreError.unsupportedSchema}
            let reads=decoded.initialReads ?? []
            let childIDs=reads.flatMap{$0.children.map(\.recordID)}
            guard decoded.initialReads==nil || decoded.schema>=9,
                  Set(reads.map(\.id)).count==reads.count,Set(reads.map{$0.source.id}).count==reads.count,
                  Set(childIDs).count==childIDs.count,
                  reads.allSatisfy({read in
                    read.source.revision>0 && !read.source.id.isEmpty &&
                    [read.memorySHA256,read.originalSHA256,read.contractSHA256].allSatisfy(Self.validDigest) &&
                    read.children.count<=3 && Set(read.children.map(\.ordinal)).count==read.children.count &&
                    read.children.allSatisfy{(1...3).contains($0.ordinal) && Self.validDigest($0.assessmentSHA256) && $0.recordID.hasPrefix("pin.record.")}
                  })else{throw PinStoreError.unsupportedSchema}
            let retirements=decoded.groupReplacementRetirementSHA256 ?? []
            guard Set(retirements).count==retirements.count,retirements.allSatisfy(Self.validDigest)else{throw PinStoreError.unsupportedSchema}
            let retiredIDs=decoded.retiredCanonicalRecordIDs ?? []
            guard Set(retiredIDs).count==retiredIDs.count,retiredIDs.allSatisfy({!$0.isEmpty}),!decoded.items.contains(where:{retiredIDs.contains($0.id)})else{throw PinStoreError.unsupportedSchema}
            let groups=decoded.groupReplacements ?? []
            guard Set(groups.map(\.id)).count==groups.count,Set(groups.map{ $0.before.id }).count==groups.count,
                  groups.allSatisfy({g in
                    g.before.id==g.after.id && g.before.fingerprint==g.after.fingerprint && g.before.revision>0 && g.before.revision<Int.max && g.after.revision==g.before.revision+1 &&
                    [g.beforeMemorySHA256,g.afterMemorySHA256].allSatisfy(Self.validDigest) &&
                    Set(g.childIDs).count==g.childIDs.count && g.childIDs.count<=3 &&
                    (g.groupingTaskSHA256.map(Self.validDigest) ?? g.childIDs.isEmpty) &&
                    (g.phase == .completed ? g.previous.isEmpty && g.staged.isEmpty && !g.childIDs.isEmpty : (1...3).contains(g.previous.count)) &&
                    (g.phase == .sourcePrepared ? g.childIDs.isEmpty && g.staged.isEmpty : true) &&
                    (g.phase == .sourceAdvanced ? g.staged.isEmpty : true) &&
                    (g.phase == .readyToCommit ? !g.childIDs.isEmpty && g.staged.map(\.id)==g.childIDs : true) &&
                    Set(g.previous.map(\.id)).count==g.previous.count &&
                    g.previous.allSatisfy({old in old.canonicalRecordID != nil && old.canonicalRevision==decoded.canonicalRevisions?[old.id] && old.allSources==[g.before] && !decoded.items.contains(where:{$0.id==old.id}) })
                  })else{throw PinStoreError.unsupportedSchema}
            let retired=decoded.retiredCanonicalSourceSHA256 ?? []
            guard Set(retired).count==retired.count,retired.allSatisfy({$0.count==64 && $0.allSatisfy({"0123456789abcdef".contains($0)})})else{throw PinStoreError.unsupportedSchema}
            let temporal=decoded.items.flatMap{[$0.observation.components,$0.previousEvidence?.observation.components].compactMap{$0}}.filter{$0.temporalDerivation != nil}
            guard temporal.isEmpty || decoded.schema>=5,temporal.allSatisfy(\.isValid)else{throw PinStoreError.unsupportedSchema}
            let visual=Self.visualFacts(decoded)
            guard visual.isEmpty || decoded.schema>=6,visual.allSatisfy(\.isValid)else{throw PinStoreError.unsupportedSchema}
            state = decoded
            state.schema = max(decoded.schema,2)
        } else { state = State() }
    }
    /// Retirement is an admission fence, not an event fact. Retain only an
    /// opaque version digest when access withdrawal purges the source metadata.
    private static func retiredDigest(_ source:AppointmentSource)->String {
        let value="pin-retired-canonical-source-v1|"+String(source.id.utf8.count)+":"+source.id+"|"+String(source.fingerprint.utf8.count)+":"+source.fingerprint+"|"+String(source.revision)
        return SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()
    }
    private static func retiredBindings(_ state:State)->Set<AppointmentSource> {
        let active=Set(state.items.flatMap(\.allSources)),pending=Set(state.pendingSemanticSources ?? [])
        return Set(state.canonicalSourceCoverage ?? []).subtracting(active).subtracting(pending)
    }
    private func isRetired(_ source:AppointmentSource)->Bool {
        Self.retiredBindings(state).contains(source) || (state.retiredCanonicalSourceSHA256 ?? []).contains(Self.retiredDigest(source))
    }
    private static func validDigest(_ value:String)->Bool{value.count==64 && value.allSatisfy{"0123456789abcdef".contains($0)}}
    private func hasPendingGroup(_ sourceID:String)->Bool{(state.groupReplacements ?? []).contains{$0.before.id==sourceID && $0.phase != .completed}}
    private static func memoryDigest(_ memory:PhotoMemory)throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return SHA256.hash(data:try encoder.encode(memory)).map{String(format:"%02x",$0)}.joined()
    }
    private static func visualFacts(_ state:State)->[VisualFactSupport] {
        state.items.flatMap { item in
            ((item.observation.fieldFacts ?? [])+(item.previousEvidence?.observation.fieldFacts ?? [])).flatMap{$0.visualSupport ?? []}
        }
    }
    private func save(_ proposed: State) throws {
        var next=proposed
        if let history=next.ownerCorrections {
            // Forget/access withdrawal removes the retained derived edit values
            // in the SAME atomic native save; tombstones remain separate.
            let current=next.items.filter{!$0.dismissed}
            next.ownerCorrections=history.filter{step in current.first(where:{$0.id==step.after.id}).map{$0.allSources==step.after.allSources} ?? false}
        }
        guard Self.validOwnerCorrectionHistory(next.ownerCorrections ?? [])else{throw PinStoreError.staleImport}
        if next.initialReads != nil || state.schema>=9{next.schema=max(next.schema,9)}
        if next.ownerCorrections != nil || state.schema>=8{next.schema=max(next.schema,8)}
        if next.groupReplacements != nil || next.retiredCanonicalRecordIDs != nil || next.groupReplacementRetirementSHA256 != nil || state.schema>=7{next.schema=max(next.schema,7)}
        // Native schema4 already protects retirement. Temporal proof requires
        // schema5 so an older native reader cannot silently discard the proof.
        let hasTemporal=next.items.contains{$0.observation.components?.temporalDerivation != nil || $0.previousEvidence?.observation.components?.temporalDerivation != nil}
        if hasTemporal || state.schema>=5{next.schema=max(next.schema,5)}
        if !Self.visualFacts(next).isEmpty || state.schema>=6{next.schema=max(next.schema,6)}
        let retired=Set((state.retiredCanonicalSourceSHA256 ?? [])+(next.retiredCanonicalSourceSHA256 ?? [])).union(Self.retiredBindings(state).map(Self.retiredDigest)).union(Self.retiredBindings(next).map(Self.retiredDigest))
        if !retired.isEmpty{next.retiredCanonicalSourceSHA256=retired.sorted();next.schema=max(next.schema,4)}
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        #endif
        state = next
    }
    private static func currentLink(_ link:AppointmentBookingLinkEvidence,sources:[String:AppointmentSource],observations:[String:[CardLine]])->Bool {
        guard link.version==AppointmentBookingLinkEvidence.contractVersion,(2...3).contains(link.identities.count),
              link.taskSHA256.count==64,link.taskSHA256.allSatisfy({$0.isHexDigit}),
              Set(link.identities.map{$0.issuer.source.id}).count==link.identities.count else{return false}
        func exact(_ a:AppointmentSemanticAnchor)->Bool {
            guard sources[a.source.id]==AppointmentSource(a.source),let lines=observations[a.source.id] else{return false}
            return lines.indices.contains{offset in (try? PinOCRObservationID.make(lines[offset],offset:offset))==a.observationID && lines[offset].text==a.quote}
        }
        func normalized(_ s:String)->String{s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator:" ")}
        guard link.identities.allSatisfy({$0.issuer.source==$0.reference.source && $0.issuer.observationID != $0.reference.observationID && !$0.issuer.quote.isEmpty && !$0.reference.quote.isEmpty && exact($0.issuer) && exact($0.reference)}),
              Set(link.identities.map{normalized($0.issuer.quote)}).count==1,Set(link.identities.map{$0.reference.quote}).count==1 else{return false}
        return true
    }
    private static func currentDateBasis(_ observation:AppointmentObservation,sources:[AppointmentSource],fields:[AppointmentSemanticField]?,visible:[String:AppointmentSource],captures:[String:Date],screenshots:[String:Bool],allowOriginalPhoto:Bool=false)->Bool {
        guard let date=observation.components else{return true}
        if let basis=date.temporalDerivation {
            guard date.isValid,observation.reviewReason==basis.disclosure,
                  sources.contains(AppointmentSource(basis.source)),visible[basis.source.id]==AppointmentSource(basis.source),
                  captures[basis.source.id]==basis.originalCapturedAt,let screenshot=screenshots[basis.source.id],
                  basis.captureOrigin==(screenshot ? "originalScreenshot":"originalPhoto"),
                  let field=fields?.first(where:{$0.field=="date"}),field.origin=="inferred",field.anchors.contains(basis.dateAnchor)else{return false}
            // Current PhotoKit metadata has no independent attestation that
            // relative wording was contemporaneous. Retain only labelled
            // assumed context; never upgrade it to calendar/action authority.
            if basis.rule=="explicitRelativeDayFromOriginalCapture"{return basis.strength=="assumedContext"}
            // The default policy remains screenshots. Explicit isolated native qualification may retain a labelled original-photo basis; all current metadata/proof and reminder restrictions still apply.
            return (screenshot || allowOriginalPhoto) && basis.rule=="nearestPrintedMonthDayToOriginalCapture"
        }
        if let basis=date.captureYearDerivation {
            return captures[basis.source.id]==basis.originalCapturedAt && sources.contains(AppointmentSource(basis.source))
        }
        return true
    }
    public func synchronize(_ memories: [PhotoMemory]) throws -> AppointmentPermit {
        let nextVisible = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, AppointmentSource($0)) })
        let nextMemories=Dictionary(uniqueKeysWithValues:memories.map{($0.id,$0)})
        let groupSourceIDs=Set((state.groupReplacements ?? []).map{ $0.before.id }+(state.initialReads ?? []).map{$0.source.id})
        // Only active transaction sources need full-payload hashes. Do not
        // re-encode and hash the person's entire catalogue on ordinary sync.
        let nextMemoryHashes=try Dictionary(uniqueKeysWithValues:memories.filter{groupSourceIDs.contains($0.id)}.map{($0.id,try Self.memoryDigest($0))})
        let observations=Dictionary(uniqueKeysWithValues:memories.map{($0.id,$0.textEvidence ?? [])})
        var visual:[String:[VisualFactSupport]]=[:]
        for memory in memories {if let reading=memory.visualReading {try reading.validate(for:memory);visual[memory.id]=try reading.visualSupports()}}
        let captures=Dictionary(uniqueKeysWithValues:memories.compactMap{m in m.photographedAt.map{(m.id,$0)}})
        let screenshots=Dictionary(uniqueKeysWithValues:memories.compactMap{m in m.isScreenshot.map{(m.id,$0)}})
        func hasCurrentDateBasis(_ observation:AppointmentObservation,_ sources:[AppointmentSource],_ fields:[AppointmentSemanticField]?)->Bool{Self.currentDateBasis(observation,sources:sources,fields:fields,visible:nextVisible,captures:captures,screenshots:screenshots,allowOriginalPhoto:temporalAdmissionPolicy == .labelledOriginalCaptureV1)}
        func hasCurrentProof(_ fields:[AppointmentSemanticField]?)->Bool {
            guard let fields else{return false}
            return fields.allSatisfy { field in field.anchors.allSatisfy { anchor in
                guard nextVisible[anchor.source.id]==AppointmentSource(anchor.source),let lines=observations[anchor.source.id] else{return false}
                if ["kind","status"].contains(field.field),visual[anchor.source.id]?.contains(where:{$0.observationID==anchor.observationID && $0.value==anchor.quote})==true{return true}
                return lines.indices.contains { offset in
                    (try? PinOCRObservationID.make(lines[offset],offset:offset))==anchor.observationID &&
                    Data(lines[offset].text.utf8).range(of:Data(anchor.quote.utf8)) != nil
                }
            }}
        }
        func hasCurrentVisualProof(_ observation:AppointmentObservation,_ fields:[AppointmentSemanticField]?)->Bool {
            guard let fields else{return (observation.fieldFacts ?? []).allSatisfy{($0.visualSupport ?? []).isEmpty}}
            for field in fields {
                let facts=(observation.fieldFacts ?? []).filter{$0.field==(field.field=="date" ? "eventDate":field.field)}
                var expected:[EvidenceSource:[VisualFactSupport]]=[:]
                for anchor in field.anchors {
                    if let proof=visual[anchor.source.id]?.first(where:{$0.observationID==anchor.observationID && $0.value==anchor.quote}) {
                        if expected[anchor.source]?.contains(proof) != true{expected[anchor.source,default:[]].append(proof)}
                    }
                }
                for fact in facts {
                    let actual=fact.visualSupport ?? [],proof=expected.removeValue(forKey:fact.source) ?? []
                    guard actual.count==proof.count,actual.allSatisfy({proof.contains($0)}),actual.isEmpty || (["kind","status"].contains(field.field) && fact.origin == .inferred && fact.confidence==0)else{return false}
                }
                guard expected.isEmpty else{return false}
            }
            return true
        }
        var next = state
        if let reads=next.initialReads {
            next.initialReads=reads.filter{nextVisible[$0.source.id]==$0.source && nextMemoryHashes[$0.source.id]==$0.memorySHA256}
        }
        if let groups=next.groupReplacements {
            next.groupReplacements=groups.compactMap{old in
                var group=old
                guard nextVisible[group.before.id] != nil else{return nil}
                if group.phase == .completed {
                    return nextVisible[group.after.id]==group.after && nextMemoryHashes[group.after.id]==group.afterMemorySHA256 ? group:nil
                }
                if group.phase == .invalidated{return group}
                if nextVisible[group.before.id]==group.before,nextMemoryHashes[group.before.id]==group.beforeMemorySHA256,group.phase == .sourcePrepared{return group}
                guard nextVisible[group.after.id]==group.after,nextMemoryHashes[group.after.id]==group.afterMemorySHA256 else{group.phase = .invalidated;return group}
                if group.phase == .sourcePrepared{group.phase = .sourceAdvanced}
                return group
            }
        }
        next.canonicalSourceCoverage=next.canonicalSourceCoverage?.filter{nextVisible[$0.id]==$0}
        next.pendingSemanticSources=next.pendingSemanticSources?.filter{nextVisible[$0.id]==$0}
        for group in next.groupReplacements ?? [] where group.phase != .completed {
            guard let current=nextVisible[group.before.id]else{continue}
            next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? [])+[current])).sorted{$0.id<$1.id}
        }
        let changedRejections=(next.sourceRejections ?? []).filter{read in
            guard nextVisible[read.source.id]==read.source,let lines=observations[read.source.id],let ids=try? lines.enumerated().map({try PinOCRObservationID.make($0.element,offset:$0.offset)}) else{return false}
            return ids != read.observationIDs
        }
        if !changedRejections.isEmpty{next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? [])+changedRejections.map(\.source))).sorted{$0.id<$1.id}}
        next.sourceRejections=next.sourceRejections?.filter{read in
            guard nextVisible[read.source.id]==read.source,let lines=observations[read.source.id],
                  let ids=try? lines.enumerated().map({try PinOCRObservationID.make($0.element,offset:$0.offset)}) else{return false}
            return ids==read.observationIDs && read.version==AppointmentSourceRejection.readerVersion
        }
        // Withdraw invalid semantic facts, while retaining a native pending
        // fence so ordinary rules cannot silently restore the old meaning.
        let invalidCanonical=next.items.filter{$0.canonicalRecordID != nil && $0.allSources.allSatisfy{nextVisible[$0.id]==$0} && (!hasCurrentProof($0.semanticSupport) || !hasCurrentVisualProof($0.observation,$0.semanticSupport) || !hasCurrentDateBasis($0.observation,$0.allSources,$0.semanticSupport))}
        if !invalidCanonical.isEmpty {next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? [])+invalidCanonical.flatMap(\.allSources))).sorted{$0.id<$1.id}}
        next.items.removeAll { item in !item.allSources.allSatisfy { nextVisible[$0.id] == $0 } ||
            (item.canonicalRecordID != nil && (!hasCurrentProof(item.semanticSupport) || !hasCurrentVisualProof(item.observation,item.semanticSupport) || !hasCurrentDateBasis(item.observation,item.allSources,item.semanticSupport))) }
        for index in next.items.indices {
            if let link=next.items[index].bookingLinkEvidence,!Self.currentLink(link,sources:nextVisible,observations:observations){
                next.items[index].bookingLinkEvidence=nil;next.items[index].previousEvidence=nil
            }
            if let previous=next.items[index].previousEvidence,
               (!previous.sources.allSatisfy({nextVisible[$0.id]==$0}) || !hasCurrentProof(previous.semanticSupport) || !hasCurrentVisualProof(previous.observation,previous.semanticSupport) || !hasCurrentDateBasis(previous.observation,previous.sources,previous.semanticSupport)) {
                next.items[index].previousEvidence=nil
            }
        }
        if next.items != state.items || next.canonicalSourceCoverage != state.canonicalSourceCoverage || next.sourceRejections != state.sourceRejections || next.pendingSemanticSources != state.pendingSemanticSources || next.groupReplacements != state.groupReplacements || next.initialReads != state.initialReads { try save(next) }
        if nextVisible != visible || observations != currentObservations || visual != currentVisualSupport || captures != currentCaptureDates || screenshots != currentScreenshotKinds || groupSourceIDs.contains(where:{nextMemories[$0] != currentMemories[$0]}) { epoch += 1 }; visible = nextVisible
        currentObservations=Dictionary(uniqueKeysWithValues:memories.map{($0.id,$0.textEvidence ?? [])})
        currentVisualSupport=visual
        currentCaptureDates=captures;currentScreenshotKinds=screenshots
        currentMemories=nextMemories
        return AppointmentPermit(epoch: epoch)
    }
    /// Prevent an older covered source from falling back into the rule reader
    /// after its later accepted source is removed. Only current bindings persist.
    public func canonicalCoveredSources()->Set<AppointmentSource> {Set(state.canonicalSourceCoverage ?? []).union(visible.values.filter{isRetired($0)})}
    public func retainVisualReadingGap(_ memory:PhotoMemory,permit:AppointmentPermit,unpreparedGroups:Bool=false)throws {
        guard permit.epoch==epoch,visible[memory.id]==AppointmentSource(memory),let reading=memory.visualReading else{throw PinStoreError.staleImport}
        try reading.validate(for:memory)
        let receipt=try reading.validatedReceipt()
        guard receipt.coverage=="partial" || unpreparedGroups else{return}
        // Cold/group reconstruction often reasserts the same pending source.
        // Do not rewrite the canonical file when nothing changed.
        guard !(state.pendingSemanticSources ?? []).contains(AppointmentSource(memory)) else{return}
        var next=state;next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? [])+[AppointmentSource(memory)])).sorted{$0.id<$1.id}
        try save(next)
    }
    /// A source can remain incomplete after some grouped records are admitted.
    /// This conservative marker grants no facts or action authority.
    public func retainIncompleteSource(_ source:AppointmentSource,permit:AppointmentPermit)throws {
        guard permit.epoch==epoch,visible[source.id]==source,!isRetired(source) else{throw PinStoreError.staleImport}
        guard !(state.pendingSemanticSources ?? []).contains(source) else{return}
        var next=state;next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? [])+[source])).sorted{$0.id<$1.id};try save(next)
    }
    public func pendingSemanticSources()->Set<AppointmentSource>{Set(state.pendingSemanticSources ?? [])}
    /// Freeze the entire old group before the photo owner advances OCR. Old
    /// children move out of all()/reminder/original authority, but remain in the
    /// same native file until one complete replacement or a pre-change abort.
    public func beginGroupReplacement(_ prepared:PreparedPhotoReread,records:[AppointmentItem],permit:AppointmentPermit)throws->AppointmentGroupReplacementTicket {
        let before=AppointmentSource(prepared.before),after=AppointmentSource(prepared.after)
        guard permit.epoch==epoch,visible[before.id]==before,before.id==after.id,before.fingerprint==after.fingerprint,
              before.revision>0,before.revision<Int.max,after.revision==before.revision+1,
              currentMemories[before.id]==prepared.before,
              !(state.pendingSemanticSources ?? []).contains(before),!isRetired(before),
              !(state.groupReplacements ?? []).contains(where:{$0.before.id==before.id && $0.phase != .completed})else{throw PinStoreError.staleImport}
        let old=state.items.filter{$0.allSources.contains(before)}.sorted{$0.id<$1.id}
        guard (1...3).contains(old.count),old.count==records.count,old.allSatisfy(records.contains),
              Set(old.map(\.id)).count==old.count,
              old.allSatisfy({$0.canonicalRecordID != nil && $0.canonicalRevision==state.canonicalRevisions?[$0.id] &&
                  $0.allSources==[before] && $0.previousEvidence==nil && $0.bookingLinkEvidence==nil && !$0.dismissed && !$0.remindersApproved})else{throw PinStoreError.staleImport}
        // A current row on another source can still depend on this source's
        // history/link proof. Do not mutate that dependency behind its owner.
        guard !state.items.contains(where:{row in
            !old.contains(where:{$0.id==row.id}) &&
            (row.previousEvidence?.sources.contains(before)==true ||
             row.bookingLinkEvidence?.identities.contains(where:{$0.issuer.source.id==before.id || $0.reference.source.id==before.id})==true)
        })else{throw PinStoreError.staleImport}
        let group=GroupReplacement(id:UUID(),before:before,after:after,beforeMemorySHA256:try Self.memoryDigest(prepared.before),afterMemorySHA256:try Self.memoryDigest(prepared.after),phase:.sourcePrepared,previous:old)
        var next=state
        next.items.removeAll{row in old.contains(where:{$0.id==row.id})}
        next.groupReplacements=(next.groupReplacements ?? []).filter{$0.before.id != before.id}+[group]
        next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? [])+[before])).sorted{$0.id<$1.id}
        try save(next)
        return .init(id:group.id,owner:canonicalSession,epoch:epoch)
    }
    public func groupReplacementStatus(_ id:UUID)->AppointmentGroupReplacementStatus? {
        guard let group=state.groupReplacements?.first(where:{$0.id==id})else{return nil}
        return .init(id:id,phase:group.phase,sourceBefore:group.before,sourceAfter:group.after,retainedRecordIDs:group.previous.map(\.id),allocatedRecordIDs:group.childIDs)
    }
    /// Cold recovery renews only process-local writer authority, never a model
    /// session, source revision, grouping receipt or consumed dispatch budget.
    public func resumeGroupReplacement(_ id:UUID,permit:AppointmentPermit)throws->AppointmentGroupReplacementTicket {
        let ticket=AppointmentGroupReplacementTicket(id:id,owner:canonicalSession,epoch:epoch)
        _=try checkedGroup(ticket,permit:permit);return ticket
    }
    private func checkedGroup(_ ticket:AppointmentGroupReplacementTicket,permit:AppointmentPermit)throws->(Int,GroupReplacement) {
        guard ticket.owner==canonicalSession,ticket.epoch==epoch,permit.epoch==epoch,
              let index=state.groupReplacements?.firstIndex(where:{$0.id==ticket.id}),let group=state.groupReplacements?[index],group.phase != .completed,group.phase != .invalidated else{throw PinStoreError.staleImport}
        let source=group.phase == .sourcePrepared ? group.before:group.after
        let digest=group.phase == .sourcePrepared ? group.beforeMemorySHA256:group.afterMemorySHA256
        guard visible[source.id]==source,let memory=currentMemories[source.id],try Self.memoryDigest(memory)==digest,
              group.previous.allSatisfy({old in old.canonicalRevision==state.canonicalRevisions?[old.id] && !state.items.contains(where:{$0.id==old.id})})else{throw PinStoreError.staleImport}
        return (index,group)
    }
    public func abortGroupReplacementBeforeSourceChange(_ ticket:AppointmentGroupReplacementTicket,permit:AppointmentPermit)throws {
        let(index,group)=try checkedGroup(ticket,permit:permit)
        guard group.phase == .sourcePrepared,group.childIDs.isEmpty,group.staged.isEmpty else{throw PinStoreError.staleImport}
        var next=state;next.items += group.previous
        next.pendingSemanticSources=next.pendingSemanticSources?.filter{$0 != group.before}
        next.groupReplacements?.remove(at:index);try save(next)
    }
    /// Disposal is separate from dispatch reconciliation. Only the native
    /// orchestrator calls this AFTER reconciling its actual attempt journals;
    /// the digest records that evidence reference, not semantic/dispatch proof.
    /// A genuinely different current source can then start a new reading. Old
    /// tickets, IDs and bindings remain retired; no receipt or budget is reset.
    public func retireInvalidatedGroupReplacement(_ id:UUID,current:PhotoMemory,dispatchReconciliationSHA256:String,permit:AppointmentPermit)throws {
        guard permit.epoch==epoch,Self.validDigest(dispatchReconciliationSHA256),
              let index=state.groupReplacements?.firstIndex(where:{$0.id==id}),let group=state.groupReplacements?[index],group.phase == .invalidated else{throw PinStoreError.staleImport}
        let source=AppointmentSource(current),digest=try Self.memoryDigest(current)
        guard source.id==group.before.id,source != group.before,source != group.after,
              visible[source.id]==source,currentMemories[source.id]==current,
              !state.items.contains(where:{$0.allSources.contains(where:{$0.id==source.id})})else{throw PinStoreError.staleImport}
        let reference=SHA256.hash(data:Data((id.uuidString+"|"+digest+"|"+dispatchReconciliationSHA256).utf8)).map{String(format:"%02x",$0)}.joined()
        var next=state
        next.retiredCanonicalRecordIDs=Array(Set((next.retiredCanonicalRecordIDs ?? [])+group.previous.map(\.id)+group.childIDs)).sorted()
        next.retiredCanonicalSourceSHA256=Array(Set((next.retiredCanonicalSourceSHA256 ?? [])+[Self.retiredDigest(group.before),Self.retiredDigest(group.after)])).sorted()
        next.groupReplacementRetirementSHA256=Array(Set((next.groupReplacementRetirementSHA256 ?? [])+[reference])).sorted()
        next.groupReplacements?.remove(at:index)
        next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? []).filter{$0.id != source.id}+[source])).sorted{$0.id<$1.id}
        try save(next)
    }
    /// The native SDK adapter calls this only after validating the complete new
    /// grouping. Allocation is persisted before any per-child semantic work.
    /// Repeat recovery returns the same IDs for the same actual grouping task.
    public func allocateGroupReplacementChildren(_ ticket:AppointmentGroupReplacementTicket,count:Int,groupingTaskSHA256:String,permit:AppointmentPermit)throws->[CanonicalWriteTicket] {
        let(index,group)=try checkedGroup(ticket,permit:permit)
        guard group.phase == .sourceAdvanced,(1...3).contains(count),Self.validDigest(groupingTaskSHA256) else{throw PinStoreError.staleImport}
        if !group.childIDs.isEmpty {
            guard group.childIDs.count==count,group.groupingTaskSHA256==groupingTaskSHA256 else{throw PinStoreError.staleImport}
            return group.childIDs.map{.init(session:canonicalSession,id:$0,expectedRevision:nil,previous:nil)}
        }
        let children=(0..<count).map{_ in reserveCanonicalRecord()}
        var next=state;next.groupReplacements?[index].childIDs=children.map(\.id);next.groupReplacements?[index].groupingTaskSHA256=groupingTaskSHA256
        try save(next);return children
    }
    /// Validate every child against current native observations before saving a
    /// ready checkpoint. A partial or invalid array changes no bytes or rows.
    public func stageGroupReplacementChildren(_ drafts:[CanonicalAppointmentDraft],tickets:[CanonicalWriteTicket],transaction:AppointmentGroupReplacementTicket,permit:AppointmentPermit)throws {
        let(index,group)=try checkedGroup(transaction,permit:permit)
        guard group.phase == .sourceAdvanced,!group.childIDs.isEmpty,drafts.map(\.recordID)==group.childIDs,tickets.map(\.id)==group.childIDs,
              drafts.allSatisfy({$0.sources==[group.after] && $0.bookingLinkEvidence==nil && $0.recordRevision==1})else{throw PinStoreError.staleImport}
        var candidate=state;var rows:[AppointmentItem]=[]
        for (draft,ticket)in zip(drafts,tickets) {
            let(next,row)=try canonicalCandidate(draft,ticket:ticket,permit:permit,state:candidate)
            candidate=next;rows.append(row)
        }
        var next=state;next.groupReplacements?[index].staged=rows;next.groupReplacements?[index].phase = .readyToCommit
        try save(next)
    }
    /// One atomic native write admits the whole group. Staged rows are checked
    /// again after cold reopen; they have no authority while merely pending.
    /// Staging inspection for the owning semantic adapter only. These rows are
    /// not all(), reminder or original-view authority and cannot be published.
    public func groupReplacementCandidateRecords(_ transaction:AppointmentGroupReplacementTicket,permit:AppointmentPermit)throws->[AppointmentItem] {
        let(_,group)=try checkedGroup(transaction,permit:permit)
        guard group.phase == .readyToCommit,!group.childIDs.isEmpty,group.staged.map(\.id)==group.childIDs else{throw PinStoreError.staleImport}
        return group.staged
    }
    @discardableResult public func commitGroupReplacement(_ transaction:AppointmentGroupReplacementTicket,permit:AppointmentPermit)throws->[AppointmentItem] {
        let(index,group)=try checkedGroup(transaction,permit:permit)
        guard group.phase == .readyToCommit,!group.childIDs.isEmpty,group.staged.map(\.id)==group.childIDs else{throw PinStoreError.staleImport}
        var next=state;var rows:[AppointmentItem]=[]
        for staged in group.staged {
            guard staged.canonicalRevision==1,staged.previousEvidence==nil,staged.bookingLinkEvidence==nil,!staged.dismissed,!staged.remindersApproved,
                  staged.allSources==[group.after],let support=staged.semanticSupport else{throw PinStoreError.staleImport}
            let draft=CanonicalAppointmentDraft(recordID:staged.id,recordRevision:1,observation:staged.observation,sources:[group.after],support:support,documentOnlyWithoutDate:staged.observation.documentOnlyWithoutDate==true)
            let ticket=CanonicalWriteTicket(session:canonicalSession,id:staged.id,expectedRevision:nil,previous:nil)
            let(candidate,row)=try canonicalCandidate(draft,ticket:ticket,permit:permit,state:next)
            guard row==staged else{throw PinStoreError.staleImport};next=candidate;rows.append(row)
        }
        next.pendingSemanticSources=next.pendingSemanticSources?.filter{$0.id != group.before.id}
        next.retiredCanonicalSourceSHA256=Array(Set((next.retiredCanonicalSourceSHA256 ?? [])+[Self.retiredDigest(group.before)])).sorted()
        next.retiredCanonicalRecordIDs=Array(Set((next.retiredCanonicalRecordIDs ?? [])+group.previous.map(\.id))).sorted()
        next.canonicalSourceCoverage=Array(Set((next.canonicalSourceCoverage ?? []).filter{$0.id != group.before.id}+[group.after])).sorted{$0.id<$1.id}
        next.groupReplacements?[index].previous=[];next.groupReplacements?[index].staged=[];next.groupReplacements?[index].phase = .completed
        try save(next);return rows
    }
    /// The caller has validated the complete grouped-source reading, not just
    /// one child. Compare every exact current child before ending preparation.
    /// This acknowledges completed reading; it establishes no event identity.
    public func completeGroupedSemanticRead(_ source:AppointmentSource,records:[AppointmentItem],permit:AppointmentPermit)throws {
        guard !hasPendingGroup(source.id)else{throw PinStoreError.staleImport}
        guard permit.epoch==epoch,visible[source.id]==source,!isRetired(source),!records.isEmpty,
              Set(records.compactMap(\.canonicalRecordID)).count==records.count,
              records.allSatisfy({!$0.dismissed && $0.allSources==[source] && $0.previousEvidence==nil})else{throw PinStoreError.staleImport}
        let current=state.items.filter{$0.canonicalRecordID != nil && $0.allSources.contains(source)}
        guard current.count==records.count,current.allSatisfy(records.contains)else{throw PinStoreError.staleImport}
        guard (state.pendingSemanticSources ?? []).contains(source)else{return}
        var next=state;next.pendingSemanticSources=next.pendingSemanticSources?.filter{$0 != source};try save(next)
    }
    public func beginSemanticRead(_ source:AppointmentSource,permit:AppointmentPermit)throws {
        guard !hasPendingGroup(source.id)else{throw PinStoreError.staleImport}
        guard permit.epoch==epoch,visible[source.id]==source,!isRetired(source),
              !state.items.contains(where:{$0.canonicalRecordID != nil && $0.allSources.contains(source)}) else{throw PinStoreError.staleImport}
        var next=state;next.schema=3
        next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? [])+[source])).sorted{$0.id<$1.id}
        next.items.removeAll{$0.canonicalRecordID==nil && $0.source==source}
        if next.items != state.items || next.pendingSemanticSources != state.pendingSemanticSources{try save(next)}
    }
    public func rejectedSources()->Set<AppointmentSource>{Set((state.sourceRejections ?? []).filter{visible[$0.source.id]==$0.source}.map(\.source))}
    /// Explicit semantic writer operation; a generic remove cannot manufacture
    /// this outcome. Existing canonical rows require their own correction path.
    public func rejectSource(_ rejection:AppointmentSourceRejection,permit:AppointmentPermit)throws {
        guard !hasPendingGroup(rejection.source.id)else{throw PinStoreError.staleImport}
        guard permit.epoch==epoch,visible[rejection.source.id]==rejection.source,
              rejection.version==AppointmentSourceRejection.readerVersion,!rejection.observationIDs.isEmpty,
              rejection.taskSHA256.count==64,rejection.taskSHA256.allSatisfy({$0.isHexDigit}),
              let lines=currentObservations[rejection.source.id],
              try lines.enumerated().map({try PinOCRObservationID.make($0.element,offset:$0.offset)})==rejection.observationIDs,
              !state.items.contains(where:{$0.canonicalRecordID != nil && $0.allSources.contains(rejection.source)}) else{throw PinStoreError.staleImport}
        var next=state
        next.pendingSemanticSources=next.pendingSemanticSources?.filter{$0 != rejection.source}
        next.items.removeAll{$0.source==rejection.source && $0.canonicalRecordID==nil}
        var reads=next.sourceRejections ?? [];reads.removeAll{$0.source.id==rejection.source.id};reads.append(rejection);reads.sort{$0.source.id<$1.source.id};next.sourceRejections=reads;next.schema=3
        if next.items != state.items || next.sourceRejections != state.sourceRejections || next.pendingSemanticSources != state.pendingSemanticSources {try save(next)}
    }
    public func all() -> [AppointmentItem] { state.items.filter { item in item.allSources.allSatisfy { visible[$0.id] == $0 } } }
    public func put(_ item: AppointmentItem, permit: AppointmentPermit) throws {
        try putBound(item,permit:permit,selectedFacts:nil)
    }
    private func putBound(_ item: AppointmentItem, permit: AppointmentPermit, selectedFacts:[FieldFact]?) throws {
        guard !hasPendingGroup(item.sourceID)else{throw PinStoreError.staleImport}
        guard item.eventID == nil,item.canonicalRecordID==nil,item.canonicalRevision==nil,item.additionalSources==nil,
              item.semanticSupport==nil,item.previousEvidence==nil,item.observation.components==nil,
              permit.epoch == epoch, visible[item.sourceID] == item.source,
              item.observation.sourceID == item.sourceID else { throw PinStoreError.staleImport }
        guard !isRetired(item.source),!(state.pendingSemanticSources ?? []).contains(item.source),!(state.sourceRejections ?? []).contains(where:{$0.source==item.source}),!(state.canonicalSourceCoverage ?? []).contains(item.source),!state.items.contains(where: { $0.canonicalRecordID != nil && $0.allSources.contains(item.source) }) else { throw PinStoreError.staleImport }
        var next = state
        var updated = item
        // Derivation is bound here, inside the same source permit as the card.
        // Caller-supplied fact bindings cannot bypass source/version checks.
        let source=EvidenceSource(id:item.source.id,fingerprint:item.source.fingerprint,revision:item.source.revision)
        if let selectedFacts {
            guard selectedFacts.allSatisfy({$0.source==source && $0.origin != .external && !$0.support.isEmpty && $0.support.allSatisfy({line in item.observation.evidence.contains(line) && currentObservations[item.sourceID]?.contains(line)==true})}) else {throw PinStoreError.staleImport}
            updated.observation.fieldFacts=selectedFacts
        }else{updated.observation.fieldFacts=AppointmentCardReader.facts(for:item.observation,source:source)}
        if let old = next.items.first(where: { $0.id == item.id && $0.source == item.source }) {
            updated.dismissed = old.dismissed
            updated.remindersApproved = old.remindersApproved && !old.dismissed && old.observation.date == item.observation.date && old.observation.timeZoneID == item.observation.timeZoneID && item.observation.reviewReason == nil
        }
        next.items.removeAll { $0.sourceID == item.sourceID }; next.items.append(updated); try save(next)
    }
    /// The compiler seals this candidate after current-source and field-ID
    /// validation. The ordinary put path rebinds facts inside the same permit.
    public func putSemantic(_ candidate: SemanticAppointmentCandidate, permit: AppointmentPermit) throws {
        try putBound(candidate.item, permit: permit, selectedFacts:candidate.facts)
    }
    /// Replace the interpretation of one current photo atomically with one or
    /// more independent source-backed events. Derived identities require the
    /// explicit source-anchor compiler contract. This is a storage boundary only;
    /// the interpreter must still prove each field's meaning before calling it.
    public func putSemanticEvents(_ events: [AppointmentItem], source: AppointmentSource, permit: AppointmentPermit) throws {
        guard permit.epoch == epoch, visible[source.id] == source, !isRetired(source), (1...8).contains(events.count) else { throw PinStoreError.staleImport }
        let evidenceSource = EvidenceSource(id: source.id, fingerprint: source.fingerprint, revision: source.revision)
        var keys = Set<String>()
        for event in events {
            guard event.canonicalRecordID==nil,event.canonicalRevision==nil,event.additionalSources==nil,
                  event.semanticSupport==nil,event.previousEvidence==nil,event.observation.components==nil,
                  event.source == source, event.observation.sourceID == source.id,
                  let key = event.eventID, !key.isEmpty, key.utf8.count <= 256, keys.insert(key).inserted,
                  let facts = event.observation.fieldFacts,
                  ((event.observation.bookingReference == key &&
                    facts.contains(where: { $0.field == "bookingReference" && $0.value == key && $0.origin == .observed })) ||
                   (event.observation.bookingReference == nil &&
                    QuotedAppointmentCompiler.sourceAnchorID(for: event.observation, source: source) == key)),
                  facts.allSatisfy({ fact in
                      fact.source == evidenceSource && fact.origin != .external && !fact.support.isEmpty &&
                      (fact.origin != .observed || fact.support.contains(where: { $0.text.contains(fact.value) })) &&
                      fact.support.allSatisfy { line in
                          line.confidence >= 0.5 && event.observation.evidence.contains(line) &&
                          currentObservations[source.id]?.contains(line) == true
                      }
                  }) else { throw PinStoreError.staleImport }
        }
        guard !(state.pendingSemanticSources ?? []).contains(source),!(state.sourceRejections ?? []).contains(where:{$0.source==source}),!(state.canonicalSourceCoverage ?? []).contains(source),!state.items.contains(where: { $0.canonicalRecordID != nil && $0.allSources.contains(source) }) else { throw PinStoreError.staleImport }
        let previousRows = state.items.filter { $0.source == source }
        guard Set(previousRows.map(\.id)).count == previousRows.count else { throw PinStoreError.unsupportedSchema }
        let previous = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.id, $0) })
        var next = state
        next.items.removeAll { $0.sourceID == source.id }
        for event in events {
            var row = event
            if let old = previous[row.id] {
                let unchanged = old.hasSameEvidence(as: row)
                row.dismissed = unchanged && old.dismissed
                row.remindersApproved = unchanged && old.remindersApproved && !old.dismissed &&
                    row.observation.reviewReason == nil
            } else {
                row.dismissed = false
                row.remindersApproved = false
            }
            next.items.append(row)
        }
        try save(next)
    }
    /// An explicit notBooking source decision withdraws a prior
    /// rule-derived row for this exact source. Reconciliation removes its OS
    /// reminders; a changed source or stale decision cannot remove a new row.
    public func removeCurrent(_ source: AppointmentSource, permit: AppointmentPermit) throws {
        guard permit.epoch == epoch, visible[source.id] == source else { throw PinStoreError.staleImport }
        guard state.items.contains(where: { $0.canonicalRecordID == nil && $0.source == source }) else { return }
        var next = state
        next.items.removeAll { $0.canonicalRecordID == nil && $0.source == source }
        try save(next)
    }
    public func approve(_ item: AppointmentItem) throws {
        guard let index = state.items.firstIndex(where: { $0.id == item.id && $0.source == item.source }), item.allSources.allSatisfy({visible[$0.id] == $0}),(item.canonicalRecordID == nil || (state.items[index].hasSameEvidence(as:item) && state.items[index].canonicalRevision==item.canonicalRevision)) else {throw PinStoreError.staleResult}
        var observed=item.observation
        if state.items[index].observation.semanticVersion != nil {observed.fieldFacts=state.items[index].observation.fieldFacts}
        else {observed.fieldFacts=AppointmentCardReader.facts(for:observed,source:EvidenceSource(id:item.source.id,fingerprint:item.source.fingerprint,revision:item.source.revision))}
        guard state.items[index].observation == observed, !state.items[index].dismissed,
              item.observation.reviewReason == nil, item.observation.cancelled != true, item.observation.date != nil else { throw PinStoreError.staleResult }
        var next = state; next.items[index].remindersApproved = true; try save(next)
    }
    public func dismiss(_ item: AppointmentItem) throws {
        guard let index = state.items.firstIndex(where: { $0.id == item.id && $0.source == item.source }), item.allSources.allSatisfy({visible[$0.id] == $0}),(item.canonicalRecordID == nil || (state.items[index].hasSameEvidence(as:item) && state.items[index].canonicalRevision==item.canonicalRevision)) else { throw PinStoreError.staleResult }
        var next = state; next.items[index].dismissed = true; next.items[index].remindersApproved = false; try save(next)
    }
    public func hasCompletedInitialRead(_ source:AppointmentSource)->Bool {
        (state.initialReads ?? []).contains{$0.source==source && $0.completed}
    }
    public func hasIncompleteInitialRead(_ source:AppointmentSource)->Bool {
        (state.initialReads ?? []).contains{$0.source==source && !$0.completed}
    }
    /// Only an untouched observation may take the image-first route. Existing
    /// semantic work, owner decisions and history retain their original route.
    public func canBeginInitialVisualRead(_ memory:PhotoMemory,permit:AppointmentPermit)throws->Bool {
        guard permit.epoch==epoch,currentMemories[memory.id]==memory,visible[memory.id]==AppointmentSource(memory)else{throw PinStoreError.staleImport}
        guard memory.revision==1,memory.visualReading==nil,!hasPendingGroup(memory.id),!isRetired(AppointmentSource(memory)),
              !(state.initialReads ?? []).contains(where:{$0.source.id==memory.id}),
              !(state.pendingSemanticSources ?? []).contains(where:{$0.id==memory.id}),
              !(state.sourceRejections ?? []).contains(where:{$0.source.id==memory.id}),
              !(state.canonicalSourceCoverage ?? []).contains(where:{$0.id==memory.id}),
              !state.items.contains(where:{row in
                  (row.allSources+(row.previousEvidence?.sources ?? [])).contains(where:{$0.id==memory.id}) &&
                  (row.canonicalRecordID != nil || row.dismissed || row.remindersApproved || row.observation.semanticVersion != nil || !row.observation.ownerCorrectionFields.isEmpty)
              })else{return false}
        return true
    }
    /// Save the work identity BEFORE any source decision. Resume requires the
    /// entire current memory and the same semantic contract, not just its ID.
    public func beginInitialRead(_ memory:PhotoMemory,originalSHA256:String,contractSHA256:String,permit:AppointmentPermit)throws->AppointmentInitialReadTicket {
        let source=AppointmentSource(memory),hash=try Self.memoryDigest(memory)
        guard permit.epoch==epoch,currentMemories[memory.id]==memory,!hasPendingGroup(memory.id),!isRetired(source),
              [originalSHA256,contractSHA256].allSatisfy(Self.validDigest)else{throw PinStoreError.staleImport}
        if let read=state.initialReads?.first(where:{$0.source.id==memory.id}) {
            guard read.source==source,read.memorySHA256==hash,read.originalSHA256==originalSHA256,read.contractSHA256==contractSHA256,
                  !read.completed else{throw PinStoreError.staleImport}
            return .init(id:read.id,resumed:true,owner:canonicalSession,epoch:epoch)
        }
        guard !state.items.contains(where:{$0.canonicalRecordID != nil && $0.allSources.contains(source)})else{throw PinStoreError.staleImport}
        let read=InitialRead(id:UUID(),source:source,memorySHA256:hash,originalSHA256:originalSHA256,contractSHA256:contractSHA256)
        var next=state;next.initialReads=(next.initialReads ?? [])+[read]
        next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? [])+[source])).sorted{$0.id<$1.id}
        next.items.removeAll{$0.canonicalRecordID==nil && $0.source==source}
        try save(next)
        return .init(id:read.id,resumed:false,owner:canonicalSession,epoch:epoch)
    }
    private func initialRead(_ ticket:AppointmentInitialReadTicket,permit:AppointmentPermit)throws->InitialRead {
        guard ticket.owner==canonicalSession,ticket.epoch==epoch,permit.epoch==epoch,
              let read=state.initialReads?.first(where:{$0.id==ticket.id}),!read.completed,
              let memory=currentMemories[read.source.id],AppointmentSource(memory)==read.source,
              try Self.memoryDigest(memory)==read.memorySHA256,!isRetired(read.source),!hasPendingGroup(read.source.id)else{throw PinStoreError.staleImport}
        return read
    }
    public func reserveInitialRecord(_ ticket:AppointmentInitialReadTicket,assessmentSHA256:String,ordinal:Int,permit:AppointmentPermit)throws->CanonicalWriteTicket {
        var read=try initialRead(ticket,permit:permit)
        guard Self.validDigest(assessmentSHA256),(1...3).contains(ordinal)else{throw PinStoreError.staleImport}
        if let child=read.children.first(where:{$0.ordinal==ordinal}) {
            guard child.assessmentSHA256==assessmentSHA256 else{throw PinStoreError.staleImport}
            return .init(session:canonicalSession,id:child.recordID,expectedRevision:nil,previous:nil,initialReadID:read.id)
        }
        guard read.children.count<3 else{throw PinStoreError.staleImport}
        let child=InitialChild(assessmentSHA256:assessmentSHA256,ordinal:ordinal,recordID:"pin.record."+UUID().uuidString)
        read.children.append(child)
        var next=state;next.initialReads=next.initialReads?.map{$0.id==read.id ? read:$0};try save(next)
        return .init(session:canonicalSession,id:child.recordID,expectedRevision:nil,previous:nil,initialReadID:read.id)
    }
    /// The caller has completed and archived the whole source pipeline. A
    /// partial child cannot mark the other allocated children as complete.
    public func finishInitialRead(_ ticket:AppointmentInitialReadTicket,records:[AppointmentItem],permit:AppointmentPermit,clearingSourcePending:Bool=false)throws {
        var read=try initialRead(ticket,permit:permit)
        let ids=Set(read.children.map(\.recordID)),current=state.items.filter{ids.contains($0.id)}
        guard Set(records.map(\.id))==ids,records.count==ids.count,current.count==ids.count,
              current.allSatisfy(records.contains),records.allSatisfy({!$0.dismissed && $0.canonicalRevision==1 && $0.allSources==[read.source]})else{throw PinStoreError.staleImport}
        read.completed=true
        var next=state;next.initialReads=next.initialReads?.map{$0.id==read.id ? read:$0}
        // Completion and coverage settle together. A crash cannot leave a
        // finished single-source reading marked as unfinished indefinitely.
        if clearingSourcePending {
            guard !records.isEmpty else{throw PinStoreError.staleImport}
            // A completed pipeline settles coverage only when the current
            // image receipt covers one readable document and its one record.
            // Partial/multiple-document readings still need preparation.
            var settled=true
            if let memory=currentMemories[read.source.id],let reading=memory.visualReading {
                try reading.validate(for:memory)
                let receipt=try reading.validatedReceipt()
                settled=receipt.coverage=="readable" && receipt.visibleDocumentCount==1 && records.count==1
            }
            if settled {next.pendingSemanticSources=next.pendingSemanticSources?.filter{$0 != read.source}}
        }
        try save(next)
    }
    /// The native writer allocates IDs; a model/reference string cannot mint one.
    public func reserveCanonicalRecord() -> CanonicalWriteTicket {
        .init(session:canonicalSession,id:"pin.record."+UUID().uuidString,expectedRevision:nil,previous:nil)
    }
    public func prepareCanonicalReplacement(id:String)throws->CanonicalWriteTicket {
        try canonicalReplacement(id:id,state:state)
    }
    private func canonicalReplacement(id:String,state:State)throws->CanonicalWriteTicket {
        guard !(state.retiredCanonicalRecordIDs ?? []).contains(id),
              !(state.groupReplacements ?? []).contains(where:{$0.phase != .completed && ($0.previous.contains(where:{$0.id==id}) || $0.childIDs.contains(id))}),
              let revision=state.canonicalRevisions?[id] else{throw PinStoreError.staleResult}
        let previous=state.items.first{$0.canonicalRecordID==id}
        return .init(session:canonicalSession,id:id,expectedRevision:revision,previous:previous)
    }
    @discardableResult public func commitCanonical(_ draft:CanonicalAppointmentDraft,ticket:CanonicalWriteTicket,permit:AppointmentPermit,keepingSourcePending:AppointmentSource?=nil,diagnostic:(@Sendable(String)->Void)?=nil)throws->AppointmentItem {
        guard !(state.retiredCanonicalRecordIDs ?? []).contains(draft.recordID),
              !(state.groupReplacements ?? []).contains(where:{group in group.phase != .completed &&
                  (draft.sources.contains(where:{$0.id==group.before.id}) || group.previous.contains(where:{$0.id==draft.recordID}) || group.childIDs.contains(draft.recordID))}) else{throw PinStoreError.staleImport}
        if let readID=ticket.initialReadID {
            guard let read=state.initialReads?.first(where:{$0.id==readID}),!read.completed,
                  let memory=currentMemories[read.source.id],try Self.memoryDigest(memory)==read.memorySHA256,
                  read.children.contains(where:{$0.recordID==ticket.id}),draft.sources==[read.source]else{throw PinStoreError.staleImport}
            if let current=state.items.first(where:{$0.id==ticket.id}) {
                // Revalidate the draft with the same native writer, then compare
                // the WHOLE row. Replaying cannot undo correction or dismissal.
                var prior=state;prior.items.removeAll{$0.id==ticket.id};prior.canonicalRevisions?.removeValue(forKey:ticket.id)
                let (_,row)=try canonicalCandidate(draft,ticket:ticket,permit:permit,keepingSourcePending:keepingSourcePending,diagnostic:diagnostic,state:prior)
                guard row==current else{throw PinStoreError.staleImport}
                return current
            }
        }
        let (next,row)=try canonicalCandidate(draft,ticket:ticket,permit:permit,keepingSourcePending:keepingSourcePending,diagnostic:diagnostic,state:state)
        try save(next);return row
    }
    /// The caller confirms an edit against the whole currently displayed row.
    /// CAS and current source access are checked by the same native writer;
    /// existing semantic import cannot mint this owner-confirmed operation.
    @discardableResult public func correct(_ expected:AppointmentItem,with correction:AppointmentOwnerCorrection,permit:AppointmentPermit)throws->AppointmentItem {
        let (candidate,row)=try ownerCorrectionCandidate(expected,with:correction,permit:permit,state:state)
        var next=candidate
        let history=state.ownerCorrections ?? []
        if let prior=history.last(where:{$0.after.id==expected.id}) {
            guard Self.correctionContinues(prior.after,expected)else{throw PinStoreError.staleResult}
        }
        next.ownerCorrections=history+[AppointmentOwnerCorrectionTransition(operationID:UUID(),before:expected,correction:correction,after:row)]
        try save(next);return row
    }
    /// Reuse the exact native mutation rules for read-only witness replay.
    private func ownerCorrectionCandidate(_ expected:AppointmentItem,with correction:AppointmentOwnerCorrection,permit:AppointmentPermit,state:State)throws->(State,AppointmentItem) {
        guard permit.epoch==epoch,!expected.dismissed,
              let current=state.items.first(where:{$0.id==expected.id}),current==expected,
              let id=expected.canonicalRecordID,let revision=expected.canonicalRevision,revision<Int.max,
              expected.allSources.allSatisfy({visible[$0.id]==$0}),
              var support=expected.semanticSupport,var facts=expected.observation.fieldFacts,
              let titleSupport=support.first(where:{$0.field=="title"}) else{throw PinStoreError.staleResult}
        var observation=expected.observation
        let field:String,value:String
        func text(_ input:String)throws->String {
            let clean=input.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !clean.isEmpty,clean.utf8.count<=4096 else{throw PinStoreError.staleImport}
            return clean
        }
        switch correction {
        case .title(let input):field="title";value=try text(input);observation.title=value
        case .provider(let input):field="provider";value=try text(input);observation.provider=value
        case .venue(let input):field="venue";value=try text(input);observation.venue=value
        case .performer(let input):field="performer";value=try text(input);observation.performer=value
        case .address(let input):field="venueAddress";value=try text(input);observation.address=value
        case .eventTicket(let input):field="kind";value=input ? "eventTicket":"appointment";observation.eventTicket=input
        case .cancelled(let input):field="status";value=input ? "cancelled":"scheduled";observation.cancelled=input
        case .schedule(var input):
            // Retain actual printed wording; the new civil values are the
            // owner's correction, never a fabricated quotation from the photo.
            input.printedDateText=observation.components?.printedDateText
            input.printedTimeText=observation.components?.printedTimeText
            input.certainty="explicit";input.captureYearDerivation=nil;input.temporalDerivation=nil
            guard input.isValid,input.hasTemporalClaim else{throw PinStoreError.staleImport}
            field="date";value=String(decoding:try JSONEncoder().encode(input),as:UTF8.self)
            observation.components=input;observation.date=input.resolvedInstant
            observation.printedDate=input.printedDateText;observation.printedTime=input.printedTimeText
            observation.timeZoneID=input.timeZoneID ?? "UTC";observation.zoneFromCard=input.timeZoneID != nil
            observation.inferredYear=nil;observation.yearBasisDate=nil;observation.documentOnlyWithoutDate=false
            observation.reviewReason=input.resolvedInstant==nil ? "Some corrected date or time details are missing. Check your correction.":nil
        }
        guard observation != expected.observation else{throw PinStoreError.staleImport}
        let version="pin-owner-correction/1",nativeField=field=="date" ? "eventDate":field
        let priorSupport=support.first(where:{$0.field==field}) ?? titleSupport
        let priorFacts=facts.filter{$0.field==nativeField}
        let anchors=priorFacts.isEmpty ? facts.filter{$0.field=="title"}:priorFacts
        guard !anchors.isEmpty else{throw PinStoreError.staleImport}
        // Source anchors identify the corrected record and preserve its printed
        // evidence. The correction's value is explicitly domain-originated.
        let changed=anchors.map { original -> FieldFact in
            var fact=original;fact.field=nativeField;fact.value=value
            fact.origin = .inferred;fact.extractorVersion=version;return fact
        }
        support.removeAll{$0.field==field}
        support.append(AppointmentSemanticField(field:field,origin:"domainCorrection",anchors:priorSupport.anchors,confidence:priorSupport.confidence,extractorVersion:version))
        facts.removeAll{$0.field==nativeField};facts.append(contentsOf:changed)
        observation.fieldFacts=facts;observation.evidence=facts.flatMap(\.support)
        guard observation != expected.observation else{throw PinStoreError.staleImport}
        let ticket=try canonicalReplacement(id:id,state:state)
        let draft=CanonicalAppointmentDraft(recordID:id,recordRevision:revision+1,observation:observation,sources:expected.allSources,support:support,documentOnlyWithoutDate:observation.documentOnlyWithoutDate==true,bookingLinkEvidence:expected.bookingLinkEvidence)
        let (next,row)=try canonicalCandidate(draft,ticket:ticket,permit:permit,state:state,ownerCorrectionFields:[field])
        return (next,row)
    }
    private static func correctionContinues(_ after:AppointmentItem,_ before:AppointmentItem)->Bool {
        // Reminder approval is mutable action state, never semantic evidence.
        var comparable=before;comparable.remindersApproved=after.remindersApproved
        return comparable==after
    }
    private static func validOwnerCorrectionHistory(_ steps:[AppointmentOwnerCorrectionTransition])->Bool {
        guard Set(steps.map(\.operationID)).count==steps.count else{return false}
        var last:[String:AppointmentItem]=[:]
        for step in steps {
            guard let before=step.before.canonicalRevision,let after=step.after.canonicalRevision,
                  before>0,before<Int.max,after==before+1,step.before.canonicalRecordID==step.after.canonicalRecordID,
                  step.before.canonicalRecordID != nil,step.before.id==step.after.id,
                  !step.before.dismissed,!step.after.dismissed,step.before.allSources==step.after.allSources,
                  step.after.previousEvidence?.revision==before,
                  step.after.previousEvidence?.observation==step.before.observation,
                  step.after.previousEvidence?.semanticSupport==step.before.semanticSupport,
                  step.after.previousEvidence?.sources==step.before.allSources else{return false}
            if let previous=last[step.before.id],!correctionContinues(previous,step.before){return false}
            last[step.after.id]=step.after
        }
        return true
    }
    /// Replay the native history with current full-row/source/epoch checks.
    /// The paired verifier must separately authenticate native confirmation;
    /// consistency of serialized transitions alone grants no confirmation.
    public func replayedOwnerCorrectionHistory(for expected:AppointmentItem,permit:AppointmentPermit)throws->AppointmentReplayedCorrectionHistory {
        guard permit.epoch==epoch,!expected.dismissed,state.items.contains(expected),
              expected.allSources.allSatisfy({visible[$0.id]==$0})else{throw PinStoreError.staleResult}
        let steps=(state.ownerCorrections ?? []).filter{$0.after.id==expected.id}
        guard let first=steps.first,let last=steps.last,last.after.hasSameEvidence(as:expected),
              last.after.canonicalRevision==expected.canonicalRevision,last.after.previousEvidence==expected.previousEvidence,
              first.before.observation.ownerCorrectionFields.isEmpty,
              Self.validOwnerCorrectionHistory(steps)else{throw PinStoreError.staleResult}
        for step in steps {
            var baseline=state;baseline.items.removeAll{$0.id==expected.id};baseline.items.append(step.before)
            baseline.canonicalRevisions=baseline.canonicalRevisions ?? [:]
            baseline.canonicalRevisions?[expected.id]=step.before.canonicalRevision
            let (_,replayed)=try ownerCorrectionCandidate(step.before,with:step.correction,permit:permit,state:baseline)
            guard replayed==step.after else{throw PinStoreError.staleResult}
        }
        return AppointmentReplayedCorrectionHistory(transitions:steps,current:expected,sources:expected.allSources)
    }
    private func canonicalCandidate(_ draft:CanonicalAppointmentDraft,ticket:CanonicalWriteTicket,permit:AppointmentPermit,keepingSourcePending:AppointmentSource?=nil,diagnostic:(@Sendable(String)->Void)?=nil,state:State,ownerCorrectionFields:Set<String>=[])throws->(State,AppointmentItem) {
        if let source=keepingSourcePending {guard draft.sources.contains(source) else{throw PinStoreError.staleImport}}
        guard ticket.session==canonicalSession,permit.epoch==epoch,draft.recordID==ticket.id,draft.recordRevision==ticket.nextRevision,
              state.canonicalRevisions?[ticket.id]==ticket.expectedRevision else{diagnostic?("ticket");throw PinStoreError.staleImport}
        if let previous=ticket.previous {guard state.items.first(where:{$0.id==ticket.id})==previous else{diagnostic?("replacement.current");throw PinStoreError.staleImport}}
        if let link=draft.bookingLinkEvidence {
            guard let previous=ticket.previous,Self.currentLink(link,sources:visible,observations:currentObservations),
                  link.identities.contains(where:{AppointmentSource($0.issuer.source)==draft.sources.first(where:{$0.id==draft.observation.sourceID})}),
                  link.identities.contains(where:{previous.allSources.contains(AppointmentSource($0.issuer.source))}) else{diagnostic?("booking.link");throw PinStoreError.staleImport}
        }
        if draft.sources.contains(where:{isRetired($0)}) {
            // A retired photo cannot restore its former schedule by itself.
            // It may still support a genuine linked update whose CURRENT
            // status is proved by a nonretired source, never an added label.
            guard draft.bookingLinkEvidence != nil,
                  draft.support.first(where:{$0.field=="status"})?.anchors.contains(where:{!isRetired(AppointmentSource($0.source))})==true else{diagnostic?("retired.source");throw PinStoreError.staleImport}
        }
        let obs=draft.observation
        guard !draft.sources.isEmpty,Set(draft.sources.map(\.id)).count==draft.sources.count,
              draft.sources.allSatisfy({visible[$0.id]==$0}),draft.sources.contains(where:{$0.id==obs.sourceID}),
              let date=obs.components,date.isValid,obs.date==date.resolvedInstant,obs.printedDate==date.printedDateText,obs.printedTime==date.printedTimeText,!obs.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              obs.semanticVersion=="pin-ibrain-components-v1",let facts=obs.fieldFacts,
              obs.evidence==facts.flatMap(\.support),(obs.documentOnlyWithoutDate==true)==draft.documentOnlyWithoutDate,
              obs.timeZoneID==(date.timeZoneID ?? "UTC"),obs.zoneFromCard==(date.timeZoneID != nil) else{diagnostic?("source.DTO");throw PinStoreError.staleImport}
        var required:Set<String>=["title","kind","status"]
        if !draft.documentOnlyWithoutDate{required.insert("date")}
        else if date.hasTemporalClaim || date.certainty != "explicit"{diagnostic?("document.only");throw PinStoreError.staleImport}
        for (field,value)in[("provider",obs.provider),("venue",obs.venue),("performer",obs.performer),("venueAddress",obs.address),("bookingReference",obs.bookingReference)]{
            if let value {guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{diagnostic?("optional.field");throw PinStoreError.staleImport};required.insert(field)}
        }
        guard Set(draft.support.map(\.field))==required,draft.support.count==required.count,
              Set(facts.map(\.source))==Set(draft.sources.map{EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)}),
              Set(facts.map{ $0.field=="eventDate" ? "date":$0.field })==required else{diagnostic?("support.membership");throw PinStoreError.staleImport}
        for text in [date.printedDateText,date.printedTimeText].compactMap({$0}) {
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  draft.support.first(where:{$0.field=="date"})?.anchors.contains(where:{$0.quote==text})==true else{diagnostic?("printed.quote");throw PinStoreError.staleImport}
        }
        if let old=ticket.previous,Set(old.allSources)==Set(draft.sources) {
            for correction in old.semanticSupport ?? [] where correction.origin=="domainCorrection" && correction.extractorVersion=="pin-owner-correction/1" && !ownerCorrectionFields.contains(correction.field) {
                let name=correction.field=="date" ? "eventDate":correction.field
                guard draft.support.contains(correction),old.observation.fieldFacts?.filter({$0.field==name})==facts.filter({$0.field==name}) else{diagnostic?("owner.correction.preserved");throw PinStoreError.staleImport}
            }
        }
        for field in draft.support {
            if field.field=="date",field.origin=="inferred",date.certainty=="explicit" {diagnostic?("date.origin");throw PinStoreError.staleImport}
            if field.origin=="domainCorrection",field.extractorVersion=="pin-owner-correction/1",!ownerCorrectionFields.contains(field.field) {
                // Later imports can preserve a prior correction, but cannot
                // create or silently rewrite this reserved native edit as a source proposal.
                guard let old=ticket.previous,
                      old.semanticSupport?.first(where:{$0.field==field.field})==field,
                      old.observation.fieldFacts?.filter({$0.field==(field.field=="date" ? "eventDate":field.field)})==facts.filter({$0.field==(field.field=="date" ? "eventDate":field.field)}) else{diagnostic?("owner.correction");throw PinStoreError.staleImport}
            }
            if ["performer","venueAddress"].contains(field.field),!(field.origin=="domainCorrection" && field.extractorVersion=="pin-owner-correction/1") {
                var parts:[String]=[]
                for anchor in field.anchors where !parts.contains(anchor.quote){parts.append(anchor.quote)}
                let value=field.field=="performer" ? obs.performer:obs.address
                guard field.origin=="observed",parts.joined(separator:field.field=="performer" ? " / ":"\n")==value else{diagnostic?("field.parts");throw PinStoreError.staleImport}
            }
            guard !field.anchors.isEmpty,!field.extractorVersion.isEmpty,field.confidence.isFinite,(0...1).contains(field.confidence),
                  ["observed","inferred","domainCorrection"].contains(field.origin) else{diagnostic?("field.metadata");throw PinStoreError.staleImport}
            var proof:[EvidenceSource:[CardLine]]=[:]
            var visualProof:[EvidenceSource:[VisualFactSupport]]=[:]
            for anchor in field.anchors {
                guard draft.sources.contains(AppointmentSource(anchor.source)),!anchor.quote.isEmpty,
                      let lines=currentObservations[anchor.source.id] else{diagnostic?("field.anchor");throw PinStoreError.staleImport}
                if let index=try lines.indices.first(where:{try PinOCRObservationID.make(lines[$0],offset:$0)==anchor.observationID}),Data(lines[index].text.utf8).range(of:Data(anchor.quote.utf8)) != nil {
                    if proof[anchor.source]?.contains(lines[index]) != true{proof[anchor.source,default:[]].append(lines[index])}
                } else if ["kind","status"].contains(field.field),let visual=currentVisualSupport[anchor.source.id]?.first(where:{$0.observationID==anchor.observationID && $0.value==anchor.quote}) {
                    if visualProof[anchor.source]?.contains(visual) != true{visualProof[anchor.source,default:[]].append(visual)}
                } else {diagnostic?("field.anchor");throw PinStoreError.staleImport}
            }
            let native=facts.filter{$0.field==(field.field=="date" ? "eventDate":field.field)}
            guard native.count==Set(proof.keys).union(visualProof.keys).count,Set(native.map(\.source))==Set(proof.keys).union(visualProof.keys) else{diagnostic?("native.factMembership");throw PinStoreError.staleImport}
            for fact in native {
                guard fact.origin != .external,fact.extractorVersion==field.extractorVersion,
                      fact.support.count == (proof[fact.source] ?? []).count && fact.support.allSatisfy({ (proof[fact.source] ?? []).contains($0) }),
                      (fact.visualSupport ?? []).count == (visualProof[fact.source] ?? []).count,
                      (fact.visualSupport ?? []).allSatisfy({(visualProof[fact.source] ?? []).contains($0)}),
                      fact.confidence == ((fact.visualSupport ?? []).isEmpty ? (fact.support.map(\.confidence).min() ?? 0):0),
                      fact.support.allSatisfy({$0.confidence.isFinite && (0...1).contains($0.confidence)}) else{diagnostic?("native.factProof");throw PinStoreError.staleImport}
                let expected:String?
                switch field.field {
                case "title":expected=obs.title
                case "provider":expected=obs.provider
                case "venue":expected=obs.venue
                case "performer":expected=obs.performer
                case "venueAddress":expected=obs.address
                case "bookingReference":expected=obs.bookingReference
                case "kind":expected=obs.eventTicket==true ? "eventTicket":"appointment"
                case "status":expected=obs.cancelled==true ? "cancelled":"scheduled"
                case "date":
                    guard let data=fact.value.data(using:.utf8),try JSONDecoder().decode(AppointmentDateComponents.self,from:data)==date else{diagnostic?("native.dateDTO");throw PinStoreError.staleImport}
                    expected=fact.value
                default:diagnostic?("native.unknownField");throw PinStoreError.staleImport
                }
                guard expected==fact.value else{diagnostic?("native.value");throw PinStoreError.staleImport}
                let literal = !["date","kind","status"].contains(field.field) && field.origin=="observed" &&
                    fact.support.contains{Data($0.text.utf8).range(of:Data(fact.value.utf8)) != nil}
                guard fact.origin == (literal ? .observed:.inferred) else{diagnostic?("native.origin");throw PinStoreError.staleImport}
            }
        }
        guard Self.currentDateBasis(obs,sources:draft.sources,fields:draft.support,visible:visible,captures:currentCaptureDates,screenshots:currentScreenshotKinds,allowOriginalPhoto:temporalAdmissionPolicy == .labelledOriginalCaptureV1)else{diagnostic?("date.captureBasis");throw PinStoreError.staleImport}
        if let basis=date.captureYearDerivation {
            guard date.certainty=="inferred",basis.policyVersion=="original-capture-year/1",currentCaptureDates[basis.source.id]==basis.originalCapturedAt,draft.sources.contains(AppointmentSource(basis.source)),
                  draft.support.first(where:{$0.field=="date"})?.origin=="inferred" else{diagnostic?("date.captureYearBasis");throw PinStoreError.staleImport}
        }
        let primary=draft.sources.first{$0.id==obs.sourceID}!
        var row=AppointmentItem(source:primary,observation:obs)
        row.canonicalRecordID=ticket.id;row.canonicalRevision=(ticket.expectedRevision ?? 0)+1
        row.additionalSources=draft.sources.filter{$0 != primary}.sorted{$0.id<$1.id}
        row.semanticSupport=draft.support;row.bookingLinkEvidence=draft.bookingLinkEvidence;row.readerVersion=AppointmentCardReader.version
        if let old=ticket.previous,old.allSources.allSatisfy({visible[$0.id]==$0}) {
            row.previousEvidence=AppointmentPreviousEvidence(revision:old.canonicalRevision ?? 1,source:old.source,additionalSources:old.additionalSources,observation:old.observation,semanticSupport:old.semanticSupport)
            let unchanged=old.hasSameEvidence(as:row)
            row.dismissed=unchanged && old.dismissed
            row.remindersApproved=unchanged && old.remindersApproved && obs.cancelled != true && obs.reviewReason==nil
        }
        var next=state;next.schema=3
        next.sourceRejections=next.sourceRejections?.filter{!draft.sources.contains($0.source)}
        next.pendingSemanticSources=next.pendingSemanticSources?.filter{!draft.sources.contains($0)}
        if let source=keepingSourcePending {next.pendingSemanticSources=Array(Set((next.pendingSemanticSources ?? [])+[source])).sorted{$0.id<$1.id}}
        next.items.removeAll{$0.canonicalRecordID==ticket.id || ($0.canonicalRecordID==nil && draft.sources.contains($0.source))}
        let covered=(next.canonicalSourceCoverage ?? [])+draft.sources+(ticket.previous?.allSources ?? [])+(ticket.previous?.previousEvidence?.sources ?? [])
        next.canonicalSourceCoverage=Array(Set(covered)).filter{visible[$0.id]==$0}.sorted{$0.id==$1.id ? $0.revision<$1.revision:$0.id<$1.id}
        next.items.append(row);next.canonicalRevisions=next.canonicalRevisions ?? [:];next.canonicalRevisions?[ticket.id]=row.canonicalRevision
        return (next,row)
    }

}
