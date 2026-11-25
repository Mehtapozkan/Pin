import Foundation
import PinCore

/// An exact transport attempt, not a record or a transferable read permit.
/// Recovery retains the original question nonce. Current access/source checks
/// remain the caller's responsibility before sending and after receipt arrival.
public enum PinInitialSourceRecovery {
    private static func permits(_ envelope:[String:Any],taskVersion:String?)->Bool {
        let policy=envelope["sourceTaskPolicy"]as?String,recovery=envelope["sourceReceiptRecovery"]as?String
        guard ["initial-v1","initial-and-retained-grouping-v2"].contains(recovery ?? "") else{return false}
        if policy==nil{return recovery=="initial-v1" && taskVersion?.hasPrefix("appointment-visual-observations-v8/")==true}
        guard (try? PinInitialSourcePolicy.configured(policy))?.usesCompactKeys==true else{return false}
        if taskVersion==PinInitialSourcePolicy.compactKeysV1.rawValue{return envelope["retainedGroupingInitialReceipt"]==nil}
        return recovery=="initial-and-retained-grouping-v2" && envelope["retainedOCRGrouping"]as?Bool==true && taskVersion=="retained-ocr-source-groups-v1" && envelope["retainedGroupingInitialReceipt"]is [String:Any]
    }
    public static func requireUnstartedCompletion(attempt:URL,completion:URL)throws {
        guard FileManager.default.fileExists(atPath:attempt.path),
              !FileManager.default.fileExists(atPath:completion.path)else{throw PinFreshProductFailure.unfinishedSourceRead}
    }
    public static func beginCompletion(file:URL,source:Data)throws {
        try PinPrivatePayloadWithdrawal.write(source,to:file,options:.withoutOverwriting)
    }
    static func validateUndispatched(_ data:Data,source:EvidenceSource,originalSHA256:String,session:UUID)throws {
        let envelope=try initialEnvelope(data)
        guard let savedSession=envelope["session"] as? String,UUID(uuidString:savedSession)==session,
              let memory=envelope["memory"] as? [String:Any],
              memory["id"] as? String==source.id,memory["fingerprint"] as? String==source.fingerprint,
              memory["revision"] as? Int==source.revision,envelope["originalSHA256"] as? String==originalSHA256,
              (try? PinInitialSourcePolicy.configured(envelope["sourceTaskPolicy"] as? String))?.usesCompactKeys==true,
              (envelope["task"] as? [String:Any])?["version"] as? String==PinInitialSourcePolicy.compactKeysV1.rawValue,
              envelope["sourceRegressions"]==nil else{throw PinDevelopmentError.sourceNotAllowed}
    }

    private static func initialEnvelope(_ current:Data)throws->[String:Any] {
        guard current.count<=1_048_576 else{throw PinDevelopmentError.oversized}
        guard let expected=try JSONSerialization.jsonObject(with:current)as?[String:Any],
              ["initial-v1","initial-and-retained-grouping-v2"].contains(expected["sourceReceiptRecovery"]as?String ?? ""),
              let nonce=expected["questionRequestID"]as?String,UUID(uuidString:nonce) != nil,
              let memory=expected["memory"]as?[String:Any],memory["revision"]as?Int==1,memory["visualReading"]==nil,
              let task=expected["task"]as?[String:Any],
              Self.permits(expected,taskVersion:task["version"]as?String),
              ["recordID","recordRevision","groupContext","clockRepair","authority","parentPublication"].allSatisfy({expected[$0]==nil}) else{throw PinDevelopmentError.sourceNotAllowed}
        return expected
    }

    public static func body(_ current:Data,file:URL,recover:Bool)throws->Data {
        var expected=try initialEnvelope(current)
        if !recover {
            guard !FileManager.default.fileExists(atPath:file.path) else{throw PinFreshProductFailure.unfinishedSourceRead}
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try PinPrivatePayloadWithdrawal.write(current,to:file,options:.withoutOverwriting)
            return current
        }
        guard FileManager.default.fileExists(atPath:file.path)else{throw PinFreshProductFailure.unfinishedSourceRead}
        let original=try Data(contentsOf:file)
        guard original.count<=1_048_576,
              var saved=try JSONSerialization.jsonObject(with:original)as?[String:Any],
              let oldNonce=saved["questionRequestID"]as?String,UUID(uuidString:oldNonce) != nil else{throw PinDevelopmentError.invalidReceipt}
        // Only the active question nonce differs. Source, bytes hash, session,
        // task, policies and all other context must match in full.
        saved.removeValue(forKey:"questionRequestID");expected.removeValue(forKey:"questionRequestID")
        guard NSDictionary(dictionary:saved).isEqual(to:expected)else{throw PinDevelopmentError.sourceNotAllowed}
        return original
    }
}
