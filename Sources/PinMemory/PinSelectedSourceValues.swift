import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Persisted in the existing canonical observation, never a second fact store.
/// Its retained context is provenance, not independent authority. The host must
/// reconstruct the source/role context from native envelopes and original receipts.
public struct PinSelectedSourceValueProof:Codable,Sendable {
    public let taskID:String
    public let context:SelectedSourceFieldValuesContext
    public let receipt:DecisionReceipt?
    public let result:SelectedSourceFieldValuesResult

    public init(taskID:String,context:SelectedSourceFieldValuesContext,receipt:DecisionReceipt?,result:SelectedSourceFieldValuesResult)throws {
        try SelectedSourceFieldValuesInterpreter.validate(result,receipt:receipt,id:taskID,context:context)
        self.taskID=taskID;self.context=context;self.receipt=receipt;self.result=result
    }
    public func encoded()throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public func validate()throws {
        try SelectedSourceFieldValuesInterpreter.validate(result,receipt:receipt,id:taskID,context:context)
    }
    /// Synchronous retained consistency only. Current source access/revision is
    /// separately checked by PinEvidenceSnapshot; independent role/receipt replay
    /// remains mandatory at the paired host boundary.
    static func retained(_ record:AppointmentItem)throws->Self? {
        guard let data=record.observation.sourceValueProof else{return nil}
        guard data.count<=1_048_576 else{throw PinEvidenceError.invalidRecord}
        let proof=try JSONDecoder().decode(Self.self,from:data);try proof.validate()
        let p=proof.result.projection
        guard record.canonicalRecordID==p.recordID,let revision=record.canonicalRevision,revision>=p.recordRevision,
              Set(record.allSources.map{SourceReference(id:$0.id,revision:$0.revision,fingerprint:$0.fingerprint)})==p.sources else{throw PinEvidenceError.staleRecord}
        let obs=record.observation
        for field in [AppointmentField.title,.performer,.venueAddress] {
            let expected=p.support.first(where:{$0.field==field})
            let saved=record.semanticSupport?.first(where:{$0.field==field.rawValue})
            if saved?.origin=="domainCorrection",saved?.extractorVersion=="pin-owner-correction/1"{continue}
            let value:String?,wanted:String?
            switch field {
            case .title:value=obs.title;wanted=p.appointment.title
            case .performer:value=obs.performer;wanted=p.appointment.performer
            default:value=obs.address;wanted=p.appointment.venueAddress
            }
            let converted=try expected.map{try JSONDecoder().decode(AppointmentSemanticField.self,from:JSONEncoder().encode($0))}
            guard value==wanted,saved==converted else{throw PinEvidenceError.invalidRecord}
        }
        return proof
    }
}
