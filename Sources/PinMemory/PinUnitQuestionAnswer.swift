import Foundation
import PinCore
import IBrain
import IBrainSemantics
import IBrainRetrieval

/// Presentation only: the enclosing admitted unit answer retains its complete proof.
/// A member cannot stand in for the event or grant independent original access.
public struct PinUnitQuestionMember:Sendable {
    public let item:AppointmentItem
    public let selection:String
    public let cancellation:String?
    public let statusSupport:[PinSourceStatusEvidenceAnswer.Support]
    public let sources:Set<PinCore.EvidenceSource>
    public var provesNotCancelled:Bool{false}
}
public struct PinUnitQuestionRow:Sendable {
    public let id:String
    public let membershipUncertain:Bool
    public let conflictingFields:Set<String>
    public let members:[PinUnitQuestionMember]
    public var memberRecordIDs:[String]{members.compactMap(\.item.canonicalRecordID)}
    public var sources:Set<PinCore.EvidenceSource>{Set(members.flatMap(\.sources))}
}
/// Ephemeral presentation of source-local query membership. This never changes
/// the enclosing answer's identity, counts, completeness or original selection.
public struct PinSourceDocumentList:Sendable {
    public struct Row:Sendable {
        public let id:String
        public let queryMembership:String
        public let unresolvedDetails:Set<String>
        public let unresolvedFields:Set<String>
    }
    public let rows:[Row]
    public let listedMembershipResolved:Bool
    public let listedRequestedFieldsEstablished:Bool
    let sdk:SourceDocumentListAssessment
}
/// Unit counts and ordinals stay separate from source/member record counts.
/// This process-local value cannot be decoded as source authority or persisted facts.
public struct PinUnitQuestionAnswer:Sendable {
    public var receipt:DecisionReceipt{pending.sdk.plan.receipt}
    public let requestID:UUID
    public let operation:String
    public let resultUnit:String
    public let rows:[PinUnitQuestionRow]
    public let countLowerBound:Int
    public let countUpperBound:Int
    public let exactCount:Int?
    public let identityResolved:Bool
    public let requestedAnswerComplete:Bool
    public let unresolvedFieldsByUnit:[String:Set<String>]
    public let coverage:PinExhaustiveQuestionCoverage
    public let requestedSourceEvidence:Set<String>
    public let currentPersonalBookingNotEstablished:Bool
    public let admittedClaimReviewComplete:Bool
    public var canAssertNoCancellationInPhotos:Bool{false}
    public var personalCalendarComplete:Bool{false}
    public var orderedMemberRecordIDs:[[String]]{rows.map(\.memberRecordIDs)}
    let pending:PinPreparedExhaustiveAnswer
    let sdk:PinUnitQuestionProof
    public internal(set) var sourceDocumentList:PinSourceDocumentList?=nil
}

