import Foundation
import PinCore
import IBrainSemantics

/// Inputs for one actual source-model task. They do not grant a write or dispatch.
public struct PinSourceReplacementModelInput:Sendable {
    public let group:PinVisualGroupContext?
    public let ticket:CanonicalWriteTicket?
    public let retainedGroupingInitialReceipt:DecisionReceipt?
}

/// New source interpretation after the photo owner's exact +1 CAS and the
/// native store's source-wide preparation. Old children never become new IDs.
/// Every model stage still uses the host's actual provider and dispatch journal.
public enum PinWholeSourceReplacement {
    /// Finish one proven-complete single child after interrupted delivery.
    /// Allocation is retrieved with its original binding, never repeated.
    /// Both providers must be configured for exact checkpoint replay, whose
    /// decide path returns before any transport or dispatch reservation.
    public static func resumeCompletedSingle(memory:PhotoMemory,originalSHA256:String,transaction:AppointmentGroupReplacementTicket,
                                            receiptCheckpoint:PinCompletedSourceCheckpoint,store:AppointmentStore,permit:AppointmentPermit,selectedSourceValues:Bool=false,initialPolicy:PinInitialSourcePolicy = .compactKeysV1,
                                            provider:@Sendable(PinSourceReplacementModelInput)async throws->PinFreshProductProvider,
                                            check:@Sendable()async throws->Void,
                                            checkpoint:@Sendable(PinUnitSourceEvidence)async throws->Void)async throws->PinUnitSourceEvidence {
        try await check();try Task.checkCancellation()
        guard let status=await store.groupReplacementStatus(transaction.id),status.phase == .sourceAdvanced,
              status.sourceAfter==AppointmentSource(memory),status.allocatedRecordIDs.count==1 else{throw PinEvidenceError.staleRecord}
        try receiptCheckpoint.validateBinding(memory:memory,originalSHA256:originalSHA256,transaction:transaction.id,allocatedRecordIDs:status.allocatedRecordIDs)
        let initialProvider=try await provider(.init(group:nil,ticket:nil,retainedGroupingInitialReceipt:nil))
        guard initialProvider.completedSourceCheckpoint?.transactionID==receiptCheckpoint.transactionID else{throw PinDevelopmentError.sourceNotAllowed}
        let initial=try await PinSealedSourcePipeline.assessInitial(memory,temporalPolicy:.anchoredSpansV9,initialPolicy:initialPolicy,provider:initialProvider)
        try await check();try Task.checkCancellation()
        guard initial.state != .groupingRequired,let candidate=initial.candidate,candidate.disposition == .booking else{throw PinEvidenceError.invalidSupport}
        let tickets=try await store.allocateGroupReplacementChildren(transaction,count:1,groupingTaskSHA256:initial.receipt.requestSHA256,permit:permit)
        guard tickets.map(\.id)==status.allocatedRecordIDs,let ticket=tickets.first else{throw PinEvidenceError.staleRecord}
        let fieldsProvider=try await provider(.init(group:nil,ticket:ticket,retainedGroupingInitialReceipt:nil))
        guard fieldsProvider.completedSourceCheckpoint?.transactionID==receiptCheckpoint.transactionID else{throw PinDevelopmentError.sourceNotAllowed}
        let completed=try await PinSealedSourcePipeline.complete(candidate,memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,contextZone:"America/Los_Angeles",temporalPolicy:.anchoredSpansV9,printedClockNotation:true,initialPolicy:initialPolicy,fieldPolicy:.denseSourceV2,completionCapacity:.denseSourceV1,valueRecovery:.nativeCompletionsV4,combinedSourceFields:true,selectedSourceValues:selectedSourceValues,provider:fieldsProvider)
        try await check();try Task.checkCancellation()
        let draft=try PinSealedSourcePipeline.draft(completed,ticket:ticket,memory:memory)
        let proof=PinUnitSourceEvidence(sourceID:memory.id,initialReceipt:initial.receipt)
        try await checkpoint(proof);try await check();try Task.checkCancellation()
        try await store.stageGroupReplacementChildren([draft],tickets:tickets,transaction:transaction,permit:permit)
        return try await resumeReady(memory:memory,transaction:transaction,proof:proof,store:store,permit:permit,initialPolicy:initialPolicy,check:check)
    }
    public static func compile(memory:PhotoMemory,transaction:AppointmentGroupReplacementTicket,store:AppointmentStore,permit:AppointmentPermit,directVisualGrouping:Bool=false,selectedSourceValues:Bool=false,initialPolicy:PinInitialSourcePolicy = .compactKeysV1,
                               provider:@Sendable(PinSourceReplacementModelInput)async throws->any DecisionProvider,
                               check:@Sendable()async throws->Void,
                               checkpoint:@Sendable(PinUnitSourceEvidence)async throws->Void)async throws->PinUnitSourceEvidence {
        try await compileStages(memory:memory,transaction:transaction,store:store,permit:permit,directVisualGrouping:directVisualGrouping,selectedSourceValues:selectedSourceValues,initialPolicy:initialPolicy,resuming:false,provider:provider,check:check,checkpoint:checkpoint)
    }
    /// Rebuild an interrupted transaction solely from exact completed stages.
    /// The existing native allocator verifies count/digest and returns its IDs.
    public static func resumeRecordedStages(memory:PhotoMemory,originalSHA256:String,transaction:AppointmentGroupReplacementTicket,stages:PinSourceStageJournal,store:AppointmentStore,permit:AppointmentPermit,directVisualGrouping:Bool=false,selectedSourceValues:Bool=false,initialPolicy:PinInitialSourcePolicy = .compactKeysV1,
                               provider:@Sendable(PinSourceReplacementModelInput)async throws->PinFreshProductProvider,
                               check:@Sendable()async throws->Void,
                               checkpoint:@Sendable(PinUnitSourceEvidence)async throws->Void)async throws->PinUnitSourceEvidence {
        guard stages.replayOnly else{throw PinDevelopmentError.sourceNotAllowed}
        try stages.validateBinding(memory:memory,originalSHA256:originalSHA256,transaction:transaction.id)
        return try await compileStages(memory:memory,transaction:transaction,store:store,permit:permit,directVisualGrouping:directVisualGrouping,selectedSourceValues:selectedSourceValues,initialPolicy:initialPolicy,resuming:true,provider:{input in
            let value=try await provider(input)
            guard value.sourceStages === stages else{throw PinDevelopmentError.sourceNotAllowed}
            return value
        },check:check,checkpoint:checkpoint)
    }
    private static func compileStages(memory:PhotoMemory,transaction:AppointmentGroupReplacementTicket,store:AppointmentStore,permit:AppointmentPermit,directVisualGrouping:Bool,selectedSourceValues:Bool,initialPolicy:PinInitialSourcePolicy,resuming:Bool,
                               provider:@Sendable(PinSourceReplacementModelInput)async throws->any DecisionProvider,
                               check:@Sendable()async throws->Void,
                               checkpoint:@Sendable(PinUnitSourceEvidence)async throws->Void)async throws->PinUnitSourceEvidence {
        try await check();try Task.checkCancellation()
        guard let status=await store.groupReplacementStatus(transaction.id),status.phase == .sourceAdvanced,
              status.sourceAfter==AppointmentSource(memory),(resuming || status.allocatedRecordIDs.isEmpty) else{throw PinEvidenceError.staleRecord}
        // A validated multi-document visual receipt already requires grouping.
        // The grouping interpreter still proves booking count and every scope;
        // every child still needs its own initial and complete field receipts.
        let direct=try directVisualGrouping && (memory.visualReading?.validatedReceipt().visibleDocumentCount ?? 0)>1
        let assessment:VisualSourcePreparationAssessment?
        if direct{assessment=nil}else{
            let initialProvider=try await provider(.init(group:nil,ticket:nil,retainedGroupingInitialReceipt:nil))
            assessment=try await PinSealedSourcePipeline.assessInitial(memory,temporalPolicy:.anchoredSpansV9,initialPolicy:initialPolicy,provider:initialProvider)
        }
        try await check();try Task.checkCancellation()
        let groups:[PinVisualGroupContext],allocationSHA:String
        if let visual=memory.visualReading,try visual.validatedReceipt().visibleDocumentCount>1 {
            guard direct || assessment?.state == .groupingRequired else{throw PinEvidenceError.invalidSupport}
            let request=try PinVisualReadingProjection.groupingRequest(memory),task=try BoundedVisualSourceGrouper.task(request)
            let groupingProvider=try await provider(.init(group:nil,ticket:nil,retainedGroupingInitialReceipt:nil))
            let raw=try await groupingProvider.decide(task)
            try await check();try Task.checkCancellation()
            let grouping=try BoundedVisualSourceGrouper.compile(request,task:task,receipt:raw)
            groups=try grouping.scopes.map{try PinVisualGroupContext(memory:memory,receipt:raw,ordinal:$0.ordinal)}
            allocationSHA=try task.digest()
        }else if let assessment,assessment.state == .groupingRequired {
            let request=try PinRetainedOCRGrouping.request(memory:memory,initialReceipt:assessment.receipt,revisionPolicy:.currentSourceV2),task=try RetainedOCRSourceGrouper.task(request)
            let groupingProvider=try await provider(.init(group:nil,ticket:nil,retainedGroupingInitialReceipt:assessment.receipt))
            let raw=try await groupingProvider.decide(task)
            try await check();try Task.checkCancellation()
            let grouping=try RetainedOCRSourceGrouper.compile(request,task:task,receipt:raw)
            groups=try grouping.scopes.map{try PinVisualGroupContext(memory:memory,initialReceipt:assessment.receipt,groupingReceipt:raw,ordinal:$0.ordinal,revisionPolicy:.currentSourceV2)}
            allocationSHA=try task.digest()
        }else {
            guard let assessment,assessment.candidate?.disposition == .booking else{throw PinEvidenceError.invalidSupport}
            groups=[];allocationSHA=assessment.receipt.requestSHA256
        }
        try await check();try Task.checkCancellation()
        let tickets=try await store.allocateGroupReplacementChildren(transaction,count:groups.isEmpty ? 1:groups.count,groupingTaskSHA256:allocationSHA,permit:permit)
        var drafts:[CanonicalAppointmentDraft]=[],outcomes:[PinGroupedSourceResult.Outcome]=[]
        for (index,ticket) in tickets.enumerated() {
            try await check();try Task.checkCancellation()
            let group=groups.isEmpty ? nil:groups[index]
            let candidate:AppointmentCandidate,initialReceipt:DecisionReceipt
            if let group {
                let childProvider=try await provider(.init(group:group,ticket:nil,retainedGroupingInitialReceipt:nil))
                let child=try await PinSealedSourcePipeline.assessGroup(memory,group:group,provider:childProvider)
                try await check();try Task.checkCancellation()
                guard let current=child.candidate,current.disposition == .booking else{throw PinEvidenceError.invalidSupport}
                candidate=current;initialReceipt=child.receipt
            }else {
                guard let assessment,let current=assessment.candidate,current.disposition == .booking else{throw PinEvidenceError.invalidSupport}
                candidate=current;initialReceipt=assessment.receipt
            }
            let fieldsProvider=try await provider(.init(group:group,ticket:ticket,retainedGroupingInitialReceipt:nil))
            let completed=try await PinSealedSourcePipeline.complete(candidate,memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,contextZone:"America/Los_Angeles",temporalPolicy:.anchoredSpansV9,groupContext:group,printedClockNotation:true,initialPolicy:initialPolicy,fieldPolicy:.denseSourceV2,completionCapacity:.denseSourceV1,valueRecovery:.nativeCompletionsV4,combinedSourceFields:true,selectedSourceValues:selectedSourceValues,provider:fieldsProvider)
            try await check();try Task.checkCancellation()
            drafts.append(try PinSealedSourcePipeline.draft(completed,ticket:ticket,memory:memory))
            if let group{outcomes.append(.init(group:group,initialReceipt:initialReceipt,recordID:ticket.id))}
        }
        let proof:PinUnitSourceEvidence
        if groups.isEmpty {
            guard let assessment else{throw PinEvidenceError.invalidSupport}
            proof=PinUnitSourceEvidence(sourceID:memory.id,initialReceipt:assessment.receipt)
        }else{proof=PinUnitSourceEvidence(sourceID:memory.id,grouped:PinGroupedSourceResult(outcomes:outcomes))}
        // Persist the exact complete proof before the native ready/commit write.
        // Receipt replay may rebuild a pre-ready transaction; proof alone grants no authority.
        try await check();try await checkpoint(proof);try await check();try Task.checkCancellation()
        try await store.stageGroupReplacementChildren(drafts,tickets:tickets,transaction:transaction,permit:permit)
        return try await resumeReady(memory:memory,transaction:transaction,proof:proof,store:store,permit:permit,initialPolicy:initialPolicy,check:check)
    }
    /// No model work, ID allocation or budget renewal. Only a native ready
    /// checkpoint can commit on reopen; incomplete stages remain inaccessible.
    public static func resumeReady(memory:PhotoMemory,transaction:AppointmentGroupReplacementTicket,proof:PinUnitSourceEvidence,store:AppointmentStore,permit:AppointmentPermit,initialPolicy:PinInitialSourcePolicy = .compactKeysV1,check:@Sendable()async throws->Void)async throws->PinUnitSourceEvidence {
        try await check();try Task.checkCancellation()
        guard let status=await store.groupReplacementStatus(transaction.id),status.phase == .readyToCommit,status.sourceAfter==AppointmentSource(memory) else{throw PinEvidenceError.staleRecord}
        let candidates=try await store.groupReplacementCandidateRecords(transaction,permit:permit)
        _=try PinProductUnitEvidence(sources:[proof]).prepare(memories:[memory],records:candidates,unit:.documents,initialPolicy:initialPolicy)
        try await check();try Task.checkCancellation()
        let rows=try await store.commitGroupReplacement(transaction,permit:permit)
        try await check();try Task.checkCancellation()
        _=try PinProductUnitEvidence(sources:[proof]).prepare(memories:[memory],records:rows,unit:.documents,initialPolicy:initialPolicy)
        return proof
    }
}
