import Foundation
import PinCore
import IBrain
import IBrainSemantics
import IBrainRetrieval
import IBrainVision

private enum PinUnitProductMeaning {
    case legacy(CompiledProductQuestion)
    case compact(CompiledCompactProductQuestion)
    var route:String {
        switch self {
        case .legacy(let value):return value.route.rawValue
        case .compact(let value):return value.route.rawValue
        }
    }
}
private enum PinPreparedAnyUnitProductAnswer {
    case inventory(PinPreparedExhaustiveAnswer)
    case contextual(PinUnitContextualAnswer)
    case linked(PinLinkedUnitContextualAnswer)
    case unsupported
    func legacy()throws->PinPreparedUnitProductAnswer {
        switch self {
        case .inventory(let value):return .inventory(value)
        case .contextual(let value):return .contextual(value)
        case .unsupported:return .unsupported
        case .linked:throw PinEvidenceError.staleRecord
        }
    }
    func linked()throws->PinPreparedLinkedUnitProductAnswer {
        switch self {
        case .inventory(let value):return .inventory(value)
        case .linked(let value):return .contextual(value)
        case .unsupported:return .unsupported
        case .contextual:throw PinEvidenceError.staleRecord
        }
    }
}

public enum PinCompactQueryMeaningError:Error,Sendable {
    case clarify,unknown
}

