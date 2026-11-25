import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Derived attempt evidence, never a replacement record store. Every use
/// reconstructs against complete CURRENT native sources and canonical records.
public struct PinUnitSourceEvidence:Codable,Sendable {
    public let sourceID:String
    /// Explicit trusted policy. Absent in archived proofs means legacy v1.
    public let sourceOccurrencePolicy:String?
    public var selectedOccurrencePolicy:SourceOccurrenceContextPolicy {get throws {
        guard sourceOccurrencePolicy==nil || sourceOccurrencePolicy=="jointIdentityV3" else{throw PinEvidenceError.invalidSupport}
        return sourceOccurrencePolicy=="jointIdentityV3" ? .jointIdentityV3:.legacyV1
    }}
    public func selectingOccurrencePolicy(_ policy:String?)throws->Self {
        guard localRelationTask==nil,localRelationReceipt==nil,policy==nil || (policy=="jointIdentityV3" && grouped != nil) else{throw PinEvidenceError.invalidSupport}
        return Self(sourceID:sourceID,initialReceipt:initialReceipt,grouped:grouped,sourceOccurrencePolicy:policy)
    }
    public let initialReceipt:DecisionReceipt?
    public let grouped:PinGroupedSourceResult?
    public let localRelationTask:ChoiceTask?
    public let localRelationReceipt:DecisionReceipt?
    public init(sourceID:String,initialReceipt:DecisionReceipt?=nil,grouped:PinGroupedSourceResult?=nil,localRelationTask:ChoiceTask?=nil,localRelationReceipt:DecisionReceipt?=nil,sourceOccurrencePolicy:String?=nil) {
        self.sourceID=sourceID;self.sourceOccurrencePolicy=sourceOccurrencePolicy;self.initialReceipt=initialReceipt;self.grouped=grouped
        self.localRelationTask=localRelationTask;self.localRelationReceipt=localRelationReceipt
    }
    /// Shape/current-source adapter only, NEVER confirmation authority. Native
    /// callers revalidate the owning writer history; the paired host verifies
    /// its authenticated witness and the original baseline independently.
    private static func currentNativeCorrectionCandidate(_ row:AppointmentItem)->Bool {
        guard !row.observation.ownerCorrectionFields.isEmpty,let revision=row.canonicalRevision,let before=row.previousEvidence,
              before.revision>0,before.revision<Int.max,revision==before.revision+1,before.sources==row.allSources else{return false}
        return row.semanticSupport?.contains(where:{$0.origin=="domainCorrection" && $0.extractorVersion=="pin-owner-correction/1"})==true
    }
    public func occurrenceRequest(memory:PhotoMemory,records:[AppointmentItem])throws->SourceOccurrenceRequest {
        guard memory.id==sourceID,initialReceipt==nil,let grouped,let first=grouped.outcomes.first else{throw PinEvidenceError.invalidSupport}
        try grouped.validate(memory:memory,records:records)
        let grouping=try first.group.grouping(memory:memory)
        let source=try PinSealedSourcePipeline.request(memory,temporalPolicy:.anchoredSpansV9).source
        let rows=records.filter{!$0.dismissed && $0.allSources.contains(AppointmentSource(memory))}
        guard grouped.outcomes.allSatisfy({$0.recordID != nil}),rows.count==grouped.outcomes.count,
              Set(rows.compactMap(\.canonicalRecordID))==Set(grouped.outcomes.compactMap(\.recordID))else{throw PinEvidenceError.invalidSupport}
        let members=try grouped.outcomes.map{outcome->SourceOccurrenceMember in
            guard let row=rows.first(where:{$0.canonicalRecordID==outcome.recordID}),(row.previousEvidence==nil || Self.currentNativeCorrectionCandidate(row)),row.allSources.count==1 else{throw PinEvidenceError.staleRecord}
            return SourceOccurrenceMember(groupOrdinal:outcome.group.ordinal,projection:try PinCanonicalMapping.projection(row,scope:source.scope))
        }
        return SourceOccurrenceRequest(taskID:"pin-source-occurrences-"+sourceID+"-"+String(memory.revision),source:source,grouping:grouping,members:members,contextPolicy:try selectedOccurrencePolicy)
    }
    public func evidence(memory:PhotoMemory,records:[AppointmentItem],unit:AppointmentResultUnit,initialPolicy:PinInitialSourcePolicy)throws->InventorySourceUnitEvidence {
        guard memory.id==sourceID else{throw PinEvidenceError.staleRecord}
        if grouped != nil {
            let request=try occurrenceRequest(memory:memory,records:records)
            if unit == .documents{return .grouped(request:request,relationTask:nil,relationReceipt:nil)}
            guard let localRelationTask,let localRelationReceipt else{throw PinFreshProductFailure.unresolvedEventUnits}
            _=try SourceOccurrenceInterpreter.compile(request,task:localRelationTask,receipt:localRelationReceipt)
            return .grouped(request:request,relationTask:localRelationTask,relationReceipt:localRelationReceipt)
        }
        guard let initialReceipt,localRelationTask==nil,localRelationReceipt==nil else{throw PinEvidenceError.invalidSupport}
        let rows=records.filter{!$0.dismissed && $0.allSources.contains(AppointmentSource(memory))}
        guard rows.count==1,let row=rows.first,row.allSources.count==1,(row.previousEvidence==nil || Self.currentNativeCorrectionCandidate(row)) else{throw PinEvidenceError.invalidSupport}
        let request=try PinSealedSourcePipeline.request(memory,temporalPolicy:.anchoredSpansV9)
        let task=try initialPolicy.selected(for:memory).task(request)
        return .single(SingleDocumentUnitEvidence(initialRequest:request,initialTask:task,initialReceipt:initialReceipt,projection:try PinCanonicalMapping.projection(row,scope:request.source.scope)))
    }
}
public struct PinProductUnitEvidence:Codable,Sendable {
    public let sources:[PinUnitSourceEvidence]
    public let crossSourceTask:ChoiceTask?
    public let crossSourceReceipt:DecisionReceipt?
    public init(sources:[PinUnitSourceEvidence],crossSourceTask:ChoiceTask?=nil,crossSourceReceipt:DecisionReceipt?=nil) {
        self.sources=sources;self.crossSourceTask=crossSourceTask;self.crossSourceReceipt=crossSourceReceipt
    }
    /// Select a versioned semantic relation contract; never infer it from a receipt.
    public static func crossSourceRelationTask(prepared:PreparedInventoryUnits,documentIdentityV1:Bool=false)throws->ChoiceTask? {
        if prepared.resultUnit == .documents {
            return documentIdentityV1 ? try InventoryDocumentIdentityInterpreter.task(id:"pin-inventory-documents",prepared:prepared):nil
        }
        return prepared.identityResolved ? try InventoryOccurrenceInterpreter.task(id:"pin-inventory-occurrences",prepared:prepared):nil
    }
    public static func documentIdentityPolicy(prepared:PreparedInventoryUnits,enabled:Bool)->InventoryDocumentIdentityPolicy {
        enabled && prepared.resultUnit == .documents ? .crossSourceV1:.sourceLocalV1
    }
    public func prepare(memories:[PhotoMemory],records:[AppointmentItem],unit:AppointmentResultUnit,initialPolicy:PinInitialSourcePolicy)throws->PreparedInventoryUnits {
        guard !sources.isEmpty,sources.count==memories.count,Set(sources.map(\.sourceID))==Set(memories.map(\.id)),Set(sources.map(\.sourceID)).count==sources.count,
              Set(records.compactMap(\.canonicalRecordID)).count==records.count,records.allSatisfy({!$0.dismissed})else{throw PinEvidenceError.invalidSupport}
        // Receipt arrays are binding material. Deterministic SOURCE order is
        // shared by phone and host; individual raw receipts are never normalized.
        let evidence=try sources.sorted{$0.sourceID<$1.sourceID}.map{proof in
            try proof.evidence(memory:memories.first{$0.id==proof.sourceID}!,records:records,unit:unit,initialPolicy:initialPolicy)
        }
        let prepared=try InventorySourceUnitCompiler.prepare(evidence,unit:unit)
        guard Set(prepared.units.flatMap{$0.members.map{$0.projection.recordID}})==Set(records.compactMap(\.canonicalRecordID))else{throw PinEvidenceError.invalidSupport}
        return prepared
    }
}
