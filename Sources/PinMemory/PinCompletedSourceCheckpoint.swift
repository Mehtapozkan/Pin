import Foundation
import PinCore
import IBrainSemantics

/// Terminal transport receipts for one already allocated replacement child.
/// The optional selected-values stage is bound to the same completed source.
/// This is never permission to dispatch, allocate another ID, or alter evidence.
public struct PinCompletedSourceCheckpoint:Codable,Sendable {
    public struct Stage:Codable,Sendable {
        public let originalEnvelope:Data
        public let receipt:DecisionReceipt
        public init(originalEnvelope:Data,receipt:DecisionReceipt){self.originalEnvelope=originalEnvelope;self.receipt=receipt}
    }
    public let schema:Int
    public let transactionID:UUID
    public let initial:Stage,fields:Stage
    public let selectedValues:Stage?
    public init(transactionID:UUID,initial:Stage,fields:Stage,selectedValues:Stage?=nil){schema=1;self.transactionID=transactionID;self.initial=initial;self.fields=fields;self.selectedValues=selectedValues}

    private func objects()throws->[[String:Any]] {
        guard schema==1 else{throw PinDevelopmentError.invalidReceipt}
        let values=try ([initial,fields]+(selectedValues.map{[$0]} ?? [])).map{stage->[String:Any] in
            guard stage.originalEnvelope.count<=1_048_576,
                  let value=try JSONSerialization.jsonObject(with:stage.originalEnvelope)as?[String:Any],
                  let session=value["session"]as?String,UUID(uuidString:session) != nil,
                  let nonce=value["questionRequestID"]as?String,UUID(uuidString:nonce) != nil,
                  let memory=value["memory"]as?[String:Any],let revision=memory["revision"]as?Int,revision>=2,memory["visualReading"] != nil,
                  let hash=value["originalSHA256"]as?String,hash.count==64,hash.allSatisfy(\.isHexDigit),
                  value["contextZone"]as?String=="America/Los_Angeles",
                  value["unitSourceRecovery"]as?Bool==true,
                  value["sourceFieldPolicy"]as?String=="denseSourceV2",
                  value["combinedSourceFields"]as?Bool==true,
                  ["groupContext","clockRepair","authority","parentPublication","retainedGroupingInitialReceipt"].allSatisfy({value[$0]==nil}),
                  stage.receipt.provider=="pin-native-subscription",stage.receipt.model=="gpt-6.1-sol",
                  stage.receipt.answers.values.allSatisfy({$0.confidence==nil && $0.probabilities==nil})else{throw PinDevelopmentError.sourceNotAllowed}
            return value
        }
        guard values[0]["recordID"]==nil,values[0]["recordRevision"]==nil,
              let record=values[1]["recordID"]as?String,!record.isEmpty,values[1]["recordRevision"]as?Int==1,
              let a=values[0]["memory"]as?[String:Any],let b=values[1]["memory"]as?[String:Any],NSDictionary(dictionary:a).isEqual(to:b),
              values[0]["originalSHA256"]as?String==values[1]["originalSHA256"]as?String else{throw PinDevelopmentError.invalidReceipt}
        if values.count==3 {
            let a=values[1],b=values[2]
            guard [values[0],a,b].allSatisfy({$0["selectedSourceValues"]as?Bool==true}),
                  b["recordID"]as?String==a["recordID"]as?String,b["recordRevision"]as?Int==a["recordRevision"]as?Int,
                  b["originalSHA256"]as?String==a["originalSHA256"]as?String,
                  let am=a["memory"]as?[String:Any],let bm=b["memory"]as?[String:Any],NSDictionary(dictionary:am).isEqual(to:bm)
            else{throw PinDevelopmentError.invalidReceipt}
        }
        return values
    }

    public func validateBinding(memory:PhotoMemory,originalSHA256:String,transaction:UUID,allocatedRecordIDs:[String])throws {
        let values=try objects()
        guard transactionID==transaction,allocatedRecordIDs.count==1,
              values[1]["recordID"]as?String==allocatedRecordIDs[0],
              values[0]["originalSHA256"]as?String==originalSHA256,
              let encoded=values[0]["memory"],
              try JSONDecoder().decode(PhotoMemory.self,from:JSONSerialization.data(withJSONObject:encoded))==memory,
              try memory.visualReading?.validatedReceipt().visibleDocumentCount==1 else{throw PinDevelopmentError.sourceNotAllowed}
    }

    /// Rebuild the ordinary current envelope. Only transport session/UI nonce
    /// may vary; complete memory, ticket, policy and actual task remain exact.
    public func validatedReceipt(currentEnvelope:Data,task:ChoiceTask)throws->DecisionReceipt {
        let values=try objects()
        guard currentEnvelope.count<=1_048_576,
              var current=try JSONSerialization.jsonObject(with:currentEnvelope)as?[String:Any],
              let nonce=current["questionRequestID"]as?String,UUID(uuidString:nonce) != nil,
              let session=current["session"]as?String,UUID(uuidString:session) != nil else{throw PinDevelopmentError.invalidReceipt}
        let index:Int
        if task.version=="appointment-visual-observations-v8/temporal-v9"{index=0}
        else if task.version=="observed-text-fields-combined-v1/dense-source-v1"{index=1}
        else if task.version==SelectedSourceFieldValuesInterpreter.version,selectedValues != nil{index=2}
        else{throw PinDevelopmentError.sourceNotAllowed}
        var saved=values[index]
        for key in ["session","questionRequestID"]{saved.removeValue(forKey:key);current.removeValue(forKey:key)}
        guard NSDictionary(dictionary:saved).isEqual(to:current),let encoded=current["task"] else{throw PinDevelopmentError.invalidReceipt}
        let original=try JSONDecoder().decode(ChoiceTask.self,from:JSONSerialization.data(withJSONObject:encoded))
        guard original.id==task.id,original.version==task.version,try original.digest()==task.digest()else{throw PinDevelopmentError.invalidReceipt}
        let receipt=(index==0 ? initial:index==1 ? fields:selectedValues!).receipt
        try receipt.validate(for:task)
        return receipt
    }
}
