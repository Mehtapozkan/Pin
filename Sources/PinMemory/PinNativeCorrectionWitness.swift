import Foundation
import CryptoKit
import PinCore
import IBrain
import IBrainSemantics

/// Authenticated native-operation evidence for the existing paired public test.
/// It never grants source authority by decoding; the host must verify the MAC,
/// reconstruct the original source baseline, and replay every exact native edit.
public struct PinNativeCorrectionWitness:Codable,Sendable {
    public static let policy="pin-native-owner-correction-v1"
    public struct Payload:Codable,Sendable {
        public let policy:String
        public let session:UUID
        public let questionRequestID:UUID
        public let nativeAuthoritySHA256:String
        public let histories:[[AppointmentOwnerCorrectionTransition]]
    }
    public let payload:Payload
    public let authentication:String
    private static func bytes<T:Encodable>(_ value:T)throws->Data {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)
    }
    public static func correctionDigest(_ correction:AppointmentOwnerCorrection)throws->String{ChoiceTask.hash(try bytes(correction))}
    public static func factsDigest(_ authority:PinProductQuestionAuthority)throws->String {
        struct Facts:Encodable {let memories:[PhotoMemory];let records:[AppointmentItem];let sdkMemory:Data;let originalSHA256BySourceID:[String:String];let sealedWorld:Bool}
        return ChoiceTask.hash(try bytes(Facts(memories:authority.memories,records:authority.records,sdkMemory:authority.sdkMemory,originalSHA256BySourceID:authority.originalSHA256BySourceID,sealedWorld:authority.sealedWorld)))
    }
    private static func message(_ payload:Payload)throws->Data{Data((policy+"\n").utf8)+(try bytes(payload))}
    private static func key(_ token:String)throws->SymmetricKey {
        guard token.utf8.count>=24,token.utf8.count<=4096 else{throw PinDevelopmentError.configuration}
        return SymmetricKey(data:Data(token.utf8))
    }
    public static func sign(histories:[AppointmentReplayedCorrectionHistory],authority:PinProductQuestionAuthority,session:UUID,requestID:UUID,token:String,allowedCorrections:Set<String>)throws->Self {
        let corrected=authority.records.filter{!$0.observation.ownerCorrectionFields.isEmpty}
        guard !histories.isEmpty,histories.count<=12,Set(histories.map{$0.current.id}).count==histories.count,
              Set(histories.map{$0.current.id})==Set(corrected.map(\.id)),
              histories.allSatisfy({h in authority.records.contains(h.current) && h.sources==h.current.allSources && !h.transitions.isEmpty})else{throw PinEvidenceError.staleRecord}
        let payload=Payload(policy:policy,session:session,questionRequestID:requestID,nativeAuthoritySHA256:try factsDigest(authority),histories:histories.sorted{$0.current.id<$1.current.id}.map(\.transitions))
        try checkAllowed(payload,allowed:allowedCorrections)
        let auth=HMAC<SHA256>.authenticationCode(for:try message(payload),using:try key(token))
        return Self(payload:payload,authentication:auth.map{String(format:"%02x",$0)}.joined())
    }
    private static func checkAllowed(_ payload:Payload,allowed:Set<String>)throws {
        guard !allowed.isEmpty,!payload.histories.isEmpty,payload.histories.count<=12,
              payload.histories.allSatisfy({!$0.isEmpty && $0.count<=64}),try bytes(payload).count<=1_048_576 else{throw PinDevelopmentError.oversized}
        for step in payload.histories.flatMap({$0}) {
            guard allowed.contains(try correctionDigest(step.correction))else{throw PinFreshProductFailure.unapprovedCorrection}
        }
    }
    public func verify(authority:PinProductQuestionAuthority,session:UUID,requestID:UUID?=nil,token:String,allowedCorrections:Set<String>)throws {
        guard payload.policy==Self.policy,payload.session==session,requestID.map({$0==payload.questionRequestID}) ?? true,
              payload.nativeAuthoritySHA256 == (try Self.factsDigest(authority)),authentication.count==64,
              authentication.allSatisfy({"0123456789abcdef".contains($0)})else{throw PinEvidenceError.staleRecord}
        try Self.checkAllowed(payload,allowed:allowedCorrections)
        let supplied=Data(stride(from:0,to:authentication.count,by:2).map{offset->UInt8 in
            let start=authentication.index(authentication.startIndex,offsetBy:offset),end=authentication.index(start,offsetBy:2)
            return UInt8(authentication[start..<end],radix:16)!
        })
        guard HMAC<SHA256>.isValidAuthenticationCode(supplied,authenticating:try Self.message(payload),using:try Self.key(token)) else{throw PinEvidenceError.staleRecord}
    }
}

/// Genuine deterministic native execution: an edit retires a relation, so the
/// current relation remains unestablished. Never a model receipt or same/different
/// verdict. Its caller/host must first verify the confirmed edit/current task.
public enum PinCorrectionUncertaintyPolicy {
    public static let provider="pin-native-correction-policy"
    public static func receipt(for task:ChoiceTask)throws->DecisionReceipt {
        guard [SourceOccurrenceInterpreter.jointIdentityVersion,InventoryOccurrenceInterpreter.version].contains(task.version),
              task.questions.keys.allSatisfy({$0.hasPrefix("pair_")}),
              task.questions.values.allSatisfy({$0.criteria["unclear"] != nil})else{throw PinEvidenceError.invalidSupport}
        let answers=Dictionary(uniqueKeysWithValues:task.questions.keys.map{($0,ChoiceAnswer(choice:"unclear"))})
        let result=DecisionReceipt(provider:provider,model:PinNativeCorrectionWitness.policy,requestSHA256:try task.digest(),answers:answers,elapsedSeconds:0)
        try result.validate(for:task);return result
    }
}
