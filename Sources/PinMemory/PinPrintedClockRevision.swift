import Foundation
import PinCore
import IBrain
import IBrainSemantics

public struct PinPrintedClockRepairInput:Codable,Sendable {
    public let context:TemporalRoleExplanationContext
    public let memory:PhotoMemory
    public let record:AppointmentItem
    public let group:PinVisualGroupContext?
    public init(context:TemporalRoleExplanationContext,memory:PhotoMemory,record:AppointmentItem,group:PinVisualGroupContext?=nil) {
        self.context=context;self.memory=memory;self.record=record;self.group=group
    }
    public func task()throws->ChoiceTask? {
        try PinPrintedClockRevision.task(context:context,memory:memory,record:record,accessGranted:true,group:group)
    }
}

/// A new clock decision over the actual current record. Old initial receipts
/// retain their original revision; only the native CAS writer advances it.
public enum PinPrintedClockRevision {
    public static func taskID(_ context:TemporalRoleExplanationContext)->String {
        context.temporalTaskID.replacingOccurrences(of:"pin-source-start-",with:"pin-source-clock-notation-")
    }
    private static func validate(_ context:TemporalRoleExplanationContext,memory:PhotoMemory,record:AppointmentItem,accessGranted:Bool,group:PinVisualGroupContext?)throws {
        guard accessGranted,!record.dismissed,record.allSources==[AppointmentSource(memory)],
              record.canonicalRecordID==context.current.recordID,record.canonicalRevision==context.current.recordRevision else{throw PinEvidenceError.staleRecord}
        let full=try PinSealedSourcePipeline.request(memory,temporalPolicy:context.effectiveTemporalPolicy)
        let selected=try group?.evidence(memory:memory)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        guard context.source==(selected?.source ?? full.source),try encoder.encode(context.lines)==encoder.encode(selected?.lines ?? full.lines),
              try PinCanonicalMapping.projection(record,scope:full.source.scope)==context.current else{throw PinEvidenceError.staleRecord}
        try group?.validate(memory:memory,projection:context.current)
    }
    public static func task(context:TemporalRoleExplanationContext,memory:PhotoMemory,record:AppointmentItem,accessGranted:Bool,group:PinVisualGroupContext?=nil)throws->ChoiceTask? {
        try validate(context,memory:memory,record:record,accessGranted:accessGranted,group:group)
        return try PrintedClockNotationInterpreter.task(id:taskID(context),context:context)
    }
    public static func draft(context:TemporalRoleExplanationContext,receipt:DecisionReceipt,memory:PhotoMemory,record:AppointmentItem,ticket:CanonicalWriteTicket,accessGranted:Bool,group:PinVisualGroupContext?=nil)throws->CanonicalAppointmentDraft? {
        try validate(context,memory:memory,record:record,accessGranted:accessGranted,group:group)
        guard ticket.id==record.canonicalRecordID,ticket.nextRevision==(record.canonicalRevision ?? 0)+1 else{throw PinEvidenceError.staleRecord}
        let result=try PrintedClockNotationInterpreter.compile(receipt,id:taskID(context),context:context)
        if result==context.current{return nil}
        try group?.validate(memory:memory,projection:result)
        let revised=MemoryProjection(recordID:ticket.id,recordRevision:ticket.nextRevision,scope:result.scope,appointment:result.appointment,support:result.support,documentOnlyWithoutDate:result.documentOnlyWithoutDate==true)
        let snapshot=try PinEvidenceSnapshot(memories:[memory],records:[PinRecordPin(id:ticket.id,revision:ticket.nextRevision,sources:[PinCore.EvidenceSource(memory)])],scope:result.scope)
        return try PinCanonicalMapping.draft(snapshot.bindEvidence(for:revised),primarySourceID:memory.id)
    }
}
