import Foundation
import PinCore
import IBrain
import IBrainRetrieval

/// An actual displayed unit's member order. This is an opaque native read
/// handle, not an interpreted question, flat-record answer or PhotoKit grant.
public struct PinDisplayedMemberContext:Sendable {
    public var parentContextID:UUID {parent.contextID}
    public var parentBindingSHA256:String {parent.context.bindingSHA256}
    public var unitID:String {parent.row.id}
    public var orderedRecordIDs:[String] {displayed.orderedRecordIDs}
    public var members:[PinUnitQuestionMember] {parent.row.members}
    let parent:PinUnitQuestionSelection
    let engine:LinkedAppointmentContextSession
    let prepared:PreparedLinkedAppointmentContext
    let displayed:LinkedDisplayedContext
    let generation:Int
    let stamp:String
}

/// Selected by an explicitly bound native ordinal. Natural language requires
/// its own genuine supported interpretation; this type does not supply one.
public struct PinDisplayedMemberSelection:Sendable {
    public let ordinal:Int
    public var unitID:String {context.unitID}
    public var member:PinUnitQuestionMember {context.members[ordinal-1]}
    public var parentContextID:UUID {context.parentContextID}
    let context:PinDisplayedMemberContext
    let sdk:LinkedRecordSelection
}

/// Current saved facts for exactly one member, with the whole parent and
/// selected member re-admitted. Printed/current policy is a separate boundary;
/// a corrected saved value is never automatically described as printed text.
public struct PinDisplayedMemberFacts:Sendable {
    public var item:AppointmentItem {selection.member.item}
    public let projection:MemoryProjection
    public let selection:PinDisplayedMemberSelection
    let expansion:LinkedEvidenceExpansion
}