/// Rebuildable local retrieval cache. Pin's existing appointment file owns truth.
public actor PinAppointmentProjectionCache {
    private let scope=MemoryScope(ownerID:"local-photo-owner",namespace:"pin-appointments-v1")
    private let session=UUID()
    private let cache:PinDerivedMemoryStore
    private let directory:URL
    private let sealedWorld:Bool
    private let processingScope:PinNativePhotoProcessingScope?
    private let sourceInventory:PinProjectionSourceInventory
    private let savedContentEnabled:Bool
    private var savedContentHistory:[SavedContentReplayPublication]=[]
    private var savedContentReplayProvider:(any PinSavedContentReplayProviding)?
    private var savedContentEngine:SavedContentQuestionSession?
    private var savedContentCatalog:SavedContentCatalog?
    private var savedContentSources:[String:PinCore.EvidenceSource]=[:]
    private var savedContentRequest:UUID?
    private var savedContentSettledRequest:UUID?
    private var savedContentEpoch=0
    private var savedContentDisplayedID:UUID?
    private var savedContentPublishedAnswerID:UUID?
    private var savedContentPublishedMembers:Set<String>=[]
    private var savedContentOriginalAnswerID:UUID?
    private var activeRetrievalRequest:UUID?
    private var retrievalGeneration=0
    private var interpretationGeneration=0
    private var retrievalAnswerGeneration=0
    private var publishedRetrievalAnswer:UUID?
    private var questionRows:[String:AppointmentItem]=[:]
    private var questionDismissedSources:Set<PinCore.EvidenceSource>=[]
    private var questionStamp:String?
    private var questionEvidenceDigest:String?
    private var questionSynchronizations=0
    private var questionSyncSerial=0
    private var displayedUnitContextID:UUID?
    private var activeUnitSubmission:UUID?
    private var unitSubmissionEpoch=0
    private var linkedUnitEngine:LinkedUnitQuestionSession?
    private var selectedUnitContinuationID:UUID?
    private var currentSelectedUnitContinuation:PinSelectedUnitContinuation?
    private var unitPublicationAttempt:UUID?
    public init(directory:URL,sealedWorld:Bool=false,sourceInventory:PinProjectionSourceInventory = .appointmentEvidence,processingScope:PinNativePhotoProcessingScope?=nil,savedContent:Bool=false)throws {
        guard !savedContent || (sealedWorld && sourceInventory == .permittedPhotoObservations) else{throw PinEvidenceError.staleRecord}
        self.savedContentEnabled=savedContent
        self.directory=directory;self.sealedWorld=sealedWorld;self.sourceInventory=sourceInventory;self.processingScope=processingScope
        cache=try PinDerivedMemoryStore(directory:directory,scope:scope)
    }
    @discardableResult public func synchronize(memories:[PhotoMemory],records:[AppointmentItem],recordingChangesFrom captures:[PinCapturedAppointmentRevision]=[],pendingSourcePreparations:Set<PinCore.EvidenceSource>=[],savedInterpretations:[SavedPhotoInterpretation]=[])async throws->Int {
        let memories=processingScope?.memories(memories) ?? memories
        let records=processingScope?.records(records) ?? records
        let captures=processingScope.map{scope in captures.filter{!scope.records([$0.native]).isEmpty}} ?? captures
        let present=Set(memories.map(EvidenceSource.init))
        let pendingSourcePreparations=processingScope == nil ? pendingSourcePreparations:pendingSourcePreparations.intersection(present)
        questionSynchronizations += 1;questionSyncSerial += 1
        let serial=questionSyncSerial;var succeeded=false
        defer{questionSynchronizations -= 1;if !succeeded,serial==questionSyncSerial{questionStamp=nil;questionRows=[:];questionDismissedSources=[];savedContentCatalog=nil;savedContentSources=[:]}}
        let canonical=records.filter{$0.canonicalRecordID != nil && !$0.dismissed}.sorted{$0.canonicalRecordID!<$1.canonicalRecordID!}
        guard captures.count<=canonical.count,Set(captures.map{ $0.native.canonicalRecordID! }).count==captures.count else{throw PinEvidenceError.staleRecord}
        for captured in captures {
            guard captured.session==session,let row=canonical.first(where:{$0.canonicalRecordID==captured.native.canonicalRecordID}),captured.matchesPrevious(of:row) else{throw PinEvidenceError.staleRecord}
        }
        let pins=try canonical.map(PinCanonicalMapping.pin)
        // This is the COMPLETE admitted-appointment scope, not a page of
        // the photo index. Fresh source interpretation has its own read grant.
        // Retained history stays readable for source-supported comparison.
        let required=Set(canonical.flatMap{$0.allSources+($0.previousEvidence?.sources ?? [])})
        let linked=memories.filter{required.contains(AppointmentSource($0))}
        guard Set(linked.map(AppointmentSource.init))==required,linked.count==required.count else{throw PinEvidenceError.staleRecord}
        // Explicit retrieval opt-in includes unlinked observations; it never
        // expands PhotoKit permission or represents unread iCloud originals.
        let selected=sourceInventory == .permittedPhotoObservations ? memories:linked
        let presentSources=Set(selected.map(EvidenceSource.init))
        let dismissedSources=Set(records.filter(\.dismissed).flatMap{$0.allSources+($0.previousEvidence?.sources ?? [])}.map{EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)}).intersection(presentSources).subtracting(required.map{EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)})
        let snapshot=try PinEvidenceSnapshot(memories:selected,records:pins,scope:scope,pendingSourcePreparations:pendingSourcePreparations.subtracting(dismissedSources))
        let projections=try canonical.map{try snapshot.bindEvidence(for:PinCanonicalMapping.projection($0,scope:scope)).projection}
        var world:[WorldMemoryProjection]=[]
        if sealedWorld {
            for projection in projections where projection.appointment.date.captureYearDerivation==nil {
                let a=projection.appointment,id=projection.recordID
                world += try AppointmentWorldCompiler.compile(projection,identities:AppointmentWorldIdentities(eventID:"pin.derived.event|"+id,venueID:a.venue==nil ? nil:"pin.derived.venue|"+id,performerID:a.performer==nil ? nil:"pin.derived.performer|"+id,revision:projection.recordRevision),policy:.typedTemporalValuesV2)
            }
            for source in snapshot.authority.sources {
                let id="pin.derived.document|"+source.reference.id
                if savedContentEnabled,source.observations.contains(where:{$0.kind == .text && !$0.value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) {
                    let native=savedInterpretations.filter{$0.source.id==source.reference.id}
                    guard native.count<=1 else{throw PinEvidenceError.staleRecord}
                    let correction=native.first
                    if let correction {
                        guard correction.source.fingerprint==source.reference.fingerprint,correction.source.revision==source.reference.revision,
                              correction.recordRevision>=source.reference.revision else{throw PinEvidenceError.staleRecord}
                    }
                    let projected=try SavedTextProjection.project(source,recordID:id,recordRevision:correction?.recordRevision ?? source.reference.revision)
                    var claims=projected.claims
                    if let text=correction?.correction {
                        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf8.count<=12_000,claims.count<256,
                              let anchor=claims.first?.anchors.first else{throw PinEvidenceError.staleRecord}
                        claims.append(.init(id:"native-saved-correction",predicate:.description,value:.text(text),origin:.domainCorrection,
                                            anchors:[anchor],extractorVersion:"pin-native-saved-correction-v1"))
                    }
                    world.append(.init(recordID:projected.recordID,recordRevision:projected.recordRevision,scope:projected.scope,kind:projected.kind,claims:claims))
                }else if !savedContentEnabled || !source.observations.isEmpty {
                    // Empty saved-photo evidence has no document claims to compile.
                    // Keep its source and expected record in the complete catalog;
                    // SavedContentCoverage reports the missing projection explicitly.
                    world.append(try WorldObservationCompiler.document(source:source,recordID:id,recordRevision:source.reference.revision,extractorVersion:"pin-native-observations-v1"))
                }
            }
        }
        let authority=AuthoritySnapshot(sources:snapshot.authority.sources,records:snapshot.authority.records+world.map{DomainRecordPin(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources,recordKind:.worldEntity)},pendingSourcePreparations:snapshot.authority.pendingSourcePreparations)
        let permit=try await cache.synchronize(authority)
        let report=try await cache.rebuild(from:projections,permit:permit)
        if sealedWorld{_=try await cache.rebuildWorld(from:world,permit:try await cache.permit())}
        for captured in captures {
            guard serial==questionSyncSerial else{throw PinEvidenceError.staleRecord}
            let currentPermit=try await cache.permit(),existing=try await cache.sourceChangeSnapshot(permit:currentPermit)
            let id=captured.native.canonicalRecordID!,old=try PinCanonicalMapping.projection(captured.native,scope:scope)
            guard let projection=projections.first(where:{$0.recordID==id})else{throw PinEvidenceError.staleRecord}
            if !existing.contains(where:{$0.previous==old && $0.current==projection}) {
                _=try await cache.recordSourceChange(from:captured.sdk,recordID:id,permit:currentPermit)
            }
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let history=Dictionary(uniqueKeysWithValues:canonical.compactMap{row in row.previousEvidence.map{(row.canonicalRecordID!,$0)}})
        let historyDigest=ChoiceTask.hash(try encoder.encode(history))
        let dismissalDigest=sourceInventory == .permittedPhotoObservations ? "|"+ChoiceTask.hash(try encoder.encode(dismissedSources.sorted{$0.id<$1.id})):""
        let savedDigest=savedContentEnabled ? "|"+ChoiceTask.hash(try encoder.encode(world)):""
        let evidenceDigest=snapshot.authorityDigest+"|"+ChoiceTask.hash(try encoder.encode(projections))+"|"+historyDigest+dismissalDigest+savedDigest
        guard serial==questionSyncSerial else{throw PinEvidenceError.staleRecord}
        // A changed authority must not revive old displayed references when
        // the same photo and records later become available again.
        if questionStamp == nil || questionEvidenceDigest != evidenceDigest {
            questionStamp=UUID().uuidString
            questionEvidenceDigest=evidenceDigest
        }
        questionRows=Dictionary(uniqueKeysWithValues:canonical.map{($0.canonicalRecordID!,$0)})
        questionDismissedSources=dismissedSources
        if savedContentEnabled {
            savedContentCatalog=SavedContentCatalog(id:"pin-permitted-saved-content-v1",sourceIDs:Set(selected.map(\.id)),recordIDs:Set(selected.map{"pin.derived.document|"+$0.id}))
            savedContentSources=Dictionary(uniqueKeysWithValues:selected.map{($0.id,PinCore.EvidenceSource($0))})
        }
        succeeded=true
        return report.rows.count
    }
    /// Capture while Pin's prior native row is STILL current, before its CAS.
    /// No token can be reconstructed from saved history after a cold rebuild.
    public func captureCurrentRevision(_ native:AppointmentItem)async throws->PinCapturedAppointmentRevision {
        guard questionSynchronizations==0,let stamp=questionStamp,let id=native.canonicalRecordID,
              let row=questionRows[id],row.hasSameEvidence(as:native),row.canonicalRevision==native.canonicalRevision,row.previousEvidence==native.previousEvidence else{throw PinEvidenceError.staleRecord}
        let permit=try await cache.permit(),snapshot=try await cache.recordSearchSnapshot(permit:permit)
        guard let stored=snapshot.records.first(where:{$0.projection.recordID==id}),stored.projection == (try PinCanonicalMapping.projection(native,scope:scope))else{throw PinEvidenceError.staleRecord}
        let captured=try await cache.captureRevision(recordID:id,permit:permit)
        guard questionSynchronizations==0,stamp==questionStamp else{throw PinEvidenceError.staleRecord}
        return PinCapturedAppointmentRevision(session:session,native:native,sdk:captured)
    }
    /// Context is returned to the presenter, never automatically made current.
    /// The host passes only the context it actually published with its answer.
    public func inspectQuestionRecord(_ recordID:String,in context:PinRecordQuestionContext,answerID:UUID)async throws->PinRecordQuestionContext {
        guard questionSynchronizations==0,let stamp=questionStamp,stamp==context.stamp,questionRows[recordID] != nil else{throw PinEvidenceError.staleRecord}
        let selected=try await EvidenceQuestionHostInspection.selecting(recordID:recordID,in:context.sdk,activeAnswerID:answerID,store:cache)
        guard questionSynchronizations==0,stamp==questionStamp else{throw PinEvidenceError.staleRecord}
        return PinRecordQuestionContext(sdk:selected,stamp:stamp)
    }
    public func question(_ question:String,now:Date,calendar:Calendar,previous:PinRecordQuestionContext?=nil,policy:EvidenceQuestionPolicy = .completeV3,inferredDatePolicy:InferredDatePolicy = .explicitOnly,temporalScopePolicy:EvidenceTemporalScopePolicy = .legacy,provider:any DecisionProvider)async throws->PinRecordQuestionAnswer {
        guard questionSynchronizations==0,let stamp=questionStamp,previous.map({$0.stamp==stamp}) ?? true else{throw PinEvidenceError.staleRecord}
        let rows=questionRows,permit=try await cache.permit()
        guard questionSynchronizations==0,stamp==questionStamp else{throw PinEvidenceError.staleRecord}
        let retained=try await cache.sourceChangeSnapshot(permit:permit)
        for change in retained {
            guard let row=rows[change.recordID],change.current == (try PinCanonicalMapping.projection(row,scope:scope)),
                  let old=PinCapturedAppointmentRevision.previousRow(of:row),change.previous == (try PinCanonicalMapping.projection(old,scope:scope))else{throw PinEvidenceError.staleRecord}
        }
        let input=EvidenceQuestionInput(taskID:"pin-current-question",question:question,now:now,calendar:calendar,previous:previous?.sdk,activeContextID:previous?.sdk.answerID,policy:policy,inferredDatePolicy:inferredDatePolicy,temporalScopePolicy:temporalScopePolicy)
        let answer=try await EvidenceQuestionSession.answer(input,provider:provider,store:cache)
        try await cache.validate(permit)
        guard questionSynchronizations==0,stamp==questionStamp else{throw PinEvidenceError.staleRecord}
        return try nativeAnswer(answer,stamp:stamp,rows:rows)
    }
    private func nativeAnswer(_ answer:EvidenceQuestionAnswer,stamp:String,rows:[String:AppointmentItem],contextOverride:EvidenceQuestionContext?=nil)throws->PinRecordQuestionAnswer {
        func bound(_ stored:StoredMemory)throws->AppointmentItem {
            guard let native=rows[stored.projection.recordID],try PinCanonicalMapping.projection(native,scope:scope)==stored.projection else{throw PinEvidenceError.staleRecord}
            return native
        }
        let matched=try answer.matched.map(bound),unresolved=try answer.unresolved.map(bound)
        let sdkContext=contextOverride ?? answer.context
        let contextRows=try (sdkContext?.orderedRecordIDs ?? []).map{id->AppointmentItem in guard let row=rows[id]else{throw PinEvidenceError.staleRecord};return row}
        let context=sdkContext.map{PinRecordQuestionContext(sdk:$0,stamp:stamp)}
        let originalView:PinOriginalViewRequest?
        if let request=answer.originalViewRequest {
            let targets=matched.filter{$0.canonicalRecordID==request.recordID}
            guard let context,targets.count==1,answer.originalViewIssue==nil else{throw PinEvidenceError.staleRecord}
            originalView=try PinOriginalViewRequest(validating:request,item:targets[0],scope:scope,context:context)
        }else{originalView=nil}
        return PinRecordQuestionAnswer(originalViewRequest:originalView,originalViewIssue:answer.originalViewIssue,route:answer.route,matched:matched,unresolved:unresolved,unresolvedDetails:answer.unresolvedDetails,location:answer.location,comparison:answer.comparison,changeExplanations:answer.changeExplanations,clarification:answer.clarification,context:context,ordered:contextRows,receipt:answer.receipt)
    }
    /// Caller-owned cancellation also invalidates already-computed handles.
    public func cancelRetrievedQuestion() {
        interpretationGeneration += 1
        invalidateRetrievedAnswer()
    }
    /// A delayed host withdrawal for an older request cannot cancel its successor.
    public func cancelRetrievedQuestion(ifActiveRequestID requestID:UUID) {
        if let activeUnitSubmission {
            guard activeUnitSubmission==requestID else{return}
            cancelUnitSubmission(ifActiveRequestID:requestID);return
        }
        guard activeRetrievalRequest==requestID else{return}
        cancelRetrievedQuestion()
    }
    /// A contextual submission is newer than its displayed answer. Cancelling
    /// it revokes only that submission; the same parent can remain displayed.
    /// A delayed cancellation for an older submission cannot revoke a successor.
    public func cancelUnitSubmission(ifActiveRequestID requestID:UUID) {
        guard activeUnitSubmission==requestID else{return}
        if activeRetrievalRequest==requestID{cancelRetrievedQuestion()}
        else{activeUnitSubmission=nil;unitSubmissionEpoch += 1}
    }
    private func invalidateRetrievedAnswer() {
        savedContentReplayProvider?.invalidate(requestID:savedContentRequest);savedContentHistory=[]
        savedContentRequest=nil;savedContentSettledRequest=nil;savedContentEpoch += 1;savedContentDisplayedID=nil;savedContentPublishedAnswerID=nil;savedContentPublishedMembers=[];savedContentOriginalAnswerID=nil;savedContentEngine=nil
        activeRetrievalRequest=nil;retrievalGeneration += 1
        retrievalAnswerGeneration += 1;publishedRetrievalAnswer=nil
        displayedUnitContextID=nil;linkedUnitEngine=nil;selectedUnitContinuationID=nil;currentSelectedUnitContinuation=nil;activeUnitSubmission=nil;unitSubmissionEpoch += 1;unitPublicationAttempt=nil
    }
    /// Call before a host-controlled source-observation write. Until current
    /// native stores are synchronized again, no old ordinary or retrieved
    /// question context may be admitted through this cache.
    public func invalidateQuestionEvidence() {
        invalidateRetrievedAnswer();questionStamp=nil;questionRows=[:];questionDismissedSources=[];savedContentCatalog=nil;savedContentSources=[:]
    }
    public func prepareRetrievedQuestion(_ question:String,requestID:UUID,strategy:SourceSearchStrategy = .hybrid,candidateLimit:Int=12,encoder:(any TextEncoder)?=nil,relevanceProvider:any DecisionProvider)async throws->PinPreparedRetrievedQuestion {
        try Task.checkCancellation()
        guard sourceInventory == .permittedPhotoObservations,questionSynchronizations==0,let stamp=questionStamp else{throw PinEvidenceError.staleRecord}
        cancelRetrievedQuestion();activeRetrievalRequest=requestID
        let generation=retrievalGeneration
        let engine=AppointmentRetrievalSession(store:cache,encoder:encoder,relevanceProvider:PinCancellableDecisionProvider(base:relevanceProvider))
        let sdk=try await engine.prepare(query:question,requestID:requestID,strategy:strategy,candidateLimit:candidateLimit)
        let result=PinPreparedRetrievedQuestion(requestID:requestID,owner:session,stamp:stamp,generation:generation,engine:engine,sdk:sdk,dismissedSources:questionDismissedSources)
        try validateRetrievedQuestion(result,activeRequestID:requestID)
        return result
    }
    public func answerRetrievedQuestion(_ prepared:PinPreparedRetrievedQuestion,activeRequestID:UUID,now:Date,calendar:Calendar,inferredDatePolicy:InferredDatePolicy = .explicitOnly,provider:any DecisionProvider)async throws->PinPreparedRetrievedAnswer {
        try validateRetrievedQuestion(prepared,activeRequestID:activeRequestID)
        retrievalAnswerGeneration += 1
        let generation=retrievalAnswerGeneration
        let sdk=try await prepared.engine.answer(prepared.sdk,activeRequestID:activeRequestID,taskID:"pin-retrieved-question",now:now,calendar:calendar,provider:PinCancellableDecisionProvider(base:provider),inferredDatePolicy:inferredDatePolicy)
        try validateRetrievedQuestion(prepared,activeRequestID:activeRequestID)
        guard generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        return PinPreparedRetrievedAnswer(prepared:prepared,sdk:sdk,generation:generation,identity:UUID())
    }
    public func followupRetrievedQuestion(_ question:String,previous:PinRetrievedQuestionAnswer,activeRequestID:UUID,now:Date,calendar:Calendar,inferredDatePolicy:InferredDatePolicy = .explicitOnly,provider:any DecisionProvider)async throws->PinPreparedRetrievedAnswer {
        let prior=previous.prepared,prepared=prior.prepared
        try validateRetrievedQuestion(prepared,activeRequestID:activeRequestID)
        guard publishedRetrievalAnswer==prior.identity else{throw PinEvidenceError.staleRecord}
        retrievalAnswerGeneration += 1
        let generation=retrievalAnswerGeneration
        let sdk=try await prepared.engine.followup(prior.sdk,activeRequestID:activeRequestID,taskID:"pin-retrieved-question",question:question,now:now,calendar:calendar,provider:PinCancellableDecisionProvider(base:provider),inferredDatePolicy:inferredDatePolicy)
        try validateRetrievedQuestion(prepared,activeRequestID:activeRequestID)
        guard generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        return PinPreparedRetrievedAnswer(prepared:prepared,sdk:sdk,generation:generation,identity:UUID())
    }
    public func inspectRetrievedQuestionRecord(_ item:AppointmentItem,in previous:PinRetrievedQuestionAnswer,activeRequestID:UUID)async throws->PinRetrievedQuestionAnswer {
        let prior=previous.prepared,prepared=prior.prepared
        try validateRetrievedQuestion(prepared,activeRequestID:activeRequestID)
        guard publishedRetrievalAnswer==prior.identity,
              let id=item.canonicalRecordID,let native=questionRows[id],native.hasSameEvidence(as:item),
              native.canonicalRevision==item.canonicalRevision,native.previousEvidence==item.previousEvidence else{throw PinEvidenceError.staleRecord}
        retrievalAnswerGeneration += 1
        let generation=retrievalAnswerGeneration
        let sdk=try await prepared.engine.selecting(recordID:id,in:prior.sdk,activeRequestID:activeRequestID)
        try validateRetrievedQuestion(prepared,activeRequestID:activeRequestID)
        guard generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        return try await admitRetrievedQuestion(PinPreparedRetrievedAnswer(prepared:prepared,sdk:sdk,generation:generation,identity:UUID()),activeRequestID:activeRequestID)
    }
    /// Perform the host's foreground/access checks immediately before this
    /// call, and its display-request check again after await. No SDK await can
    /// serialize a SwiftUI owner turn on the host's behalf.
    public func admitRetrievedQuestion(_ pending:PinPreparedRetrievedAnswer,activeRequestID:UUID)async throws->PinRetrievedQuestionAnswer {
        let prepared=pending.prepared
        try validateRetrievedQuestion(prepared,activeRequestID:activeRequestID)
        guard pending.generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        _=try await prepared.engine.admit(pending.sdk,activeRequestID:activeRequestID)
        try validateRetrievedQuestion(prepared,activeRequestID:activeRequestID)
        guard pending.generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        let answer=try pending.sdk.answer.map{try nativeAnswer($0,stamp:prepared.stamp,rows:questionRows,contextOverride:pending.sdk.context)}
        publishedRetrievalAnswer=pending.identity
        return PinRetrievedQuestionAnswer(requestID:activeRequestID,answer:answer,coverage:PinRetrievalCoverage(prepared.sdk,dismissedSources:prepared.dismissedSources),stage:PinRetrievalStage(prepared.sdk,dismissedSources:prepared.dismissedSources),prepared:pending)
    }
    private func validateRetrievedQuestion(_ prepared:PinPreparedRetrievedQuestion,activeRequestID:UUID)throws {
        try Task.checkCancellation()
        guard prepared.owner==session,sourceInventory == .permittedPhotoObservations,
              questionSynchronizations==0,prepared.stamp==questionStamp,
              prepared.requestID==activeRequestID,activeRetrievalRequest==activeRequestID,
              prepared.generation==retrievalGeneration else{throw PinEvidenceError.staleRecord}
    }
    /// Explicit exhaustive operation: one typed plan over every admitted
    /// record. The ordinary question route does not enable this implicitly.
    public func productQuestionAuthority(memories:[PhotoMemory],records:[AppointmentItem],originalSHA256BySourceID:[String:String])async throws->PinProductQuestionAuthority {
        let memories=processingScope?.memories(memories) ?? memories
        let records=processingScope?.records(records) ?? records
        guard sourceInventory == .permittedPhotoObservations,questionSynchronizations==0,let stamp=questionStamp,
              Set(memories.map(\.id))==Set(originalSHA256BySourceID.keys) else{throw PinEvidenceError.staleRecord}
        let canonical=records.filter{$0.canonicalRecordID != nil && !$0.dismissed}
        guard canonical.count==questionRows.count,canonical.allSatisfy({row in questionRows[row.canonicalRecordID!].map{$0.hasSameEvidence(as:row) && $0.canonicalRevision==row.canonicalRevision && $0.previousEvidence==row.previousEvidence} ?? false})else{throw PinEvidenceError.staleRecord}
        let permit=try await cache.permit(),bytes=try Data(contentsOf:directory.appendingPathComponent("memory.json"))
        guard !bytes.isEmpty,bytes.count<=262144 else{throw PinDevelopmentError.oversized}
        try await cache.validate(permit)
        guard questionSynchronizations==0,questionStamp==stamp else{throw PinEvidenceError.staleRecord}
        return PinProductQuestionAuthority(memories:memories,records:records,sdkMemory:bytes,originalSHA256BySourceID:originalSHA256BySourceID,sealedWorld:sealedWorld)
    }
    public func captureProductAuthoritySnapshot(memories:[PhotoMemory],records:[AppointmentItem],originalSHA256BySourceID:[String:String])async throws->PinProductAuthoritySnapshot {
        guard questionSynchronizations==0,let stamp=questionStamp else{throw PinEvidenceError.staleRecord}
        let authority=try await productQuestionAuthority(memories:memories,records:records,originalSHA256BySourceID:originalSHA256BySourceID)
        guard questionSynchronizations==0,stamp==questionStamp else{throw PinEvidenceError.staleRecord}
        return PinProductAuthoritySnapshot(authority:authority,owner:session,stamp:stamp)
    }
    public func mintProductReconciliation(initial:PinProductAuthoritySnapshot,current:PinProductAuthoritySnapshot,interpretation:PinCapturedExhaustiveInterpretation,answer:PinExhaustiveQuestionAnswer)async throws->PinProductReconciliation {
        let admitted=try await readmitExhaustiveAnswer(answer)
        guard initial.owner==session,current.owner==session,interpretation.owner==session,
              interpretation.generation==interpretationGeneration,interpretation.requestID==answer.requestID,
              interpretation.originalStamp==initial.stamp,current.stamp==questionStamp,
              current.stamp==admitted.pending.question.stamp,initial.stamp != current.stamp,
              interpretation.originalReceiptSHA256==answer.receipt.requestSHA256,
              initial.authority.originalSHA256BySourceID==current.authority.originalSHA256BySourceID,
              initial.authority.sealedWorld==current.authority.sealedWorld else{throw PinEvidenceError.staleRecord}
        let before=Dictionary(uniqueKeysWithValues:initial.authority.memories.map{($0.id,$0)})
        guard before.count==initial.authority.memories.count,Set(before.keys)==Set(current.authority.memories.map(\.id)) else{throw PinEvidenceError.staleRecord}
        var changed:Set<PinCore.EvidenceSource>=[]
        for memory in current.authority.memories {
            guard let old=before[memory.id] else{throw PinEvidenceError.staleRecord}
            if old==memory{continue}
            var metadata=memory;metadata.text=old.text;metadata.textEvidence=old.textEvidence;metadata.visualReading=old.visualReading;metadata.revision=old.revision
            guard metadata==old,old.revision<Int.max,memory.revision==old.revision+1 else{throw PinEvidenceError.staleRecord}
            changed.insert(EvidenceSource(old))
        }
        guard (1...2).contains(changed.count),changed.isSubset(of:interpretation.missingSources)else{throw PinEvidenceError.staleRecord}
        return PinProductReconciliation(questionRequestID:answer.requestID,originalAuthoritySHA256:try initial.authority.canonicalDigest(),publishedAuthoritySHA256:try current.authority.canonicalDigest())
    }
    public func mintProductReconciliation(initial:PinProductAuthoritySnapshot,current:PinProductAuthoritySnapshot,interpretation:PinCapturedExhaustiveInterpretation,answer:PinUnitQuestionAnswer)async throws->PinProductReconciliation {
        let epoch=unitSubmissionEpoch
        guard activeUnitSubmission.map({$0==answer.requestID}) ?? true else{throw PinEvidenceError.staleRecord}
        let admitted=try await readmitUnitQuestion(answer)
        let flat=try await admitExhaustiveQuestion(admitted.pending,activeRequestID:answer.requestID)
        _=try await mintProductReconciliation(initial:initial,current:current,interpretation:interpretation,answer:flat)
        _=try await readmitUnitQuestion(admitted)
        guard epoch==unitSubmissionEpoch,activeUnitSubmission.map({$0==answer.requestID}) ?? true else{throw PinEvidenceError.staleRecord}
        return PinProductReconciliation(questionRequestID:answer.requestID,originalAuthoritySHA256:try initial.authority.unitReconciliationDigest(),publishedAuthoritySHA256:try current.authority.unitReconciliationDigest())
    }
    public func prepareProductQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,previous:PinRecordQuestionContext?,provider:any DecisionProvider)async throws->PinPreparedProductAnswer {
        try Task.checkCancellation()
        guard sourceInventory == .permittedPhotoObservations,questionSynchronizations==0,let stamp=questionStamp,
              previous.map({$0.stamp==stamp}) ?? true else{throw PinEvidenceError.staleRecord}
        cancelRetrievedQuestion();activeRetrievalRequest=requestID
        let generation=retrievalAnswerGeneration,permit=try await cache.permit(),rows=questionRows
        let inventoryInput=EvidenceQuestionInput(taskID:"pin-exhaustive-question",question:question,now:now,calendar:calendar,policy:.completeV9,inferredDatePolicy:.labelledTemporalContext)
        let inventory=try ExhaustiveAppointmentPlanner.task(inventoryInput,policy:.composedOutputV3)
        let contextualInput=EvidenceQuestionInput(taskID:"pin-current-question",question:question,now:now,calendar:calendar,previous:previous?.sdk,activeContextID:previous?.answerID,policy:.completeV9,inferredDatePolicy:.labelledTemporalContext,temporalScopePolicy:.inventoryVsEventTimeV1,clarificationPolicy:.reasonV1)
        var contextual:ChoiceTask?
        if rows.count<=256 {
            let snapshot=try await cache.recordSearchSnapshot(permit:permit,maximumRecords:256)
            let changes=try await cache.sourceChangeSnapshot(permit:permit).filter{change in snapshot.records.contains{$0.projection.recordID==change.recordID}}
            for change in changes {
                guard let row=rows[change.recordID],change.current == (try PinCanonicalMapping.projection(row,scope:scope)),
                      let old=PinCapturedAppointmentRevision.previousRow(of:row),change.previous == (try PinCanonicalMapping.projection(old,scope:scope))else{throw PinEvidenceError.staleRecord}
            }
            let world=try await cache.queryWorld(WorldMemoryQuery(kind:.event,constraints:[WorldConstraint(predicate:.status,value:.text("scheduled"))],requested:[.name,.status,.scheduledAt,.category]),requestID:UUID(),permit:permit,maximumEntities:4096)
            let gaps=world.unresolved.filter{item in item.fields.contains{$0.predicate == .status && $0.state != .known} && item.fields.contains{$0.predicate == .category && $0.claims.contains{$0.value == .text("appointment") || $0.value == .text("eventTicket")}}}
            contextual=try EvidenceQuestionSession.task(contextualInput,snapshot:snapshot,changes:changes,authorityGaps:gaps)
        }
        try await cache.validate(permit)
        let prepared=try ProductQuestionPlanner.prepare(taskID:"pin-product-question",inventory:inventory,contextual:contextual,permit:permit)
        let receipt=try await PinCancellableDecisionProvider(base:provider).decide(prepared.task)
        try await cache.validate(permit)
        guard questionSynchronizations==0,stamp==questionStamp,generation==retrievalAnswerGeneration,activeRetrievalRequest==requestID else{throw PinEvidenceError.staleRecord}
        let decision=try ProductQuestionPlanner.compile(receipt,for:prepared)
        switch decision.route {
        case .inventory:
            let handle=PinPreparedExhaustiveQuestion(requestID:requestID,owner:session,stamp:stamp,generation:retrievalGeneration,engine:ExhaustiveAppointmentSession(store:cache),dismissedSources:questionDismissedSources)
            let answer=try await handle.engine.prepare(inventoryInput,requestID:requestID,productDecision:decision,planningPolicy:.composedOutputV3)
            try validateExhaustiveQuestion(handle,activeRequestID:requestID)
            guard generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
            return .inventory(PinPreparedExhaustiveAnswer(question:handle,sdk:answer,generation:generation))
        case .contextual:
            let answer=try await EvidenceQuestionSession.answer(contextualInput,productDecision:decision,store:cache)
            try await cache.validate(permit)
            guard questionSynchronizations==0,stamp==questionStamp,generation==retrievalAnswerGeneration,activeRetrievalRequest==requestID else{throw PinEvidenceError.staleRecord}
            return .contextual(try nativeAnswer(answer,stamp:stamp,rows:rows))
        case .unsupported:return .unsupported
        }
    }
    /// Call after this exact answer has been assigned to the native presenter.
    /// A count or list supplies the complete visible order, never a guessed parent.
    public func contextForDisplayedProductAnswer(_ answer:PinExhaustiveQuestionAnswer)async throws->PinRecordQuestionContext {
        let current=try await readmitExhaustiveAnswer(answer),pending=current.pending
        let ids=(current.displayRows+current.uncertain).compactMap(\.canonicalRecordID)
        guard ids.count==current.displayRows.count+current.uncertain.count else{throw PinEvidenceError.staleRecord}
        let context=try await pending.question.engine.contextForDisplayedAnswer(pending.sdk,activeRequestID:answer.requestID,displayedRecordIDs:ids)
        try validateExhaustiveQuestion(pending.question,activeRequestID:answer.requestID)
        return PinRecordQuestionContext(sdk:context,stamp:pending.question.stamp)
    }
    public func prepareExhaustiveQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,inferredDatePolicy:InferredDatePolicy = .explicitOnly,provider:any DecisionProvider,planningPolicy:ExhaustivePlanningPolicy = .inventoryV1)async throws->PinPreparedExhaustiveAnswer {
        try Task.checkCancellation()
        guard sourceInventory == .permittedPhotoObservations,questionSynchronizations==0,let stamp=questionStamp else{throw PinEvidenceError.staleRecord}
        cancelRetrievedQuestion();activeRetrievalRequest=requestID
        let handle=PinPreparedExhaustiveQuestion(requestID:requestID,owner:session,stamp:stamp,generation:retrievalGeneration,engine:ExhaustiveAppointmentSession(store:cache),dismissedSources:questionDismissedSources)
        let generation=retrievalAnswerGeneration
        let input=EvidenceQuestionInput(taskID:"pin-exhaustive-question",question:question,now:now,calendar:calendar,policy:.completeV9,inferredDatePolicy:inferredDatePolicy)
        let answer=try await handle.engine.prepare(input,requestID:requestID,provider:PinCancellableDecisionProvider(base:provider),planningPolicy:planningPolicy)
        try validateExhaustiveQuestion(handle,activeRequestID:requestID)
        guard generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        return PinPreparedExhaustiveAnswer(question:handle,sdk:answer,generation:generation)
    }
    public func captureExhaustiveInterpretation(_ answer:PinExhaustiveQuestionAnswer,activeRequestID:UUID)async throws->PinCapturedExhaustiveInterpretation {
        let current=try await admitExhaustiveQuestion(answer.pending,activeRequestID:activeRequestID)
        return PinCapturedExhaustiveInterpretation(owner:session,requestID:activeRequestID,generation:interpretationGeneration,sdk:current.pending.sdk.interpretation,originalStamp:current.pending.question.stamp,originalReceiptSHA256:current.receipt.requestSHA256,missingSources:Set(current.missingEvidence.map(\.source)))
    }
    public func captureExhaustiveInterpretation(_ plan:PinUnitRereadPlan,activeRequestID:UUID)async throws->PinCapturedExhaustiveInterpretation {
        let(_,current)=try await readmitUnitRereadPlan(plan,activeRequestID:activeRequestID)
        return PinCapturedExhaustiveInterpretation(owner:session,requestID:activeRequestID,generation:interpretationGeneration,sdk:current.pending.sdk.interpretation,originalStamp:current.pending.question.stamp,originalReceiptSHA256:current.receipt.requestSHA256,missingSources:Set(plan.targets.map(\.source)))
    }
    /// After native evidence CAS, create fresh query/answer authority while
    /// retaining the exact submitted meaning. The SDK verifies all input context.
    public func prepareExhaustiveQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,inferredDatePolicy:InferredDatePolicy = .explicitOnly,interpretation:PinCapturedExhaustiveInterpretation)async throws->PinPreparedExhaustiveAnswer {
        try Task.checkCancellation()
        guard sourceInventory == .permittedPhotoObservations,questionSynchronizations==0,let stamp=questionStamp,
              interpretation.owner==session,interpretation.requestID==requestID,interpretation.generation==interpretationGeneration else{throw PinEvidenceError.staleRecord}
        invalidateRetrievedAnswer();activeRetrievalRequest=requestID
        let handle=PinPreparedExhaustiveQuestion(requestID:requestID,owner:session,stamp:stamp,generation:retrievalGeneration,engine:ExhaustiveAppointmentSession(store:cache),dismissedSources:questionDismissedSources)
        let generation=retrievalAnswerGeneration
        let input=EvidenceQuestionInput(taskID:"pin-exhaustive-question",question:question,now:now,calendar:calendar,policy:.completeV9,inferredDatePolicy:inferredDatePolicy)
        let answer=try await handle.engine.prepare(input,requestID:requestID,interpretation:interpretation.sdk)
        try validateExhaustiveQuestion(handle,activeRequestID:requestID)
        guard generation==retrievalAnswerGeneration,interpretation.generation==interpretationGeneration else{throw PinEvidenceError.staleRecord}
        return PinPreparedExhaustiveAnswer(question:handle,sdk:answer,generation:generation)
    }
    /// A work budget, not a result cap. No interpretation occurs per page.
    public func advanceExhaustiveQuestion(_ question:PinPreparedExhaustiveQuestion,activeRequestID:UUID,maximumRecords:Int=256)async throws->PinPreparedExhaustiveAnswer {
        try validateExhaustiveQuestion(question,activeRequestID:activeRequestID)
        retrievalAnswerGeneration += 1;let generation=retrievalAnswerGeneration
        let answer=try await question.engine.advance(activeRequestID:activeRequestID,maximumRecords:maximumRecords)
        try validateExhaustiveQuestion(question,activeRequestID:activeRequestID)
        guard generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        return PinPreparedExhaustiveAnswer(question:question,sdk:answer,generation:generation)
    }
    /// Recover the completed page checkpoint after cancellation without
    /// interpreting the question again or redispatching the provider.
    public func currentExhaustiveQuestion(_ question:PinPreparedExhaustiveQuestion,activeRequestID:UUID)async throws->PinPreparedExhaustiveAnswer {
        try validateExhaustiveQuestion(question,activeRequestID:activeRequestID)
        retrievalAnswerGeneration += 1;let generation=retrievalAnswerGeneration
        let answer=try await question.engine.current(activeRequestID:activeRequestID)
        try validateExhaustiveQuestion(question,activeRequestID:activeRequestID)
        guard generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        return PinPreparedExhaustiveAnswer(question:question,sdk:answer,generation:generation)
    }
    /// Host foreground/access/request checks must surround this await, just
    /// as they do candidate-answer publication and native original opening.
    public func admitExhaustiveQuestion(_ pending:PinPreparedExhaustiveAnswer,activeRequestID:UUID)async throws->PinExhaustiveQuestionAnswer {
        let handle=pending.question
        try validateExhaustiveQuestion(handle,activeRequestID:activeRequestID)
        guard pending.generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        let sdk=try await handle.engine.admit(pending.sdk,activeRequestID:activeRequestID)
        try validateExhaustiveQuestion(handle,activeRequestID:activeRequestID)
        guard pending.generation==retrievalAnswerGeneration else{throw PinEvidenceError.staleRecord}
        func rows(_ stored:[StoredMemory])throws->[AppointmentItem] {
            try stored.map { value in
                guard let native=questionRows[value.projection.recordID],try PinCanonicalMapping.projection(native,scope:scope)==value.projection else{throw PinEvidenceError.staleRecord}
                return native
            }
        }
        let targets=sdk.rereadTargets.map { target in
            PinMissingQuestionEvidence(source:.init(id:target.source.id,fingerprint:target.source.fingerprint,revision:target.source.revision),recordIDs:target.recordIDs,fields:Set(target.fields.map(\.rawValue)),reasons:Set(target.reasons.map(\.rawValue)))
        }
        let dismissed=targets.filter{handle.dismissedSources.contains($0.source)}
        return PinExhaustiveQuestionAnswer(requestID:activeRequestID,operation:sdk.plan.operation.rawValue,matches:try rows(sdk.matches),uncertain:try rows(sdk.uncertain),extremeRecords:try sdk.extremeRecords.map(rows),unresolvedDetails:sdk.unresolvedDetails.mapValues{Set($0.map(\.rawValue))},missingEvidence:targets.filter{!handle.dismissedSources.contains($0.source)},coverage:PinExhaustiveQuestionCoverage(sdk.coverage,dismissed:dismissed.count),admittedCountLowerBound:sdk.admittedCountLowerBound,admittedCountUpperBound:sdk.admittedCountUpperBound,exactAdmittedCount:sdk.exactAdmittedCount,canAssertNoMatchInAdmittedRecords:sdk.canAssertNoMatchInAdmittedRecords,requestedAnswerComplete:sdk.requestedAnswerComplete,sourceStatusEvidence:sdk.sourceStatusEvidence.map(PinSourceStatusEvidenceAnswer.init),pending:pending)
    }
    public func readmitExhaustiveAnswer(_ answer:PinExhaustiveQuestionAnswer)async throws->PinExhaustiveQuestionAnswer {
        try await admitExhaustiveQuestion(answer.pending,activeRequestID:answer.requestID)
    }
    /// Unit interpretation is opt-in and remains separate from legacy record answers.
    /// Caller supplies complete actual grouping/relation evidence, never a row count.
    public func sourceUnitQuestion(_ pending:PinPreparedExhaustiveAnswer,request:SourceOccurrenceRequest,relationTask:ChoiceTask?=nil,relationReceipt:DecisionReceipt?=nil,activeRequestID:UUID)async throws->PinUnitQuestionAnswer {
        _=try await admitExhaustiveQuestion(pending,activeRequestID:activeRequestID)
        let answer=try await pending.question.engine.sourceUnitAnswer(pending.sdk,request:request,relationTask:relationTask,relationReceipt:relationReceipt,activeRequestID:activeRequestID)
        return try await admitUnitQuestion(pending,proof:.source(answer),activeRequestID:activeRequestID)
    }
    public func inventoryUnitQuestion(_ pending:PinPreparedExhaustiveAnswer,prepared:PreparedInventoryUnits,relationTask:ChoiceTask?=nil,relationReceipt:DecisionReceipt?=nil,documentIdentityV1:Bool=false,activeRequestID:UUID)async throws->PinUnitQuestionAnswer {
        _=try await admitExhaustiveQuestion(pending,activeRequestID:activeRequestID)
        let answer=try await pending.question.engine.inventoryUnitAnswer(pending.sdk,prepared:prepared,relationTask:relationTask,relationReceipt:relationReceipt,documentIdentityPolicy:PinProductUnitEvidence.documentIdentityPolicy(prepared:prepared,enabled:documentIdentityV1),activeRequestID:activeRequestID)
        return try await admitUnitQuestion(pending,proof:.inventory(answer),activeRequestID:activeRequestID)
    }
    public func readmitUnitQuestion(_ answer:PinUnitQuestionAnswer)async throws->PinUnitQuestionAnswer {
        try await admitUnitQuestion(answer.pending,proof:answer.sdk,activeRequestID:answer.requestID,documentList:answer.sourceDocumentList != nil)
    }
    /// Explicit presentation opt-in only. Ineligible queries retain their full
    /// existing answer. Stale/invalid evidence is never treated as ineligibility.
    public func sourceDocumentListQuestion(_ answer:PinUnitQuestionAnswer)async throws->PinUnitQuestionAnswer {
        do{return try await admitUnitQuestion(answer.pending,proof:answer.sdk,activeRequestID:answer.requestID,documentList:true)}
        catch SemanticError.unsupportedEvidence{return try await readmitUnitQuestion(answer)}
    }
    /// Explicit result-units policy. Legacy composedOutputV3 stays unchanged.
    /// A follow-up keeps its ORIGINAL parent engine/answer identity; the new
    /// submission identity fences asynchronous interpretation independently.
    public func prepareUnitProductQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,previous:PinDisplayedUnitContext?,provider:any DecisionProvider)async throws->PinPreparedUnitProductAnswer {
        try await prepareUnitProductQuestionImpl(question,requestID:requestID,now:now,calendar:calendar,previous:previous,provider:provider,compactProvider:nil).legacy()
    }
    /// Explicit typed query opt-in; source and legacy interpretation are separate.
    public func prepareCompactUnitProductQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,previous:PinDisplayedUnitContext?,provider:any CompactProductQueryProvider)async throws->PinPreparedUnitProductAnswer {
        try await prepareUnitProductQuestionImpl(question,requestID:requestID,now:now,calendar:calendar,previous:previous,provider:nil,compactProvider:provider).legacy()
    }
    /// Explicit v2 only. No implicit retry, extra decision or change to v1 defaults.
    public func prepareLinkedCompactUnitProductQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,previous:PinDisplayedUnitContext?,provider:any CompactProductQueryProvider)async throws->PinPreparedLinkedUnitProductAnswer {
        try await prepareUnitProductQuestionImpl(question,requestID:requestID,now:now,calendar:calendar,previous:previous,provider:nil,compactProvider:provider,linkedContextV2:true).linked()
    }
    /// Explicit member-aware v3. Whole-unit and legacy defaults stay unchanged.
    public func prepareMemberCompactUnitProductQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,previous:PinDisplayedUnitContext?,provider:any CompactProductQueryProvider,useCurrentSavedInventory:Bool=false)async throws->PinPreparedLinkedUnitProductAnswer {
        // Parent presence is native state, not a model decision. Keep the
        // qualified standalone task exact; member interpretation needs a parent.
        if previous==nil {
            if useCurrentSavedInventory {
                // This chooses an intent contract, never correction authority.
                // Callers must independently authenticate current native history.
                return try await prepareUnitProductQuestionImpl(question,requestID:requestID,now:now,calendar:calendar,previous:nil,provider:nil,compactProvider:provider,linkedContextV2:true,currentSavedInventoryV21:true).linked()
            }
            return try await prepareLinkedCompactUnitProductQuestion(question,requestID:requestID,now:now,calendar:calendar,previous:nil,provider:provider)
        }
        return try await prepareUnitProductQuestionImpl(question,requestID:requestID,now:now,calendar:calendar,previous:previous,provider:nil,compactProvider:provider,linkedContextV2:true,memberDetailsV3:true).linked()
    }
    /// Explicit photo input scope contract; no new source interpretation or model router.
    public func preparePhotoScopeCompactUnitProductQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,previous:PinDisplayedUnitContext?,provider:any CompactProductQueryProvider)async throws->PinPreparedLinkedUnitProductAnswer {
        try await prepareUnitProductQuestionImpl(question,requestID:requestID,now:now,calendar:calendar,previous:previous,provider:nil,compactProvider:provider,linkedContextV2:true,photoScopeInventoryV22:true).linked()
    }
    /// Standalone inventory bound to this cache's current permitted source set.
    /// A source snapshot is not a displayed answer or a selected booking.
    public func prepareCurrentSourceScopeCompactUnitProductQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,provider:any CompactProductQueryProvider)async throws->PinPreparedLinkedUnitProductAnswer {
        try await prepareUnitProductQuestionImpl(question,requestID:requestID,now:now,calendar:calendar,previous:nil,provider:nil,compactProvider:provider,linkedContextV2:true,currentSourceScopeV23:true).linked()
    }
    /// Scoped calendar defaults reuse the same native submission, parent and
    /// source-permit owner. This API adds no intent routing or model call.
    public func prepareCalendarDefaultsCompactUnitProductQuestion(_ question:String,requestID:UUID,now:Date,calendar:Calendar,previous:PinDisplayedUnitContext?,provider:any CompactProductQueryProvider,usePhotoScopeComposition:Bool=false,useLocationExtent:Bool=false,useSelectedUnitContinuation:Bool=false)async throws->PinPreparedLinkedUnitProductAnswer {
        try await prepareUnitProductQuestionImpl(question,requestID:requestID,now:now,calendar:calendar,previous:previous,provider:nil,compactProvider:provider,linkedContextV2:true,memberDetailsV3:previous != nil,calendarInventoryDefaultsV1:true,photoCalendarDefaultsV1:usePhotoScopeComposition,savedLocationExtentV1:useLocationExtent,selectedUnitContinuationV1:useSelectedUnitContinuation).linked()
    }
    private func prepareUnitProductQuestionImpl(_ question:String,requestID:UUID,now:Date,calendar:Calendar,previous:PinDisplayedUnitContext?,provider:(any DecisionProvider)?,compactProvider:(any CompactProductQueryProvider)?,linkedContextV2:Bool=false,memberDetailsV3:Bool=false,currentSavedInventoryV21:Bool=false,photoScopeInventoryV22:Bool=false,currentSourceScopeV23:Bool=false,calendarInventoryDefaultsV1:Bool=false,photoCalendarDefaultsV1:Bool=false,savedLocationExtentV1:Bool=false,selectedUnitContinuationV1:Bool=false)async throws->PinPreparedAnyUnitProductAnswer {
        try Task.checkCancellation()
        guard !selectedUnitContinuationV1 || savedLocationExtentV1 else{throw PinEvidenceError.staleRecord}
        guard !savedLocationExtentV1 || photoCalendarDefaultsV1 else{throw PinEvidenceError.staleRecord}
        guard !photoCalendarDefaultsV1 || calendarInventoryDefaultsV1 else{throw PinEvidenceError.staleRecord}
        guard !calendarInventoryDefaultsV1 || (linkedContextV2 && memberDetailsV3==(previous != nil) && !currentSavedInventoryV21 && !photoScopeInventoryV22 && !currentSourceScopeV23)else{throw PinEvidenceError.staleRecord}
        guard !currentSavedInventoryV21 || (previous==nil && linkedContextV2 && !memberDetailsV3) else{throw PinEvidenceError.staleRecord}
        guard !currentSourceScopeV23 || (previous==nil && linkedContextV2 && !currentSavedInventoryV21 && !memberDetailsV3 && !photoScopeInventoryV22) else{throw PinEvidenceError.staleRecord}
        guard sourceInventory == .permittedPhotoObservations,questionSynchronizations==0,let stamp=questionStamp else{throw PinEvidenceError.staleRecord}
        if previous==nil{displayedUnitContextID=nil;linkedUnitEngine=nil;selectedUnitContinuationID=nil;currentSelectedUnitContinuation=nil;unitPublicationAttempt=nil}
        activeUnitSubmission=requestID;unitSubmissionEpoch += 1
        let submissionEpoch=unitSubmissionEpoch,generation=retrievalAnswerGeneration
        var finished=false
        defer{if !finished,unitSubmissionEpoch==submissionEpoch,activeUnitSubmission==requestID{activeUnitSubmission=nil;unitSubmissionEpoch += 1}}
        func current()throws {
            try Task.checkCancellation()
            guard questionSynchronizations==0,questionStamp==stamp,generation==retrievalAnswerGeneration,activeUnitSubmission==requestID,unitSubmissionEpoch==submissionEpoch else{throw PinEvidenceError.staleRecord}
        }
        if let previous {
            _=try await readmitDisplayedUnitContext(previous)
            if selectedUnitContinuationV1 {
                guard previous.continuation?.sdk.publication.publicationID==selectedUnitContinuationID else{throw PinEvidenceError.staleRecord}
                if let focus=previous.continuation{_=try await focus.engine.admitDisplayedContinuation(focus.sdk)}
            }else{guard previous.continuation==nil else{throw PinEvidenceError.staleRecord}}
        }
        try current()
        let permit=try await cache.permit()
        let inventoryInput=EvidenceQuestionInput(taskID:"pin-exhaustive-question",question:question,now:now,calendar:calendar,policy:.completeV9,inferredDatePolicy:.labelledTemporalContext)
        let inventory=try ExhaustiveAppointmentPlanner.task(inventoryInput,policy:.resultUnitsV4)
        var contextual:PreparedDisplayedUnitFollowup?
        var linked:PreparedLinkedUnitQuestion?
        var linkedEngine:LinkedUnitQuestionSession?
        if let previous {
            let input=EvidenceQuestionInput(taskID:"pin-current-unit-question",question:question,now:now,calendar:calendar,activeContextID:previous.id,policy:.completeV9,inferredDatePolicy:.labelledTemporalContext)
            if linkedContextV2 {
                let engine:LinkedUnitQuestionSession
                if selectedUnitContinuationV1,let retained=linkedUnitEngine{engine=retained}
                else{engine=try LinkedUnitQuestionSession(store:cache,unitOwner:previous.answer.pending.question.engine)}
                if selectedUnitContinuationV1{linkedUnitEngine=engine}
                linkedEngine=engine
                linked=try await engine.prepare(input,context:previous.sdk,activeAnswerRequestID:previous.answerRequestID,requestID:requestID,policy:selectedUnitContinuationV1 ? .selectedUnitContinuationV5:savedLocationExtentV1 ? .locationExtentV4:memberDetailsV3 ? .memberDetailsV3:.wholeUnitsV2,continuation:selectedUnitContinuationV1 ? previous.continuation?.sdk:nil)
            }else{
                contextual=try await previous.answer.pending.question.engine.prepareDisplayedUnitFollowup(input,context:previous.sdk,activeAnswerRequestID:previous.answerRequestID)
            }
            _=try await readmitDisplayedUnitContext(previous)
        }
        let meaning:PinUnitProductMeaning
        if let compactProvider {
            guard provider==nil else{throw PinEvidenceError.staleRecord}
            let prepared:PreparedCompactProductQuestion
            if calendarInventoryDefaultsV1 {
                let sources=try await cache.sourceSearchSnapshot(permit:permit)
                try current()
                prepared=try selectedUnitContinuationV1 ? CompactProductQueryPlanner.preparePhotoCalendarSelectedUnitContinuation(taskID:"pin-product-question",inventory:inventory,contextual:linked?.task,sources:sources):savedLocationExtentV1 ? CompactProductQueryPlanner.preparePhotoCalendarLocationExtent(taskID:"pin-product-question",inventory:inventory,contextual:linked?.task,sources:sources):photoCalendarDefaultsV1 ? CompactProductQueryPlanner.preparePhotoCalendarDefaults(taskID:"pin-product-question",inventory:inventory,contextual:linked?.task,sources:sources):CompactProductQueryPlanner.prepareCalendarDefaults(taskID:"pin-product-question",inventory:inventory,contextual:linked?.task,sources:sources)
                try await cache.validate(sources.permit)
                if let previous{_=try await readmitDisplayedUnitContext(previous)}
            }else if currentSourceScopeV23 {
                let sources=try await cache.sourceSearchSnapshot(permit:permit)
                try current()
                prepared=try CompactProductQueryPlanner.prepareCurrentSourceScope(taskID:"pin-product-question",inventory:inventory,sources:sources)
                try await cache.validate(sources.permit)
            }else{
                prepared=try CompactProductQueryPlanner.prepare(taskID:"pin-product-question",inventory:inventory,contextual:linked?.task ?? contextual?.task,permit:permit,contract:photoScopeInventoryV22 ? .photoScopeInventoryV22:currentSavedInventoryV21 ? .currentSavedInventoryV21:memberDetailsV3 ? .memberDetailsV3:linkedContextV2 ? .linkedUnitContextV2:.legacyV1)
            }
            try current()
            let receipt=try await PinCancellableCompactQueryProvider(base:compactProvider).decide(prepared.task)
            try await cache.validate(permit);try current()
            if let previous{_=try await readmitDisplayedUnitContext(previous)}
            try current()
            meaning = .compact(try CompactProductQueryPlanner.compile(receipt,for:prepared))
        }else{
            guard let provider else{throw PinEvidenceError.staleRecord}
            let prepared=try ProductQuestionPlanner.prepare(taskID:"pin-product-question",inventory:inventory,contextual:contextual?.task,permit:permit)
            try current()
            let receipt=try await PinCancellableDecisionProvider(base:provider).decide(prepared.task)
            try await cache.validate(permit);try current()
            if let previous{_=try await readmitDisplayedUnitContext(previous)}
            try current()
            meaning = .legacy(try ProductQuestionPlanner.compile(receipt,for:prepared))
        }
        switch meaning.route {
        case "inventory":
            cancelRetrievedQuestion();activeRetrievalRequest=requestID;activeUnitSubmission=requestID
            let handle=PinPreparedExhaustiveQuestion(requestID:requestID,owner:session,stamp:stamp,generation:retrievalGeneration,engine:ExhaustiveAppointmentSession(store:cache),dismissedSources:questionDismissedSources)
            let nextGeneration=retrievalAnswerGeneration,nextEpoch=unitSubmissionEpoch
            let answer:ExhaustiveAppointmentAnswer
            switch meaning {
            case .legacy(let decision):answer=try await handle.engine.prepare(inventoryInput,requestID:requestID,productDecision:decision,planningPolicy:.resultUnitsV4)
            case .compact(let decision):answer=try await handle.engine.prepare(inventoryInput,requestID:requestID,compactDecision:decision,planningPolicy:.resultUnitsV4)
            }
            try validateExhaustiveQuestion(handle,activeRequestID:requestID)
            guard nextGeneration==retrievalAnswerGeneration,nextEpoch==unitSubmissionEpoch,activeUnitSubmission==requestID else{throw PinEvidenceError.staleRecord}
            finished=true
            return .inventory(PinPreparedExhaustiveAnswer(question:handle,sdk:answer,generation:nextGeneration))
        case "contextual":
            if linkedContextV2 {
                guard let previous,let linked,let linkedEngine,case .compact(let decision)=meaning else{throw PinEvidenceError.staleRecord}
                let result=try await linkedEngine.complete(compactDecision:decision,for:linked,activeRequestID:requestID)
                try current()
                _=try await readmitDisplayedUnitContext(previous)
                var rows:[PinLinkedUnitQuestionRow]=[]
                for row in result.rows {
                    let selection=try await nativeUnitSelection(row.selection,context:previous)
                    try current()
                    rows.append(PinLinkedUnitQuestionRow(selection:selection,expansions:row.expansions,gaps:row.gaps,selectedMemberPath:row.selectedMemberPath,scopedDetails:row.scopedDetails))
                }
                _=try await linkedEngine.admit(result,activeRequestID:requestID)
                try current();finished=true
                return .linked(PinLinkedUnitContextualAnswer(requestID:requestID,rows:rows,context:previous,sdk:result,engine:linkedEngine,submissionEpoch:submissionEpoch,generation:generation,stamp:stamp,selectedUnitContinuationEnabled:selectedUnitContinuationV1))
            }
            guard let previous,let contextual else{throw PinEvidenceError.staleRecord}
            let result:DisplayedUnitFollowup
            switch meaning {
            case .legacy(let decision):result=try await previous.answer.pending.question.engine.completeDisplayedUnitFollowup(decision,for:contextual,activeAnswerRequestID:previous.answerRequestID)
            case .compact(let decision):result=try await previous.answer.pending.question.engine.completeDisplayedUnitFollowup(compactDecision:decision,for:contextual,activeAnswerRequestID:previous.answerRequestID)
            }
            _=try await readmitDisplayedUnitContext(previous)
            try current()
            let selection=try await nativeUnitSelection(result.selection,context:previous)
            try current()
            finished=true
            return .contextual(PinUnitContextualAnswer(requestID:requestID,selection:selection,sdk:result))
        case "unsupported":finished=true;return .unsupported
        case "clarify":throw PinCompactQueryMeaningError.clarify
        case "unknown":throw PinCompactQueryMeaningError.unknown
        default:throw PinEvidenceError.staleRecord
        }
    }
    /// Call only AFTER assigning this whole answer to the actual presenter.
    /// A host replica must first rebuild the complete original answer and may
    /// then reuse the phone's display label for exact task comparison.
    /// An empty admitted answer has no object or ordinal to continue on. Keep
    /// its full answer/proof, but do not give the next question an empty target
    /// branch that the compact interpreter cannot represent.
    public func contextForUnitAnswerContinuation(_ answer:PinUnitQuestionAnswer,displayedUnitIDs:[String])async throws->PinDisplayedUnitContext? {
        if !answer.rows.isEmpty{return try await contextForDisplayedUnitAnswer(answer,displayedUnitIDs:displayedUnitIDs)}
        guard displayedUnitIDs.isEmpty,unitPublicationAttempt==nil,activeUnitSubmission==answer.requestID else{throw PinEvidenceError.staleRecord}
        let epoch=unitSubmissionEpoch
        _=try await readmitUnitQuestion(answer)
        guard epoch==unitSubmissionEpoch,activeUnitSubmission==answer.requestID else{throw PinEvidenceError.staleRecord}
        displayedUnitContextID=nil
        return nil
    }
    public func contextForDisplayedUnitAnswer(_ answer:PinUnitQuestionAnswer,displayedUnitIDs:[String],displayIdentity:UUID?=nil)async throws->PinDisplayedUnitContext {
        guard unitPublicationAttempt==nil else{throw PinEvidenceError.staleRecord}
        let attempt=UUID();unitPublicationAttempt=attempt
        defer{if unitPublicationAttempt==attempt{unitPublicationAttempt=nil}}
        let current=try await readmitUnitQuestion(answer),engine=current.pending.question.engine,context:DisplayedUnitContext
        guard unitPublicationAttempt==attempt else{throw PinEvidenceError.staleRecord}
        if let assessment=current.sourceDocumentList {
            context=try await engine.contextForDisplayedSourceDocumentListAssessment(assessment.sdk,activeRequestID:answer.requestID,displayedUnitIDs:displayedUnitIDs,displayIdentity:displayIdentity)
        }else{switch current.sdk {
        case .source(let value):context=try await engine.contextForDisplayedSourceUnitAnswer(value,activeRequestID:answer.requestID,displayedUnitIDs:displayedUnitIDs,displayIdentity:displayIdentity)
        case .inventory(let value):context=try await engine.contextForDisplayedInventoryUnitAnswer(value,activeRequestID:answer.requestID,displayedUnitIDs:displayedUnitIDs,displayIdentity:displayIdentity)
        }
        }
        _=try await readmitUnitQuestion(current)
        guard unitPublicationAttempt==attempt else{throw PinEvidenceError.staleRecord}
        _=try await engine.admitDisplayedUnitContext(context,activeAnswerRequestID:answer.requestID)
        _=try await readmitUnitQuestion(current)
        guard unitPublicationAttempt==attempt else{throw PinEvidenceError.staleRecord}
        displayedUnitContextID=context.id;linkedUnitEngine=nil;selectedUnitContinuationID=nil;currentSelectedUnitContinuation=nil
        return PinDisplayedUnitContext(answer:current,sdk:context)
    }
    @discardableResult public func readmitDisplayedUnitContext(_ context:PinDisplayedUnitContext)async throws->PinDisplayedUnitContext {
        guard displayedUnitContextID==context.id else{throw PinEvidenceError.staleRecord}
        _=try await readmitUnitQuestion(context.answer)
        _=try await context.answer.pending.question.engine.admitDisplayedUnitContext(context.sdk,activeAnswerRequestID:context.answerRequestID)
        guard displayedUnitContextID==context.id else{throw PinEvidenceError.staleRecord}
        _=try await readmitUnitQuestion(context.answer)
        guard displayedUnitContextID==context.id else{throw PinEvidenceError.staleRecord}
        return context
    }
    public func clearDisplayedUnitContext(_ context:PinDisplayedUnitContext)async throws {
        guard displayedUnitContextID==context.id else{throw PinEvidenceError.staleRecord}
        // Revoke locally before the SDK await; delayed old clears cannot revoke
        // a successor publication or revive a pending contextual submission.
        displayedUnitContextID=nil;linkedUnitEngine=nil;selectedUnitContinuationID=nil;currentSelectedUnitContinuation=nil;activeUnitSubmission=nil;unitSubmissionEpoch += 1;unitPublicationAttempt=nil
        try await context.answer.pending.question.engine.clearDisplayedUnitContext(context.id)
    }
    public func selectDisplayedUnit(_ context:PinDisplayedUnitContext,unitID:String)async throws->PinUnitQuestionSelection {
        _=try await readmitDisplayedUnitContext(context)
        let selection=try await context.answer.pending.question.engine.selectDisplayedUnit(context.sdk,unitID:unitID,activeAnswerRequestID:context.answerRequestID)
        return try await nativeUnitSelection(selection,context:context)
    }
    /// Reuse the linked reader over the actual rendered order of ONE unit.
    /// This does not flatten the event into a fabricated record-answer context.
    public func prepareDisplayedMembers(_ context:PinDisplayedUnitContext,unitID:String)async throws->PinDisplayedMemberContext {
        let parent=try await selectDisplayedUnit(context,unitID:unitID)
        guard questionSynchronizations==0,let stamp=questionStamp,
              !parent.row.members.isEmpty,parent.row.members.count<=256 else{throw PinEvidenceError.staleRecord}
        let generation=retrievalAnswerGeneration,ids=parent.row.memberRecordIDs
        guard ids.count==parent.row.members.count,Set(ids).count==ids.count else{throw PinEvidenceError.staleRecord}
        let engine=try LinkedAppointmentContextSession(store:cache,budget:.init(maximumDepth:0,maximumReads:12,maximumSources:12))
        let requestID=UUID()
        let prepared=try await engine.prepare(bindings:ids.map{LinkedAppointmentBinding(recordID:$0)},requestID:requestID)
        let displayed=try await engine.bindDisplayed(prepared,orderedRecordIDs:ids,activeRequestID:requestID)
        _=try await readmitUnitSelection(parent)
        guard generation==retrievalAnswerGeneration,stamp==questionStamp,questionSynchronizations==0 else{throw PinEvidenceError.staleRecord}
        return PinDisplayedMemberContext(parent:parent,engine:engine,prepared:prepared,displayed:displayed,generation:generation,stamp:stamp)
    }
    @discardableResult public func readmitDisplayedMembers(_ context:PinDisplayedMemberContext)async throws->PinDisplayedMemberContext {
        try Task.checkCancellation()
        guard questionSynchronizations==0,context.generation==retrievalAnswerGeneration,
              context.stamp==questionStamp else{throw PinEvidenceError.staleRecord}
        let current=try await readmitUnitSelection(context.parent)
        guard current.row.memberRecordIDs==context.orderedRecordIDs,
              current.row.members.count==context.members.count,
              zip(current.row.members,context.members).allSatisfy({$0.item==$1.item && $0.selection==$1.selection && $0.sources==$1.sources}) else{throw PinEvidenceError.staleRecord}
        _=try await context.engine.admit(context.prepared,activeRequestID:context.prepared.requestID,requiredReferences:[])
        _=try await readmitUnitSelection(context.parent)
        try Task.checkCancellation()
        guard context.generation==retrievalAnswerGeneration,context.stamp==questionStamp,
              questionSynchronizations==0 else{throw PinEvidenceError.staleRecord}
        return context
    }
    public func selectDisplayedMember(_ context:PinDisplayedMemberContext,ordinal:Int)async throws->PinDisplayedMemberSelection {
        _=try await readmitDisplayedMembers(context)
        guard ordinal>0,ordinal<=context.members.count else{throw PinEvidenceError.staleRecord}
        let selected=try await context.engine.select(ordinal:ordinal,in:context.displayed,activeRequestID:context.prepared.requestID)
        guard selected.recordID==context.orderedRecordIDs[ordinal-1] else{throw PinEvidenceError.staleRecord}
        _=try await readmitDisplayedMembers(context)
        return PinDisplayedMemberSelection(ordinal:ordinal,context:context,sdk:selected)
    }
    public func readDisplayedMemberFacts(_ selection:PinDisplayedMemberSelection)async throws->PinDisplayedMemberFacts {
        let context=try await readmitDisplayedMembers(selection.context)
        guard selection.ordinal>0,selection.ordinal<=context.members.count,
              context.orderedRecordIDs[selection.ordinal-1]==selection.sdk.recordID,
              let summary=context.prepared.summaries.first(where:{$0.recordID==selection.sdk.recordID}),
              summary.reference.kind == .appointmentFacts else{throw PinEvidenceError.staleRecord}
        // Admit the original opaque selection. Re-selecting by the same ID
        // would conceal a caller's foreign session/display handle.
        let expansion=try await context.engine.expand(summary.reference,in:context.prepared,activeRequestID:context.prepared.requestID,selection:selection.sdk)
        guard case .appointment(let projection)=expansion.payload,
              projection == (try PinCanonicalMapping.projection(selection.member.item,scope:scope)) else{throw PinEvidenceError.staleRecord}
        let admitted=try await context.engine.admit(context.prepared,activeRequestID:context.prepared.requestID,requiredReferences:[summary.reference])
        guard admitted.allRequestedReferencesExpanded else{throw PinEvidenceError.staleRecord}
        _=try await readmitDisplayedMembers(context)
        return PinDisplayedMemberFacts(projection:projection,selection:selection,expansion:expansion)
    }
    /// Revalidate the WHOLE selection immediately before EACH original source.
    /// The foreground host still owns PhotoKit fingerprint/access/request checks.
    public func readmitUnitSelection(_ selection:PinUnitQuestionSelection,source:PinCore.EvidenceSource?=nil)async throws->PinUnitQuestionSelection {
        let current=try await nativeUnitSelection(selection.sdk,context:selection.context)
        guard source.map({current.row.sources.contains($0)}) ?? true else{throw PinEvidenceError.staleRecord}
        return current
    }
    public func readmitUnitContextualAnswer(_ answer:PinUnitContextualAnswer)async throws->PinUnitContextualAnswer {
        guard activeUnitSubmission==answer.requestID else{throw PinEvidenceError.staleRecord}
        _=try await answer.selection.context.answer.pending.question.engine.admitDisplayedUnitFollowup(answer.sdk,activeAnswerRequestID:answer.selection.context.answerRequestID)
        _=try await readmitUnitSelection(answer.selection)
        guard activeUnitSubmission==answer.requestID else{throw PinEvidenceError.staleRecord}
        return answer
    }
    /// Recheck the actual parent, every whole native row and the same local
    /// submission before publication and again before EACH original handoff.
    public func readmitLinkedUnitContextualAnswer(_ answer:PinLinkedUnitContextualAnswer)async throws->PinLinkedUnitContextualAnswer {
        func current()throws {
            try Task.checkCancellation()
            guard activeUnitSubmission==answer.requestID,unitSubmissionEpoch==answer.submissionEpoch,
                  retrievalAnswerGeneration==answer.generation,questionSynchronizations==0,questionStamp==answer.stamp else{throw PinEvidenceError.staleRecord}
        }
        try current()
        _=try await readmitDisplayedUnitContext(answer.context)
        if answer.selectedUnitContinuationEnabled,let focus=currentSelectedUnitContinuation,focus.sdk.publication.answerRequestID==answer.requestID {
            _=try await focus.engine.admitDisplayedContinuation(focus.sdk)
        }else{_=try await answer.engine.admit(answer.sdk,activeRequestID:answer.requestID)}
        try current()
        for row in answer.rows {_=try await readmitUnitSelection(row.selection);try current()}
        return answer
    }
    /// Retain the prior facets only as presentation when the current original
    /// request consumes that exact, process-local published selection. Original
    /// admission must continue to use `answer`, never this older request handle.
    public func presentationForLinkedUnitOriginal(_ answer:PinLinkedUnitContextualAnswer,previous:PinLinkedUnitContextualAnswer?)async throws->PinLinkedUnitContextualAnswer {
        _=try await readmitLinkedUnitContextualAnswer(answer)
        guard answer.selectedUnitContinuationEnabled,answer.operation=="currentOriginals",
              let previous,previous.selectedUnitContinuationEnabled,
              previous.allRequestedValuesEstablished,previous.allSelectedMemberReadsComplete,
              previous.contextID==answer.contextID,previous.context.sdk.bindingSHA256==answer.context.sdk.bindingSHA256,
              previous.generation==answer.generation,previous.stamp==answer.stamp,
              previous.rows.count==1,answer.rows.count==1,
              previous.rows[0].selectedMemberPath==nil,answer.rows[0].selectedMemberPath==nil,
              let focus=answer.context.continuation,let current=currentSelectedUnitContinuation,
              focus.sdk.publication.publicationID==current.sdk.publication.publicationID,
              focus.sdk.publication.bindingSHA256==current.sdk.publication.bindingSHA256 else{return answer}
        let publication=focus.sdk.publication,old=previous.rows[0].selection,new=answer.rows[0].selection
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        guard publication.answerRequestID==previous.requestID,publication.parentContextID==previous.contextID,
              publication.parentBindingSHA256==previous.context.sdk.bindingSHA256,
              try encoder.encode(publication.contextualReceipt)==encoder.encode(previous.receipt),
              publication.selectedOrdinal==old.ordinal,old.ordinal==new.ordinal,
              publication.selectedUnitID==old.row.id,old.row.id==new.row.id,
              old.sources==new.sources else{return answer}
        _=try PinLinkedUnitPresentation.row(new.row,contextual:previous)
        _=try await focus.engine.admitDisplayedContinuation(focus.sdk)
        _=try await readmitLinkedUnitContextualAnswer(answer)
        return previous
    }
    /// The presenter must assign this admitted contextual answer before calling.
    /// Publishing retains the full base inventory; it does not narrow ordinals.
    public func contextForDisplayedLinkedUnitAnswer(_ answer:PinLinkedUnitContextualAnswer,publicationID:UUID=UUID())async throws->PinDisplayedUnitContext {
        _=try await readmitLinkedUnitContextualAnswer(answer)
        guard answer.selectedUnitContinuationEnabled else{return answer.context}
        guard unitPublicationAttempt==nil else{throw PinEvidenceError.staleRecord}
        let attempt=UUID(),epoch=unitSubmissionEpoch
        unitPublicationAttempt=attempt
        defer{if unitPublicationAttempt==attempt{unitPublicationAttempt=nil}}
        func current()throws {
            try Task.checkCancellation()
            guard unitPublicationAttempt==attempt,unitSubmissionEpoch==epoch,activeUnitSubmission==answer.requestID,
                  displayedUnitContextID==answer.contextID else{throw PinEvidenceError.staleRecord}
        }
        // Viewing an original retains its selection rather than replacing focus.
        if answer.operation=="currentOriginals" {try current();return answer.context}
        let eligible=answer.allRequestedValuesEstablished && answer.allSelectedMemberReadsComplete && answer.rows.count==1 && answer.rows[0].selectedMemberPath==nil && !answer.rows[0].selection.row.membershipUncertain
        var result=answer.context
        if eligible {
            let focus=try await answer.engine.contextForDisplayedContinuation(answer.sdk,activeRequestID:answer.requestID,publicationID:publicationID)
            try current()
            let chain=(answer.context.continuation?.publications ?? [])+[focus.publication]
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            guard chain.count<=8,try encoder.encode(chain).count<=262_144 else{throw PinEvidenceError.staleRecord}
            _=try await answer.engine.admitDisplayedContinuation(focus);try current()
            let native=PinSelectedUnitContinuation(engine:answer.engine,sdk:focus,publications:chain)
            result.continuation=native;currentSelectedUnitContinuation=native;selectedUnitContinuationID=focus.publication.publicationID
        }else{
            let old=answer.context.continuation
            selectedUnitContinuationID=nil;currentSelectedUnitContinuation=nil;result.continuation=nil
            if let old{try await old.engine.clearDisplayedContinuation(old.sdk.publication.publicationID);try current()}
        }
        _=try await readmitDisplayedUnitContext(result);try current()
        return result
    }
    private func nativeUnitSelection(_ selection:DisplayedUnitSelection,context:PinDisplayedUnitContext)async throws->PinUnitQuestionSelection {
        _=try await readmitDisplayedUnitContext(context)
        _=try await context.answer.pending.question.engine.admitDisplayedUnitSelection(selection,activeAnswerRequestID:context.answerRequestID)
        let current=try await readmitUnitQuestion(context.answer)
        guard displayedUnitContextID==context.id,selection.contextID==context.id,
              selection.ordinal>0,selection.ordinal<=context.orderedUnitIDs.count,
              context.orderedUnitIDs[selection.ordinal-1]==selection.row.unit.id else{throw PinEvidenceError.staleRecord}
        let row=try PinUnitNativeBinding.row(selection.row.unit,uncertain:selection.row.membershipUncertain,
            matchedRecordIDs:Set(current.pending.sdk.matches.map{$0.projection.recordID}),uncertainRecordIDs:Set(current.pending.sdk.uncertain.map{$0.projection.recordID}),
            evidence:selection.row.statusEvidence,records:questionRows,scope:scope)
        guard let admitted=current.rows.first(where:{$0.id==row.id}),admitted.memberRecordIDs==row.memberRecordIDs else{throw PinEvidenceError.staleRecord}
        return PinUnitQuestionSelection(row:row,context:context,sdk:selection)
    }
    private func admitUnitQuestion(_ pending:PinPreparedExhaustiveAnswer,proof:PinUnitQuestionProof,activeRequestID:UUID,documentList:Bool=false)async throws->PinUnitQuestionAnswer {
        _=try await admitExhaustiveQuestion(pending,activeRequestID:activeRequestID)
        let units:[SourceOccurrenceUnit],uncertain:Set<String>,unit:String,lower:Int,upper:Int,exact:Int?,identity:Bool,complete:Bool,gaps:[String:Set<AppointmentField>],coverage:ExhaustiveAppointmentCoverage,status:UnitSourceStatusEvidenceAnswer?
        switch proof {
        case .source(let value):
            let value=try await pending.question.engine.admitSourceUnitAnswer(value,activeRequestID:activeRequestID)
            units=value.orderedUnits;uncertain=Set(value.uncertainUnits.map(\.id));unit=value.resultUnit.rawValue
            lower=value.countLowerBound;upper=value.countUpperBound;exact=value.exactCount;identity=value.identityResolved;complete=value.requestedAnswerComplete
            gaps=value.unresolvedFieldsByUnit;coverage=value.coverage;status=value.sourceStatusEvidence
        case .inventory(let value):
            let value=try await pending.question.engine.admitInventoryUnitAnswer(value,activeRequestID:activeRequestID)
            units=value.orderedUnits;uncertain=Set(value.uncertainUnits.map(\.id));unit=value.resultUnit.rawValue
            lower=value.countLowerBound;upper=value.countUpperBound;exact=value.exactCount;identity=value.identityResolved;complete=value.requestedAnswerComplete
            gaps=value.unresolvedFieldsByUnit;coverage=value.coverage;status=value.sourceStatusEvidence
        }
        try validateExhaustiveQuestion(pending.question,activeRequestID:activeRequestID)
        guard pending.generation==retrievalAnswerGeneration,
              Set(units.map(\.id)).count==units.count,
              status==nil || status?.rows.map(\.unitID)==units.map(\.id) else{throw PinEvidenceError.staleRecord}
        let matchedIDs=Set(pending.sdk.matches.map{$0.projection.recordID}),uncertainIDs=Set(pending.sdk.uncertain.map{$0.projection.recordID})
        let rows=try units.enumerated().map { index,value in
            try PinUnitNativeBinding.row(value,uncertain:uncertain.contains(value.id),matchedRecordIDs:matchedIDs,uncertainRecordIDs:uncertainIDs,evidence:status?.rows[index],records:questionRows,scope:scope)
        }
        let memberIDs=rows.flatMap(\.memberRecordIDs)
        guard Set(memberIDs).count==memberIDs.count else{throw PinEvidenceError.staleRecord}
        var assessment:PinSourceDocumentList?
        if documentList {
            guard case .inventory(let inventory)=proof else{throw SemanticError.unsupportedEvidence}
            let value=try await pending.question.engine.sourceDocumentListAssessment(inventory,activeRequestID:activeRequestID)
            _=try await pending.question.engine.admitSourceDocumentListAssessment(value,activeRequestID:activeRequestID)
            try validateExhaustiveQuestion(pending.question,activeRequestID:activeRequestID)
            guard pending.generation==retrievalAnswerGeneration,value.rows.map({$0.unit.id})==rows.map(\.id),
                  try zip(value.rows,rows).allSatisfy({sdk,native in
                      sdk.unit.members.map(\.projection)==(try native.members.map{try PinCanonicalMapping.projection($0.item,scope:scope)}) &&
                      native.members.count==1 && native.members[0].selection==sdk.queryMembership.rawValue
                  }) else{throw PinEvidenceError.staleRecord}
            assessment=PinSourceDocumentList(rows:value.rows.map{.init(id:$0.unit.id,queryMembership:$0.queryMembership.rawValue,unresolvedDetails:Set($0.unresolvedDetails.map(\.rawValue)),unresolvedFields:Set($0.unresolvedFields.map(\.rawValue)))},listedMembershipResolved:value.listedMembershipResolved,listedRequestedFieldsEstablished:value.listedRequestedFieldsEstablished,sdk:value)
        }
        return PinUnitQuestionAnswer(requestID:activeRequestID,operation:pending.sdk.plan.operation.rawValue,resultUnit:unit,rows:rows,countLowerBound:lower,countUpperBound:upper,exactCount:exact,identityResolved:identity,requestedAnswerComplete:complete,unresolvedFieldsByUnit:gaps.mapValues{Set($0.map(\.rawValue))},coverage:PinExhaustiveQuestionCoverage(coverage,dismissed:0),requestedSourceEvidence:Set(status?.requested.map(\.rawValue) ?? []),currentPersonalBookingNotEstablished:status?.currentPersonalBooking != nil,admittedClaimReviewComplete:status?.admittedClaimReviewComplete ?? false,pending:pending,sdk:proof,sourceDocumentList:assessment)
    }
    public func planQuestionEvidence(_ answer:PinExhaustiveQuestionAnswer,activeRequestID:UUID,permittedSources:Set<EvidenceSource>,maximumTargets:Int=3)async throws->PinQuestionEvidencePlan {
        guard (1...12).contains(maximumTargets)else{throw PinDevelopmentError.sourceNotAllowed}
        let current=try await admitExhaustiveQuestion(answer.pending,activeRequestID:activeRequestID)
        guard permittedSources.isSubset(of:Set(current.missingEvidence.map(\.source))) else{throw PinDevelopmentError.sourceNotAllowed}
        let selected=Array(current.missingEvidence.filter{permittedSources.contains($0.source)}.prefix(maximumTargets))
        return PinQuestionEvidencePlan(targets:selected,withheldTargetCount:current.missingEvidence.count-selected.count,dismissedTargetCount:current.coverage.dismissedSourceTargets)
    }
    public func prepareImageReread(_ answer:PinExhaustiveQuestionAnswer,source:PinCore.EvidenceSource,activeRequestID:UUID)async throws->PinPreparedImageReread {
        let current=try await admitExhaustiveQuestion(answer.pending,activeRequestID:activeRequestID)
        guard current.missingEvidence.contains(where:{$0.source==source})else{throw PinDevelopmentError.sourceNotAllowed}
        let read=try await cache.sourceReadSnapshot(sourceID:source.id,permit:cache.permit())
        guard read.source.reference==SourceReference(id:source.id,revision:source.revision,fingerprint:source.fingerprint)else{throw PinEvidenceError.staleRecord}
        _=try await admitExhaustiveQuestion(answer.pending,activeRequestID:activeRequestID)
        return PinPreparedImageReread(source:source,answer:answer,read:read,owner:session,unitPlan:nil)
    }
    /// Only validated finite relation choices can add identity-reading needs.
    /// All members of an implicated source remain in the target, not one ticket.
    public func planUnitReread(_ answer:PinUnitQuestionAnswer,snapshot:PinProductAuthoritySnapshot,evidence:PinProductUnitEvidence,initialPolicy:PinInitialSourcePolicy,documentIdentityV1:Bool=false,activeRequestID:UUID)async throws->PinUnitRereadPlan {
        let epoch=unitSubmissionEpoch
        let current=try await readmitUnitQuestion(answer)
        guard activeRequestID==current.requestID,snapshot.owner==session,snapshot.stamp==questionStamp,
              snapshot.stamp==current.pending.question.stamp,
              activeUnitSubmission.map({$0==activeRequestID}) ?? true,
              case .inventory(let original)=current.sdk,let selected=AppointmentResultUnit(rawValue:current.resultUnit)else{throw PinEvidenceError.staleRecord}
        let prepared=try evidence.prepare(memories:snapshot.authority.memories,records:snapshot.authority.records,unit:selected,initialPolicy:initialPolicy)
        let verified=try await current.pending.question.engine.inventoryUnitAnswer(current.pending.sdk,prepared:prepared,relationTask:evidence.crossSourceTask,relationReceipt:evidence.crossSourceReceipt,documentIdentityPolicy:PinProductUnitEvidence.documentIdentityPolicy(prepared:prepared,enabled:documentIdentityV1),activeRequestID:activeRequestID)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        guard verified.evidenceBindingSHA256==original.evidenceBindingSHA256,
              try encoder.encode(verified.sourceReceipts)==encoder.encode(original.sourceReceipts),
              try encoder.encode(verified.localRelationReceipts)==encoder.encode(original.localRelationReceipts),
              try encoder.encode(verified.crossSourceRelationReceipt)==encoder.encode(original.crossSourceRelationReceipt),
              try encoder.encode(verified.queryReceipt)==encoder.encode(original.queryReceipt) else{throw PinEvidenceError.invalidSupport}
        _=try await readmitUnitQuestion(current)
        let flat=try await admitExhaustiveQuestion(current.pending,activeRequestID:activeRequestID)
        var targets:[PinCore.EvidenceSource:PinMissingQuestionEvidence]=[:]
        func add(_ source:PinCore.EvidenceSource,fields:Set<String>,reasons:Set<String>)throws {
            guard snapshot.authority.memories.contains(where:{PinCore.EvidenceSource($0)==source})else{throw PinEvidenceError.staleRecord}
            let rows=snapshot.authority.records.filter{!$0.dismissed && $0.allSources.contains(AppointmentSource(source))}
            let ids=Set(rows.compactMap(\.canonicalRecordID));guard ids.count==rows.count else{throw PinEvidenceError.invalidSupport}
            let old=targets[source]
            targets[source]=PinMissingQuestionEvidence(source:source,recordIDs:ids.union(old?.recordIDs ?? []),fields:fields.union(old?.fields ?? []),reasons:reasons.union(old?.reasons ?? []))
        }
        for gap in flat.missingEvidence{try add(gap.source,fields:gap.fields,reasons:gap.reasons)}
        if selected == .occurrences {
            for proof in evidence.sources where proof.grouped != nil {
                guard let memory=snapshot.authority.memories.first(where:{$0.id==proof.sourceID}),let task=proof.localRelationTask,let receipt=proof.localRelationReceipt else{throw PinEvidenceError.invalidSupport}
                let request=try proof.occurrenceRequest(memory:memory,records:snapshot.authority.records)
                let local=try SourceOccurrenceInterpreter.compile(request,task:task,receipt:receipt)
                if local.pairs.contains(where:{$0.relation == .unclear}) {
                    try add(PinCore.EvidenceSource(memory),fields:[],reasons:["sourceOccurrenceIdentityUnresolved"])
                }
            }
            if let task=evidence.crossSourceTask,let receipt=evidence.crossSourceReceipt {
                // Compile reconstructs the exact task, binding and order before
                // finite pair IDs can identify any implicated source endpoint.
                _=try InventoryOccurrenceInterpreter.compile(id:task.id,prepared:prepared,task:task,receipt:receipt)
                for a in prepared.units.indices {for b in prepared.units.indices where b>a {
                    let key="pair_\(a)_\(b)"
                    if task.questions[key] != nil,receipt.answers[key]?.choice=="unclear" {
                        for member in prepared.units[a].members+prepared.units[b].members {for source in member.projection.sources {
                            try add(.init(id:source.id,fingerprint:source.fingerprint,revision:source.revision),fields:[],reasons:["crossSourceIdentityUnresolved"])
                        }}
                    }
                }}
            }
        }
        _=try await readmitUnitQuestion(current)
        guard epoch==unitSubmissionEpoch,snapshot.stamp==questionStamp else{throw PinEvidenceError.staleRecord}
        return PinUnitRereadPlan(targets:targets.values.sorted{($0.source.id,$0.source.revision,$0.source.fingerprint)<($1.source.id,$1.source.revision,$1.source.fingerprint)},answer:current,snapshot:snapshot,owner:session,submissionEpoch:epoch)
    }
    private func readmitUnitRereadPlan(_ plan:PinUnitRereadPlan,activeRequestID:UUID)async throws->(PinUnitQuestionAnswer,PinExhaustiveQuestionAnswer) {
        guard plan.owner==session,plan.snapshot.owner==session,plan.submissionEpoch==unitSubmissionEpoch,
              plan.snapshot.stamp==questionStamp,plan.answer.requestID==activeRequestID,
              activeUnitSubmission.map({$0==activeRequestID}) ?? true else{throw PinEvidenceError.staleRecord}
        let current=try await readmitUnitQuestion(plan.answer)
        let flat=try await admitExhaustiveQuestion(current.pending,activeRequestID:activeRequestID)
        guard plan.submissionEpoch==unitSubmissionEpoch,plan.snapshot.stamp==questionStamp else{throw PinEvidenceError.staleRecord}
        return (current,flat)
    }
    public func prepareImageReread(_ plan:PinUnitRereadPlan,source:PinCore.EvidenceSource,activeRequestID:UUID)async throws->PinPreparedImageReread {
        let(_,flat)=try await readmitUnitRereadPlan(plan,activeRequestID:activeRequestID)
        guard plan.targets.contains(where:{$0.source==source})else{throw PinDevelopmentError.sourceNotAllowed}
        let read=try await cache.sourceReadSnapshot(sourceID:source.id,permit:cache.permit())
        guard read.source.reference==SourceReference(id:source.id,revision:source.revision,fingerprint:source.fingerprint)else{throw PinEvidenceError.staleRecord}
        _=try await readmitUnitRereadPlan(plan,activeRequestID:activeRequestID)
        return PinPreparedImageReread(source:source,answer:flat,read:read,owner:session,unitPlan:plan)
    }
    public func prepareInitialImageRead(_ memory:PhotoMemory,activeRequestID:UUID)async throws->PinPreparedInitialImageRead {
        let source=PinCore.EvidenceSource(memory),epoch=unitSubmissionEpoch
        guard sourceInventory == .permittedPhotoObservations,questionSynchronizations==0,
              let stamp=questionStamp,memory.revision==1,memory.visualReading==nil,
              !questionDismissedSources.contains(where:{$0.id==memory.id}),
              !questionRows.values.contains(where:{($0.allSources+($0.previousEvidence?.sources ?? [])).contains(where:{$0.id==memory.id})})else{throw PinDevelopmentError.sourceNotAllowed}
        let read=try await cache.sourceReadSnapshot(sourceID:source.id,permit:cache.permit())
        guard read.source.reference==SourceReference(id:source.id,revision:source.revision,fingerprint:source.fingerprint)else{throw PinEvidenceError.staleRecord}
        let authority=PinPreparedInitialImageRead(source:source,read:read,owner:session,stamp:stamp,epoch:epoch,requestID:activeRequestID)
        try await readmitImageReadAuthority(.initial(authority),activeRequestID:activeRequestID)
        return authority
    }
    private func readmitImageReadAuthority(_ authority:PinImageReadAuthority,activeRequestID:UUID)async throws {
        switch authority {
        case .question(let value):try await readmitImageRereadAuthority(value,activeRequestID:activeRequestID)
        case .initial(let value):
            try Task.checkCancellation()
            guard value.owner==session,value.requestID==activeRequestID,value.stamp==questionStamp,
                  value.epoch==unitSubmissionEpoch,questionSynchronizations==0,sourceInventory == .permittedPhotoObservations else{throw PinEvidenceError.staleRecord}
            try await cache.validate(value.read.permit)
        }
    }
    public func readInitialImage(_ authority:PinPreparedInitialImageRead,activeRequestID:UUID,ledger:PinImageRereadLedger,acquire:@Sendable(PinCore.EvidenceSource)async throws->Data,validateHost:@Sendable()async throws->Void,reader:any VisualEvidenceReader,prepareFrame:@escaping @Sendable(Data)async throws->PreparedVisualFrame)async throws->PinImageRereadResult {
        try await readImage(.initial(authority),activeRequestID:activeRequestID,ledger:ledger,acquire:acquire,validateHost:validateHost,reader:reader,admission:.preserveVisualEvidence,readingPolicy:.verbatimFieldsV2,framePolicy:.pixelBound2400kV2,prepareFrame:prepareFrame)
    }
    private func readmitImageRereadAuthority(_ authority:PinPreparedImageReread,activeRequestID:UUID)async throws {
        guard authority.owner==session else{throw PinEvidenceError.staleRecord}
        if let plan=authority.unitPlan{_=try await readmitUnitRereadPlan(plan,activeRequestID:activeRequestID)}
        else{_=try await admitExhaustiveQuestion(authority.answer.pending,activeRequestID:activeRequestID)}
    }
    /// Acquisition and liveness closures are supplied by the foreground native
    /// owner. Whole-frame policy only: field-scoped reads cannot replace text.
    public func readImageReread(_ authority:PinPreparedImageReread,activeRequestID:UUID,ledger:PinImageRereadLedger,acquire:@Sendable(PinCore.EvidenceSource)async throws->Data,validateHost:@Sendable()async throws->Void,reader:any VisualEvidenceReader,admission:PinImageRereadAdmission = .completeTextOnly,readingPolicy:VisualReadingPolicy = .verbatimFieldsV2,framePolicy:VisualFramePolicy = .legacy2048JPEG95,prepareFrame:(@Sendable(Data)async throws->PreparedVisualFrame)?=nil)async throws->PinImageRereadResult {
        try await readImage(.question(authority),activeRequestID:activeRequestID,ledger:ledger,acquire:acquire,validateHost:validateHost,reader:reader,admission:admission,readingPolicy:readingPolicy,framePolicy:framePolicy,prepareFrame:prepareFrame)
    }
    private func readImage(_ authority:PinImageReadAuthority,activeRequestID:UUID,ledger:PinImageRereadLedger,acquire:@Sendable(PinCore.EvidenceSource)async throws->Data,validateHost:@Sendable()async throws->Void,reader:any VisualEvidenceReader,admission:PinImageRereadAdmission = .completeTextOnly,readingPolicy:VisualReadingPolicy = .verbatimFieldsV2,framePolicy:VisualFramePolicy = .legacy2048JPEG95,prepareFrame:(@Sendable(Data)async throws->PreparedVisualFrame)?=nil)async throws->PinImageRereadResult {
        guard readingPolicy == .verbatimFieldsV2 || readingPolicy == .localOCRDenseV1 else{throw PinDevelopmentError.sourceNotAllowed}
        if readingPolicy == .localOCRDenseV1 {
            guard case .completeTextOnly=admission else{throw PinDevelopmentError.sourceNotAllowed}
        }
        try await readmitImageReadAuthority(authority,activeRequestID:activeRequestID)
        guard try await ledger.canRead(authority.source)else{throw PinDevelopmentError.sourceNotAllowed}
        try await readmitImageReadAuthority(authority,activeRequestID:activeRequestID)
        try await validateHost();try Task.checkCancellation()
        let bytes=try await acquire(authority.source)
        try await validateHost();try Task.checkCancellation()
        try await readmitImageReadAuthority(authority,activeRequestID:activeRequestID)
        let saved=try await ledger.savedAttempt(source:authority.source)
        let acquisitionID=saved?.taskID ?? UUID()
        let binding=try await cache.bindSourceImage(authority.read,imageSHA256:VisualEvidenceRequest.hash(bytes),acquisitionID:acquisitionID)
        let frame:PreparedVisualFrame
        if let saved{frame=try PreparedVisualFrame.restoreTrustedHostArtifact(saved.frameData,originalImageData:bytes)}
        else if let prepareFrame{frame=try await prepareFrame(bytes)}
        else{frame=try PreparedVisualFrame.prepare(originalImageData:bytes,policy:framePolicy)}
        guard frame.preprocessing==(framePolicy == .pixelBound2400kV2 ? VisualEvidenceRequest.frameVersionV2:VisualEvidenceRequest.frameVersion)else{throw PinDevelopmentError.sourceNotAllowed}
        let request=try VisualEvidenceRequest(taskID:acquisitionID.uuidString,binding:binding,imageData:bytes,preparedFrame:frame,readingPolicy:readingPolicy)
        try await validateHost();try Task.checkCancellation()
        try await readmitImageReadAuthority(authority,activeRequestID:activeRequestID)
        let retainedReceipt:VisualEvidenceReceipt?
        if saved != nil{retainedReceipt=try await ledger.claimContinuation(request,source:authority.source)}
        else{try await ledger.reserve(request,source:authority.source);retainedReceipt=nil}
        try await validateHost();try Task.checkCancellation()
        try await readmitImageReadAuthority(authority,activeRequestID:activeRequestID)
        let prepared:PreparedVisualEvidence
        if let retainedReceipt {
            // Existing receipt passes the same SDK/currentness path. No model
            // call and no decoded source permit are substituted for admission.
            prepared=try await VisualEvidenceSession.prepare(request,reader:PinRetainedVisualReceiptReader(receipt:retainedReceipt),store:cache,liveness:authority.liveness)
        }else{
            prepared=try await VisualEvidenceSession.prepare(request,reader:reader,store:cache,liveness:authority.liveness)
        }
        try await ledger.received(prepared.receipt,taskID:request.taskID)
        try await validateHost();try Task.checkCancellation()
        let admitted=try await VisualEvidenceSession.admit(prepared,activeTaskID:request.taskID,store:cache)
        try await readmitImageReadAuthority(authority,activeRequestID:activeRequestID)
        guard admitted.readScope == .fullDocumentRequested,admitted.coverage != .noReadableDetails,!admitted.textLines.isEmpty else{throw PinEvidenceError.staleRecord}
        let visualReading:PhotoVisualReading?
        switch admission {
        case .completeTextOnly:
            guard admitted.coverage == .readable,admitted.visibleDocumentCount<=1 else{throw PinEvidenceError.invalidSupport}
            visualReading=nil
        case .preserveVisualEvidence:
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            visualReading=try PhotoVisualReading(sourceBeforeRead:authority.source,originalSHA256:binding.imageSHA256,frameSHA256:VisualEvidenceRequest.hash(try request.modelImageData()),requestData:request.requestData(),receiptData:encoder.encode(prepared.receipt))
        }
        let lines=admitted.textLines.map{line in CardLine(line.text,confidence:Float(line.confidence),region:line.region.map{EvidenceRegion(x:$0.x,y:$0.y,width:$0.width,height:$0.height)})}
        return PinImageRereadResult(visualReading:visualReading,source:authority.source,lines:lines,receipt:prepared.receipt,acquisitionID:acquisitionID,originalSHA256:binding.imageSHA256,frameSHA256:VisualEvidenceRequest.hash(try request.modelImageData()),prepared:prepared,authority:authority)
    }
    public func admitImageReread(_ result:PinImageRereadResult,activeRequestID:UUID)async throws {
        try await readmitImageReadAuthority(result.authority,activeRequestID:activeRequestID)
        _=try await VisualEvidenceSession.admit(result.prepared,activeTaskID:result.acquisitionID.uuidString,store:cache)
        try await readmitImageReadAuthority(result.authority,activeRequestID:activeRequestID)
    }
    private func validateExhaustiveQuestion(_ prepared:PinPreparedExhaustiveQuestion,activeRequestID:UUID)throws {
        try Task.checkCancellation()
        guard prepared.owner==session,sourceInventory == .permittedPhotoObservations,
              questionSynchronizations==0,prepared.stamp==questionStamp,
              prepared.requestID==activeRequestID,activeRetrievalRequest==activeRequestID,
              prepared.generation==retrievalGeneration else{throw PinEvidenceError.staleRecord}
    }
    /// Export only an already-current fictional native state for local peer
    /// reconstruction. A real store permit and the whole saved SDK snapshot
    /// are checked; the peer cannot become source or action authority.
    public func phoneTestAuthority(memories:[PhotoMemory],records:[AppointmentItem],manifestSHA256:String,sealedSession:PinSealedTestSession?=nil,witnesses:[PinFixtureSourceWitness]=[])async throws->PinPhoneQuestionAuthority {
        #if DEBUG
        guard Bundle.main.bundleIdentifier=="app.pin.phonetest",Bundle.main.object(forInfoDictionaryKey:"PinPairedPhoneTest")as?Bool==true,
              questionSynchronizations==0,let stamp=questionStamp,records.count==questionRows.count,
              records.allSatisfy({row in questionRows[row.canonicalRecordID ?? ""].map{$0.hasSameEvidence(as:row) && $0.canonicalRevision==row.canonicalRevision && $0.previousEvidence==row.previousEvidence} ?? false})else{throw PinDevelopmentError.disabled}
        let permit=try await cache.permit(),snapshot=try await cache.recordSearchSnapshot(permit:permit),changes=try await cache.sourceChangeSnapshot(permit:permit)
        let bytes=try Data(contentsOf:directory.appendingPathComponent("memory.json"));guard bytes.count<=262144 else{throw PinDevelopmentError.oversized}
        let saved=try JSONDecoder().decode(PinPhoneQuestionAuthority.SavedSDK.self,from:bytes)
        guard saved.scope==scope,saved.rows.values.sorted(by:{$0.projection.recordID<$1.projection.recordID})==snapshot.records,
              (saved.sourceChanges ?? [:]).values.sorted(by:{$0.recordID<$1.recordID})==changes else{throw PinEvidenceError.staleRecord}
        try await cache.validate(permit)
        guard questionSynchronizations==0,stamp==questionStamp else{throw PinEvidenceError.staleRecord}
        if let sealedSession{try sealedSession.validateNativeProfile();guard manifestSHA256==sealedSession.fixtureManifestSHA256 else{throw PinDevelopmentError.sourceNotAllowed}}
        return PinPhoneQuestionAuthority(schema:sealedSession==nil ? 1:2,fixtureManifestSHA256:manifestSHA256,memories:memories,records:records,sdkMemory:bytes,witnesses:sealedSession==nil ? nil:witnesses)
        #else
        throw PinDevelopmentError.disabled
        #endif
    }
    /// Only this opt-in route changes generic document projections. The same
    /// native and derived owners continue to hold appointments and sources.
    public func savedContentQuestion(_ question:String,requestID:UUID,previous:PinSavedContentContext?=nil,
        provider:any DecisionProvider,validateAccess:@Sendable ()async throws->Void,
        progress:@Sendable (PinSavedContentStage)async->Void = {_ in})async throws->PinSavedContentAnswer {
        try Task.checkCancellation();try await validateAccess()
        guard savedContentEnabled,questionSynchronizations==0,let stamp=questionStamp,let catalog=savedContentCatalog,
              previous.map({$0.owner==session && $0.sdk.id==savedContentDisplayedID}) ?? true else{throw PinEvidenceError.staleRecord}
        savedContentEpoch += 1;let epoch=savedContentEpoch;savedContentRequest=requestID;savedContentSettledRequest=nil;savedContentOriginalAnswerID=nil
        let engine:SavedContentQuestionSession
        if let existing=savedContentEngine{engine=existing}
        else{engine=try SavedContentQuestionSession(store:cache);savedContentEngine=engine}
        func current()throws {
            try Task.checkCancellation()
            guard savedContentRequest==requestID,savedContentEpoch==epoch,questionSynchronizations==0,questionStamp==stamp else{throw PinEvidenceError.staleRecord}
        }
        if previous == nil {savedContentHistory=[]}
        let snapshot=try await SavedContentReplaySnapshot.capture(store:cache,catalog:catalog)
        try current()
        PinQuestionTiming.markSaved(requestID,.snapshotCaptured)
        let replayQuery=SavedContentReplayQuery(question:question,taskID:"pin-saved-content-"+requestID.uuidString,requestID:requestID,parentContextID:previous?.sdk.id)
        let boundProvider:any DecisionProvider
        let replayProvider=provider as? any PinSavedContentReplayProviding
        if let replayProvider {
            guard savedContentHistory.count<8 else{throw PinDevelopmentError.testEnded}
            savedContentReplayProvider=replayProvider
            boundProvider=try replayProvider.bound(snapshot:snapshot,query:replayQuery,history:savedContentHistory)
        }else{boundProvider=provider}
        let prepared=try await engine.prepare(question:question,taskID:replayQuery.taskID,requestID:requestID,catalog:catalog,context:previous?.sdk)
        try current();await progress(.understanding)
        try await validateAccess();try current()
        try await engine.validatePrepared(prepared,activeRequestID:requestID);try current()
        PinQuestionTiming.markSaved(requestID,.taskPrepared)
        let receipt=try await boundProvider.decide(prepared.task)
        try current();try await validateAccess();try current()
        var state=try await engine.start(receipt,for:prepared,activeRequestID:requestID)
        while let task=state.nextTask {
            await progress(.checkingEvidence(visited:state.visitedRecords,total:state.totalRecords))
            try current();try await validateAccess();try current()
            try await engine.validatePendingPage(activeRequestID:requestID);try current()
            let page=try await boundProvider.decide(task)
            try current();try await validateAccess();try current()
            state=try await engine.advance(page,activeRequestID:requestID)
        }
        guard let answer=state.answer else{throw PinEvidenceError.staleRecord}
        try current();try await engine.admit(answer,activeRequestID:requestID)
        let permit=try await cache.permit(),inventory=try await cache.worldSearchSnapshot(permit:permit,maximumEntities:4096)
        let ids=Set(answer.cards.map(\.recordID)+answer.originals.map(\.recordID))
        let rows=inventory.entities.filter{ids.contains($0.projection.recordID)}
        guard Set(rows.map{$0.projection.recordID})==ids else{throw PinEvidenceError.staleRecord}
        try await validateAccess();try await cache.validate(permit);try current()
        if answer.meaning.operation == .originals,previous?.sdk.id==savedContentDisplayedID {savedContentOriginalAnswerID=requestID}
        // These terminal operations leave the previously published cards in place.
        // Search/filter results become settled only when the presenter publishes them.
        switch answer.meaning.operation {
        case .originals, .clarify, .unsupported: savedContentSettledRequest=requestID
        case .search, .filter: break
        }
        return PinSavedContentAnswer(requestID:requestID,answer:answer,owner:session,epoch:epoch,stamp:stamp,engine:engine,rows:rows,replaySnapshot:snapshot,replayQuery:replayQuery,replaySessionID:replayProvider?.replaySessionID)
    }
    /// Call at publication with precisely the order the presenter will show.
    /// A computed answer is never silently made the user's previous answer.
    public func contextForDisplayingSavedContent(_ value:PinSavedContentAnswer,orderedRecordIDs:[String],
        validateAccess:@Sendable ()async throws->Void)async throws->PinSavedContentContext {
        try validateSavedContentAnswer(value);try await validateAccess();try validateSavedContentAnswer(value)
        let context=try await value.engine.contextForDisplayedAnswer(value.answer,orderedRecordIDs:orderedRecordIDs,activeRequestID:value.requestID)
        try await validateAccess();try validateSavedContentAnswer(value)
        if let replaySessionID=value.replaySessionID {
            savedContentHistory.append(try SavedContentReplayPublication(sessionID:replaySessionID,snapshot:value.replaySnapshot,query:value.replayQuery,answer:value.answer,context:context))
        }
        savedContentSettledRequest=value.requestID;savedContentDisplayedID=context.id;savedContentPublishedAnswerID=value.requestID;savedContentPublishedMembers=Set(context.orderedRecordIDs);savedContentOriginalAnswerID=nil
        return PinSavedContentContext(owner:session,sdk:context)
    }
    private func validateSavedContentAnswer(_ value:PinSavedContentAnswer)throws {
        try Task.checkCancellation()
        guard value.owner==session,savedContentRequest==value.requestID,savedContentEpoch==value.epoch,
              questionSynchronizations==0,questionStamp==value.stamp else{throw PinEvidenceError.staleRecord}
    }
    /// Manual card opening also works after a contextual original→Done return.
    /// Recheck the WHOLE bound row and current native identity, not ordinal/ID alone.
    public func savedContentOriginalSources(_ value:PinSavedContentAnswer,recordID:String,
        validateAccess:@Sendable ()async throws->Void)async throws->[PinCore.EvidenceSource] {
        try Task.checkCancellation();try await validateAccess()
        guard let publication=savedContentDisplayedID,savedContentPublishedMembers.contains(recordID),
              value.requestID==savedContentPublishedAnswerID || value.requestID==savedContentOriginalAnswerID,
              value.owner==session,savedContentEnabled,questionSynchronizations==0,questionStamp != nil,
              let row=value.rows.first(where:{$0.projection.recordID==recordID}) else{throw PinEvidenceError.staleRecord}
        let serial=questionSyncSerial,permit=try await cache.permit()
        let current=try await cache.worldSearchSnapshot(permit:permit,maximumEntities:4096)
        guard current.entities.contains(row) else{throw PinEvidenceError.staleRecord}
        let sources=try row.projection.sources.map{source->PinCore.EvidenceSource in
            let expected=PinCore.EvidenceSource(id:source.id,fingerprint:source.fingerprint,revision:source.revision)
            guard savedContentSources[source.id]==expected else{throw PinEvidenceError.staleRecord};return expected
        }
        try await validateAccess();try await cache.validate(permit);try Task.checkCancellation()
        guard serial==questionSyncSerial,questionSynchronizations==0,questionStamp != nil,
              publication==savedContentDisplayedID,savedContentPublishedMembers.contains(recordID),
              value.requestID==savedContentPublishedAnswerID || value.requestID==savedContentOriginalAnswerID else{throw PinEvidenceError.staleRecord}
        return sources.sorted{$0.id<$1.id}
    }
    /// Warm inactivity withdraws transport authority, but retains a settled displayed
    /// parent. Pending or computed-but-unpublished results must still be cancelled.
    /// A delayed pause cannot withdraw a newer request.
    @discardableResult
    public func pauseSavedContentQuestion(ifActiveRequestID requestID:UUID)->Bool {
        guard savedContentRequest==requestID else{return false}
        savedContentReplayProvider?.invalidate(requestID:requestID)
        guard savedContentSettledRequest==requestID,savedContentDisplayedID != nil else {
            cancelSavedContentQuestion(ifActiveRequestID:requestID);return false
        }
        return true
    }
    /// A delayed cancellation for an older submission cannot withdraw a successor.
    public func cancelSavedContentQuestion(ifActiveRequestID requestID:UUID) {
        guard savedContentRequest==requestID else{return}
        savedContentReplayProvider?.invalidate(requestID:savedContentRequest);savedContentHistory=[]
        savedContentRequest=nil;savedContentSettledRequest=nil;savedContentEpoch += 1;savedContentDisplayedID=nil;savedContentPublishedAnswerID=nil;savedContentPublishedMembers=[];savedContentOriginalAnswerID=nil;savedContentEngine=nil
    }
    public func close()async{cancelRetrievedQuestion();questionStamp=nil;questionRows=[:];questionDismissedSources=[];savedContentCatalog=nil;savedContentSources=[:];await cache.close()}
}

