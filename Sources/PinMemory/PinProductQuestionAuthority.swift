import Foundation
import PinCore
import IBrainSemantics
import IBrainRetrieval

/// Public-fixture native reconstruction input for the paired Mac only. The
/// provider sends only its reconstructed finite ChoiceTask to intelligence.
public struct PinProductQuestionAuthority:Codable,Sendable {
    public let memories:[PhotoMemory]
    public let records:[AppointmentItem]
    public let sdkMemory:Data
    public let originalSHA256BySourceID:[String:String]
    public let sealedWorld:Bool
    public var nativeCorrectionWitness:PinNativeCorrectionWitness?=nil
    public var unitEvidence:PinProductUnitEvidence?=nil
    public func withUnitEvidence(_ evidence:PinProductUnitEvidence)->Self {
        var copy=self;copy.unitEvidence=evidence;return copy
    }
    public func canonicalDigest()throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return ChoiceTask.hash(try encoder.encode(self))
    }
    /// V6 unit reconciliation binds every native fact and raw unit proof. SDK
    /// generation/permit bytes are independently reconstructed by the host and
    /// can change on an otherwise read-only reopen; they are not photo facts.
    public func unitReconciliationDigest()throws->String {
        struct Bound:Encodable {
            let contract:String
            let memories:[PhotoMemory],records:[AppointmentItem]
            let originalSHA256BySourceID:[String:String]
            let sealedWorld:Bool
            let unitEvidence:PinProductUnitEvidence?
            let nativeCorrections:[[AppointmentOwnerCorrectionTransition]]?
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return ChoiceTask.hash(try encoder.encode(Bound(contract:"native-unit-source-reconciliation-v1",memories:memories,records:records,originalSHA256BySourceID:originalSHA256BySourceID,sealedWorld:sealedWorld,unitEvidence:unitEvidence,nativeCorrections:nativeCorrectionWitness?.payload.histories)))
    }
}
/// Process-local cache ownership; decoding a wire authority cannot create this.
public struct PinProductAuthoritySnapshot:Sendable {
    public let authority:PinProductQuestionAuthority
    let owner:UUID
    let stamp:String
    public func withUnitEvidence(_ evidence:PinProductUnitEvidence)->Self {
        .init(authority:authority.withUnitEvidence(evidence),owner:owner,stamp:stamp)
    }
    public func withNativeCorrections(_ histories:[AppointmentReplayedCorrectionHistory],configuration:PinFreshProductConfiguration,requestID:UUID)throws->Self {
        guard configuration.nativeCorrectionPolicy==PinNativeCorrectionWitness.policy,let allowed=configuration.allowedNativeCorrectionSHA256 else{throw PinFreshProductFailure.unapprovedCorrection}
        var updated=authority
        updated.nativeCorrectionWitness=try PinNativeCorrectionWitness.sign(histories:histories,authority:authority,session:configuration.session,requestID:requestID,token:configuration.token,allowedCorrections:allowed)
        return Self(authority:updated,owner:owner,stamp:stamp)
    }
}
public struct PinProductReconciliation:Codable,Sendable {
    public let questionRequestID:UUID
    public let originalAuthoritySHA256:String
    public let publishedAuthoritySHA256:String
}
/// Constructed by the native presenter after publishing an admitted answer.
/// It names one genuine prior receipt and the exact rows actually shown.
public struct PinProductPublishedParent:Codable,Sendable {
    public let requestSHA256:String
    public let displayedRecordIDs:[String]
    public let selectedOrdinal:Int?
    public let reconciliation:PinProductReconciliation?
    public var units:PinProductUnitPublication?=nil
    public init(requestSHA256:String,displayedRecordIDs:[String],selectedOrdinal:Int?=nil,reconciliation:PinProductReconciliation?=nil) {
        self.requestSHA256=requestSHA256;self.displayedRecordIDs=displayedRecordIDs;self.selectedOrdinal=selectedOrdinal
        self.reconciliation=reconciliation
    }
    public func selecting(_ ordinal:Int?)->Self {
        var copy=Self(requestSHA256:requestSHA256,displayedRecordIDs:displayedRecordIDs,selectedOrdinal:ordinal,reconciliation:reconciliation);copy.units=units;return copy
    }
    public init(unitContext:PinDisplayedUnitContext,reconciliation:PinProductReconciliation?=nil) {
        requestSHA256=unitContext.continuation?.publications.last?.contextualReceipt.requestSHA256 ?? unitContext.answer.receipt.requestSHA256;displayedRecordIDs=[];selectedOrdinal=nil;self.reconciliation=reconciliation
        units=PinProductUnitPublication(answerRequestID:unitContext.answerRequestID,displayIdentity:unitContext.id,displayedUnitIDs:unitContext.orderedUnitIDs,orderedMemberRecordIDs:unitContext.orderedMemberRecordIDs,bindingSHA256:unitContext.bindingSHA256,baseRequestSHA256:unitContext.continuation == nil ? nil:unitContext.answer.receipt.requestSHA256,continuations:unitContext.continuation?.publications)
    }
}
/// Wire reconstruction metadata only. No initializer can import source/context
/// authority; the host must rebuild the original complete answer from receipts.
public struct PinProductUnitPublication:Codable,Sendable {
    public let answerRequestID:UUID
    public let displayIdentity:UUID
    public let displayedUnitIDs:[String]
    public let orderedMemberRecordIDs:[[String]]
    public let bindingSHA256:String
    public var baseRequestSHA256:String?=nil
    public var continuations:[LinkedUnitContinuationPublication]?=nil
}
