import Foundation
import CryptoKit
import PinCore

/// Explicit trusted local authorization for one proven non-dispatched task.
/// Not an inference receipt, retry policy or replacement source authority.
public struct PinSourceUndispatchedRecoveryAuthorization:Decodable,Sendable {
    public let session:UUID,transactionID:UUID,questionRequestID:UUID
    public let sourceAfter:EvidenceSource
    public let initialEnvelopeSHA256:String,evidenceSHA256:String
    public let evidenceData:Data
    public func validate(session expected:UUID,transaction:UUID,source:EvidenceSource)throws {
        struct Evidence:Decodable{let dispatchState:String;let requestSHA256:String;let failureLayer:String}
        guard session==expected,transactionID==transaction,sourceAfter==source,
              initialEnvelopeSHA256.count==64,initialEnvelopeSHA256.allSatisfy(\.isHexDigit),evidenceData.count<=32768,
              SHA256.hash(data:evidenceData).map({String(format:"%02x",$0)}).joined()==evidenceSHA256 else{throw PinDevelopmentError.configuration}
        let evidence=try JSONDecoder().decode(Evidence.self,from:evidenceData)
        guard evidence.dispatchState=="not-started",evidence.failureLayer=="native-reconstruction-before-dispatch",evidence.requestSHA256==initialEnvelopeSHA256 else{throw PinDevelopmentError.sourceNotAllowed}
    }
}
