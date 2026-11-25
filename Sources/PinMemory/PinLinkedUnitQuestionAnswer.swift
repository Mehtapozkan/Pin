import Foundation
import PinCore
import IBrain
import IBrainSemantics
import IBrainRetrieval

/// Presentation of an admitted whole displayed unit. Expansions retain their
/// own sources; a value from one member never becomes another ticket's fact.
public struct PinLinkedUnitQuestionRow:Sendable {
    public let selection:PinUnitQuestionSelection
    public let expansions:[LinkedEvidenceExpansion]
    public let gaps:[LinkedUnitAnswerGap]
    public let selectedMemberPath:LinkedUnitMemberPath?
    public let scopedDetails:[LinkedUnitScopedDetail]?
    /// The selection retains the full parent proof; these IDs alone answer a member request.
    public var answerMemberRecordIDs:[String] {
        selectedMemberPath.map{[$0.recordID]} ?? selection.row.memberRecordIDs
    }
}

/// Process-local handle, never decoded as correction, source or PhotoKit authority.
public struct PinLinkedUnitContextualAnswer:Sendable {
    public let requestID:UUID
    public let rows:[PinLinkedUnitQuestionRow]
    public var receipt:DecisionReceipt{sdk.plan.originalReceipt}
    public var operation:String{sdk.plan.operation.rawValue}
    public var requestedDetails:Set<String>{Set(sdk.plan.requestedDetails.map(\.rawValue))}
    public var requestedChanges:Set<String>{Set(sdk.plan.requestedChanges.map(\.rawValue))}
    public var requestedSourceEvidence:Set<String>{Set(sdk.plan.requestedSourceEvidence.map(\.rawValue))}
    public var allRequestedValuesEstablished:Bool{sdk.allRequestedValuesEstablished}
    public var allSelectedMemberReadsComplete:Bool{sdk.allSelectedMemberReadsComplete}
    public var personalCalendarComplete:Bool{false}
    public var locationExtent:String {sdk.plan.locationExtent.rawValue}
    public var evidenceScope:String{sdk.plan.evidenceScope.rawValue}
    public var contextRowsForPublication:[PinUnitQuestionRow]{context.answerRows}
    public var contextID:UUID{context.id}
    public var originalSelections:[PinUnitQuestionSelection]{sdk.plan.operation.requestsOriginals ? rows.map(\.selection):[]}
    let context:PinDisplayedUnitContext
    let sdk:LinkedUnitQuestionAnswer
    let engine:LinkedUnitQuestionSession
    let submissionEpoch:Int
    let generation:Int
    let stamp:String
    var selectedUnitContinuationEnabled:Bool=false
}

public enum PinPreparedLinkedUnitProductAnswer:Sendable {
    case inventory(PinPreparedExhaustiveAnswer)
    case contextual(PinLinkedUnitContextualAnswer)
    case unsupported
}

/// Use the admitted contextual facets while preserving the entire displayed row.
/// A different selection, member, claim or source cannot enter through rendering.
public enum PinLinkedUnitPresentation {
    public static func row(_ original:PinUnitQuestionRow,contextual:PinLinkedUnitContextualAnswer?)throws->PinUnitQuestionRow {
        guard let current=contextual?.rows.first(where:{$0.selection.row.id==original.id})?.selection.row else{return original}
        guard current.membershipUncertain==original.membershipUncertain,current.conflictingFields==original.conflictingFields,
              current.members.count==original.members.count,
              zip(current.members,original.members).allSatisfy({$0.item==$1.item && $0.selection==$1.selection && $0.sources==$1.sources})else{throw PinEvidenceError.staleRecord}
        return current
    }
}
