import Foundation

/// A transient snapshot of application-owned authority. It is neither a grant
/// nor durable memory. Rebuild it after asynchronous I/O and before each view.
public struct AppointmentOriginalAuthority: Sendable {
    public let activeAnswerID: UUID?
    public let activeRequestID: UUID
    public let authorized: Bool
    public let accessReady: Bool
    public let foreground: Bool
    public let items: [AppointmentItem]
    public let originals: [PhotoMemory]
    public let nativeFingerprints: [String:String]
    public init(activeAnswerID: UUID?, activeRequestID: UUID, authorized: Bool,
                accessReady: Bool, foreground: Bool, items: [AppointmentItem],
                originals: [PhotoMemory], nativeFingerprints: [String:String]) {
        self.activeAnswerID=activeAnswerID; self.activeRequestID=activeRequestID
        self.authorized=authorized; self.accessReady=accessReady; self.foreground=foreground
        self.items=items; self.originals=originals; self.nativeFingerprints=nativeFingerprints
    }
}

/// Host-only presentation state for an already resolved event. This type does
/// not interpret language, validate a model receipt, select an event or open a
/// photo. The caller must first obtain a qualified typed original-view result
/// and independently validate its record/scope/answer binding. The native
/// source references here can only be that row's current/previous PRIMARY
/// originals. No model-authored PhotoKit identifier is an admission path.
///
/// No Codable/public initializer: a persisted or model-decoded queue cannot
/// become presentation authority. A new question/Home/Forget must replace the
/// host request ID. Warm return may retain it while renewing all other checks.
public struct AppointmentOriginalSequence: Sendable {
    public let sources: [AppointmentSource]
    public let position: Int
    public var currentSource: AppointmentSource { sources[position] }
    public var hasNext: Bool { position+1<sources.count }
    private let item: AppointmentItem
    private let answerID: UUID
    private let requestID: UUID
    private init(item: AppointmentItem, sources: [AppointmentSource], position: Int,
                 answerID: UUID, requestID: UUID) {
        self.item=item; self.sources=sources; self.position=position
        self.answerID=answerID; self.requestID=requestID
    }
    public static func bind(item: AppointmentItem, requestedSources: [AppointmentSource],
                            answerID: UUID, requestID: UUID,
                            authority: AppointmentOriginalAuthority) -> Self? {
        guard let id=item.canonicalRecordID, !id.isEmpty, item.id==id,
              let revision=item.canonicalRevision, revision>0,
              (1...2).contains(requestedSources.count),
              Set(requestedSources.map(\.id)).count==requestedSources.count else { return nil }
        let allowed=[item.source]+(item.previousEvidence.map{[$0.source]} ?? [])
        guard requestedSources.allSatisfy(allowed.contains) else { return nil }
        let plan=Self(item:item,sources:requestedSources,position:0,answerID:answerID,requestID:requestID)
        return plan.validatedMemory(in:authority)==nil ? nil:plan
    }
    public func validatedMemory(in authority: AppointmentOriginalAuthority) -> PhotoMemory? {
        guard authority.authorized, authority.accessReady, authority.foreground,
              authority.activeAnswerID==answerID, authority.activeRequestID==requestID else { return nil }
        let current=authority.items.filter{$0.id==item.id}
        guard current.count==1, let row=current.first, !row.dismissed,
              row.canonicalRecordID==item.canonicalRecordID,
              row.canonicalRevision==item.canonicalRevision,
              row.hasSameEvidence(as:item), row.previousEvidence==item.previousEvidence,
              Set(authority.originals.map(\.id)).count==authority.originals.count else { return nil }
        let memories=Dictionary(uniqueKeysWithValues:authority.originals.map{($0.id,$0)})
        // Revalidate every source supporting the event/history, including the
        // pending original, before showing either member of the sequence.
        let proof=Set(item.allSources+(item.previousEvidence?.sources ?? []))
        guard proof.allSatisfy({source in
            !source.id.isEmpty && !source.fingerprint.isEmpty && source.revision>0 &&
            memories[source.id].map{AppointmentSource($0)==source}==true &&
            authority.nativeFingerprints[source.id]==source.fingerprint
        }) else { return nil }
        return memories[currentSource.id]
    }
    public func advanced(in authority: AppointmentOriginalAuthority) -> Self? {
        guard hasNext, validatedMemory(in:authority) != nil else { return nil }
        return Self(item:item,sources:sources,position:position+1,answerID:answerID,requestID:requestID)
    }
}