/// Authored consumer-fixture input only; never an interpreter or identity policy.
/// A native writer ticket supplies the record ID/revision at the point of admission.
public struct PinRecordedAppointment:Decodable,Sendable {
    public let source:AppointmentSource
    public let replacesSource:AppointmentSource?
    private let appointment:AppointmentProjection
    private let support:[FieldSupport]
    private let documentOnlyWithoutDate:Bool?
    public func draft(ticket:CanonicalWriteTicket,memories:[PhotoMemory])throws->CanonicalAppointmentDraft {
        let sources=Set(support.flatMap(\.anchors).map{PinCore.EvidenceSource(id:$0.source.id,fingerprint:$0.source.fingerprint,revision:$0.source.revision)})
        let scope=MemoryScope(ownerID:"local-photo-owner",namespace:"pin-appointments-v1")
        let snapshot=try PinEvidenceSnapshot(memories:memories,records:[PinRecordPin(id:ticket.id,revision:ticket.nextRevision,sources:sources)],scope:scope)
        let p=MemoryProjection(recordID:ticket.id,recordRevision:ticket.nextRevision,scope:scope,appointment:appointment,support:support,documentOnlyWithoutDate:documentOnlyWithoutDate==true)
        return try PinCanonicalMapping.draft(snapshot.bindEvidence(for:p),primarySourceID:source.id)
    }
}

private struct PinRetainedVisualReceiptReader:VisualEvidenceReader {
    let receipt:VisualEvidenceReceipt
    func read(_ request:VisualEvidenceRequest)async throws->VisualEvidenceReceipt {
        try Task.checkCancellation();try receipt.validate(for:request);return receipt
    }
}
