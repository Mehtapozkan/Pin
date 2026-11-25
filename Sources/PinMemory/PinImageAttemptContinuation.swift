import Foundation
import PinCore
import IBrainVision

/// Trusted local configuration for one frozen attempt, not a retry policy or a
/// source grant. The configuration owner must reconcile a closed host allocation
/// before asserting non-dispatch. Missing receipts alone never prove it.
public struct PinImageAttemptContinuation: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Equatable, Sendable { case provenUndispatched, retainedReceipt, completedHostReceipt }
    public let session: UUID
    public let continuationSession: UUID
    public let taskID: UUID
    public let source: EvidenceSource
    public let ledgerSHA256: String
    public let requestSHA256: String
    public let frameArtifactSHA256: String
    public let mode: Mode
    public let dispatchEvidenceData: Data?
    public let dispatchEvidenceSHA256: String?
    public let completedReceiptData: Data?
    public let completedReceiptSHA256: String?

    public init(session:UUID,continuationSession:UUID,taskID:UUID,source:EvidenceSource,ledgerSHA256:String,requestSHA256:String,frameArtifactSHA256:String,mode:Mode,dispatchEvidenceData:Data?=nil,dispatchEvidenceSHA256:String?=nil,completedReceiptData:Data?=nil,completedReceiptSHA256:String?=nil) {
        self.session=session;self.continuationSession=continuationSession;self.taskID=taskID;self.source=source
        self.ledgerSHA256=ledgerSHA256;self.requestSHA256=requestSHA256;self.frameArtifactSHA256=frameArtifactSHA256;self.mode=mode
        self.dispatchEvidenceData=dispatchEvidenceData;self.dispatchEvidenceSHA256=dispatchEvidenceSHA256
        self.completedReceiptData=completedReceiptData;self.completedReceiptSHA256=completedReceiptSHA256
    }

    /// Delivery of a completed response is independent of source admission.
    /// The caller must still reconstruct the exact request/frame and use the
    /// ordinary SDK/current-source admission path before changing native facts.
    func completedHostReceipt() throws -> VisualEvidenceReceipt? {
        guard mode == .completedHostReceipt else{return nil}
        guard let bytes=completedReceiptData,let digest=completedReceiptSHA256,
              bytes.count<=131072,VisualEvidenceRequest.hash(bytes)==digest else{throw PinDevelopmentError.configuration}
        let receipt=try JSONDecoder().decode(VisualEvidenceReceipt.self,from:bytes)
        guard receipt.requestSHA256==requestSHA256 else{throw PinEvidenceError.staleRecord}
        return receipt
    }

    public func validate(continuationSession expected: UUID) throws {
        guard continuationSession == expected, session != expected,
              [ledgerSHA256, requestSHA256, frameArtifactSHA256].allSatisfy({
                  $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
              }) else { throw PinDevelopmentError.configuration }
        switch mode {
        case .retainedReceipt:
            guard dispatchEvidenceData == nil, dispatchEvidenceSHA256 == nil,completedReceiptData==nil,completedReceiptSHA256==nil else { throw PinDevelopmentError.configuration }
        case .completedHostReceipt:
            guard dispatchEvidenceData==nil,dispatchEvidenceSHA256==nil else{throw PinDevelopmentError.configuration}
            _=try completedHostReceipt()
        case .provenUndispatched:
            guard completedReceiptData==nil,completedReceiptSHA256==nil else{throw PinDevelopmentError.configuration}
            struct Evidence: Decodable {
                let closed: Bool
                let session: UUID
                let dispatchState: String
                let failureLayer: String
                let imageModelCalls: Int
                let logicalRequestSHA256: String
            }
            guard let bytes = dispatchEvidenceData, let digest = dispatchEvidenceSHA256,
                  bytes.count <= 32768, VisualEvidenceRequest.hash(bytes) == digest else { throw PinDevelopmentError.configuration }
            let proof = try JSONDecoder().decode(Evidence.self, from: bytes)
            guard proof.closed, proof.session == session, proof.dispatchState == "not-started",
                  proof.failureLayer == "image-validation-before-reservation", proof.imageModelCalls == 0,
                  proof.logicalRequestSHA256 == requestSHA256 else { throw PinDevelopmentError.sourceNotAllowed }
        }
    }
}
