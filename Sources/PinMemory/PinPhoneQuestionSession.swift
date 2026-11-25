import Foundation
import CryptoKit
import IBrainSemantics

/// A separate fictional-phone user session. The Mac reconstructs every SDK
/// task from sealed native records and actual completed receipts. These hashes
/// are a client-side privacy boundary, never a second factual record store.
public struct PinPhoneQuestionSession:Codable,Sendable {
    public let id:UUID
    public let allowedAppointmentSHA256:Set<String>
    public var authorityPolicy:String? = nil
    public var sealedSession:PinSealedTestSession? = nil
    public var allowedTextSHA256:Set<String>? = nil
    public func validate()throws {
        try validateAuthorityPolicy()
        if authorityPolicy=="native-sealed-fixture-envelope-v2"{
            guard let sealedSession,sealedSession.id==id,allowedAppointmentSHA256.isEmpty else{throw PinDevelopmentError.configuration};try sealedSession.validate();return
        }
        guard sealedSession==nil else{throw PinDevelopmentError.configuration}
        guard (1...3).contains(allowedAppointmentSHA256.count),allowedAppointmentSHA256.allSatisfy({$0.count==64 && $0.allSatisfy{("0123456789abcdef").contains($0)}})else{throw PinDevelopmentError.configuration}
    }
    func validateAuthorityPolicy()throws {
        if authorityPolicy=="native-sealed-fixture-envelope-v2" {
            guard sealedSession != nil,allowedTextSHA256==nil else{throw PinDevelopmentError.configuration};return
        }
        if let authorityPolicy {
            guard authorityPolicy=="native-fixture-envelope-v1",let hashes=allowedTextSHA256,(1...3).contains(hashes.count),hashes.allSatisfy({$0.count==64 && $0.allSatisfy{("0123456789abcdef").contains($0)}})else{throw PinDevelopmentError.configuration}
        }else if allowedTextSHA256 != nil {throw PinDevelopmentError.configuration}
    }
    static func digest(_ value:Any)throws->String {
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])
        return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    public func validateTask(_ task:ChoiceTask,now:Date=Date())throws {
        try validate()
        if authorityPolicy=="native-sealed-fixture-envelope-v2" {
            guard let sealedSession,task.id=="pin-current-question",task.version==sealedSession.evidenceQuestionContractVersion,
                  let state=try JSONSerialization.jsonObject(with:Data(task.state.utf8))as?[String:Any],
                  let question=state["latestQuestion"]as?String,sealedSession.permitsQuestion(question),
                  let instant=state["now"]as?String,let date=ISO8601DateFormatter().date(from:instant),abs(now.timeIntervalSince(date))<=180,
                  let rows=state["records"]as?[[String:Any]],rows.count<=3 else{throw PinDevelopmentError.sourceNotAllowed}
            return
        }
        guard task.id=="pin-current-question",task.version==EvidenceQuestionSession.contractVersionV4,
              let state=try JSONSerialization.jsonObject(with:Data(task.state.utf8))as?[String:Any],
              let question=state["latestQuestion"]as?String,!question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,question.utf8.count<=1024,
              let instant=state["now"]as?String,let date=ISO8601DateFormatter().date(from:instant),abs(now.timeIntervalSince(date))<=180,
              let records=state["records"]as?[[String:Any]],records.count<=3 else{throw PinDevelopmentError.sourceNotAllowed}
        func check(_ rows:[[String:Any]])throws {
            var seen:Set<String>=[]
            for row in rows {
                guard Set(row.keys)==["appointment"],let appointment=row["appointment"]as?[String:Any]else{throw PinDevelopmentError.sourceNotAllowed}
                let hash=try Self.digest(appointment)
                guard allowedAppointmentSHA256.contains(hash),seen.insert(hash).inserted else{throw PinDevelopmentError.sourceNotAllowed}
            }
        }
        try check(records)
        if let previous=state["previousDisplayedAnswer"] {
            guard let value=previous as?[String:Any],let rows=value["orderedRecords"]as?[[String:Any]],rows.count<=3 else{throw PinDevelopmentError.sourceNotAllowed}
            try check(rows)
        }
    }
}