/// One actual publication. Display order is unit order, never member order.
/// This context is ephemeral and cannot be decoded from a paired-host payload.
public struct PinDisplayedUnitContext:Sendable {
    public var id:UUID{sdk.id}
    public var answerRequestID:UUID{answer.requestID}
    public var resultUnit:String{answer.resultUnit}
    public var bindingSHA256:String{sdk.bindingSHA256}
    public var answerRows:[PinUnitQuestionRow]{answer.rows}
    public var orderedUnitIDs:[String]{sdk.orderedRows.map{$0.unit.id}}
    public var orderedMemberRecordIDs:[[String]]{sdk.orderedRows.map{$0.unit.members.map{$0.projection.recordID}}}
    let answer:PinUnitQuestionAnswer
    let sdk:DisplayedUnitContext
    var continuation:PinSelectedUnitContinuation?=nil
}
public struct PinUnitQuestionSelection:Sendable {
    public var contextID:UUID{context.id}
    public var ordinal:Int{sdk.ordinal}
    public var contextRows:[PinUnitQuestionRow]{context.answerRows}
    public let row:PinUnitQuestionRow
    /// Every distinct current original, in deterministic source order.
    /// Native PhotoKit/current-access checks remain mandatory before each open.
    public var sources:[PinCore.EvidenceSource]{row.sources.sorted{($0.id,$0.revision,$0.fingerprint)<($1.id,$1.revision,$1.fingerprint)}}
    let context:PinDisplayedUnitContext
    let sdk:DisplayedUnitSelection
}
public struct PinUnitContextualAnswer:Sendable {
    public let requestID:UUID
    public var receipt:DecisionReceipt{sdk.originalReceipt}
    public var operation:String{sdk.operation.rawValue}
    public var requestedSourceEvidence:Set<String>{Set(sdk.requestedSourceEvidence.map(\.rawValue))}
    public let selection:PinUnitQuestionSelection
    let sdk:DisplayedUnitFollowup
}
public enum PinPreparedUnitProductAnswer:Sendable {
    case inventory(PinPreparedExhaustiveAnswer)
    case contextual(PinUnitContextualAnswer)
    case unsupported
}
/// Presentation uses the admitted follow-up's current evidence for its selected
/// unit. The earlier plain list may intentionally contain no status facet.
public enum PinUnitPresentation {
    public static func row(_ original:PinUnitQuestionRow,contextual:PinUnitContextualAnswer?)throws->PinUnitQuestionRow {
        guard let selection=contextual?.selection,selection.row.id==original.id else{return original}
        let current=selection.row
        guard current.membershipUncertain==original.membershipUncertain,current.conflictingFields==original.conflictingFields,
              current.members.count==original.members.count,
              zip(current.members,original.members).allSatisfy({$0.item==$1.item && $0.selection==$1.selection && $0.sources==$1.sources})else{throw PinEvidenceError.staleRecord}
        return current
    }
}
enum PinUnitQuestionProof:Sendable {
    case source(SourceUnitQueryAnswer)
    case inventory(InventoryUnitQueryAnswer)
}
/// Native trust-boundary mapping only. Semantic grouping and count evaluation
/// belong to the SDK; all native member projections must still match exactly.
enum PinUnitNativeBinding {
    static func row(_ unit:SourceOccurrenceUnit,uncertain:Bool,
                    matchedRecordIDs:Set<String>,uncertainRecordIDs:Set<String>,
                    evidence:UnitSourceStatusEvidenceRow?,records:[String:AppointmentItem],
                    scope:MemoryScope)throws->PinUnitQuestionRow {
        guard !unit.id.isEmpty,!unit.members.isEmpty,
              Set(unit.members.map{$0.projection.recordID}).count==unit.members.count else{throw PinEvidenceError.staleRecord}
        if let evidence {
            guard evidence.unitID==unit.id,evidence.membershipUncertain==uncertain,
                  evidence.conflictingFields==unit.conflictingFields,
                  evidence.members.map(\.projection)==unit.members.map(\.projection)else{throw PinEvidenceError.staleRecord}
        }
        let members=try unit.members.enumerated().map { index,member in
            let projection=member.projection
            guard let native=records[projection.recordID],
                  try PinCanonicalMapping.projection(native,scope:scope)==projection else{throw PinEvidenceError.staleRecord}
            let selection=matchedRecordIDs.contains(projection.recordID) ? "matching":uncertainRecordIDs.contains(projection.recordID) ? "uncertain":"excluded"
            let status=evidence?.members[index]
            guard status==nil || status?.selection.rawValue==selection else{throw PinEvidenceError.staleRecord}
            let support=status?.statusSupport.flatMap { field in field.anchors.map { anchor in
                PinSourceStatusEvidenceAnswer.Support(source:.init(id:anchor.source.id,fingerprint:anchor.source.fingerprint,revision:anchor.source.revision),observationID:anchor.observationID,quote:anchor.quote,origin:field.origin.rawValue)
            }} ?? []
            return PinUnitQuestionMember(item:native,selection:selection,cancellation:status?.cancellation.rawValue,statusSupport:support,sources:Set(projection.sources.map{.init(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)}))
        }
        return PinUnitQuestionRow(id:unit.id,membershipUncertain:uncertain,conflictingFields:Set(unit.conflictingFields.map(\.rawValue)),members:members)
    }
}

/// Native capability plus bounded reconstruction evidence. Decoded wire data
/// cannot create the process-local SDK continuation.
struct PinSelectedUnitContinuation:Sendable {
    let engine:LinkedUnitQuestionSession
    let sdk:LinkedUnitContinuationContext
    let publications:[LinkedUnitContinuationPublication]
}
