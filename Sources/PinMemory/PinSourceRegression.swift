import Foundation
import CryptoKit
import PinCore

/// Read-only address of an already completed initial source assessment. It
/// selects existing evidence, never a new dispatch journal or a retry permit.
public struct PinCompletedSourceArchive:Codable,Sendable {
    public let session:UUID
    public let source:EvidenceSource
    public let initialReceiptSHA256:String

    public func validate(currentSession:UUID)throws {
        guard session != currentSession,source.revision>0,!source.id.isEmpty,
              initialReceiptSHA256.count==64,
              initialReceiptSHA256.allSatisfy({"0123456789abcdef".contains($0)}) else {
            throw PinDevelopmentError.configuration
        }
    }
}

/// Explicit development regression after a locally rejected, never-dispatched
/// source request. This is evidence about an old attempt, not source truth.
public struct PinSourceRegression:Codable,Sendable {
    public let previousSession:UUID
    public let source:EvidenceSource
    public let markerSHA256:String
    public let nondispatchAuditSHA256:String
    public let undispatchedEnvelopeSHA256:String?
    public let closedAllocationSHA256:String?

    init(previousSession:UUID,source:EvidenceSource,markerSHA256:String,
         nondispatchAuditSHA256:String,undispatchedEnvelopeSHA256:String?=nil,closedAllocationSHA256:String?=nil) {
        self.previousSession=previousSession
        self.source=source
        self.markerSHA256=markerSHA256
        self.nondispatchAuditSHA256=nondispatchAuditSHA256
        self.undispatchedEnvelopeSHA256=undispatchedEnvelopeSHA256
        self.closedAllocationSHA256=closedAllocationSHA256
    }

    public func validate(session:UUID)throws {
        guard previousSession != session,
              !(undispatchedEnvelopeSHA256 != nil && closedAllocationSHA256 != nil),
              closedAllocationSHA256==nil || source.revision>0,
              ([markerSHA256,nondispatchAuditSHA256]+[undispatchedEnvelopeSHA256,closedAllocationSHA256].compactMap{$0}).allSatisfy({$0.count==64 && $0.allSatisfy(\.isHexDigit)})
        else{throw PinDevelopmentError.configuration}
    }
}

public enum PinSourceAttemptLocation {
    /// Only used when assembling evidence for a source already covered by the
    /// authoritative domain store. The ordinary receipt compiler still checks
    /// the selected receipt against the current source and canonical records.
    public static func completedInitialReceipt(documents:URL,source:EvidenceSource,
                                               session:UUID,archives:[PinCompletedSourceArchive])throws->Data? {
        let matches=archives.filter{$0.source.id==source.id}
        guard !matches.isEmpty else{return nil}
        guard matches.count==1,let archive=matches.first,archive.source==source else {
            throw PinDevelopmentError.sourceNotAllowed
        }
        try archive.validate(currentSession:session)
        let root=documents.appendingPathComponent("source-regression-"+archive.session.uuidString)
            .appendingPathComponent("fresh-source-attempts")
        let key=try Self.key(for:source)
        let marker=try read(root.appendingPathComponent(key+".json"),maximum:16_384,sha256:key)
        guard try JSONDecoder().decode(EvidenceSource.self,from:marker)==source else {
            throw PinDevelopmentError.sourceNotAllowed
        }
        return try read(root.appendingPathComponent(key+".unit-initial-receipt.json"),
                        maximum:131_072,sha256:archive.initialReceiptSHA256)
    }

    /// Persisted archive identity predates unescaped-slash wire encodings.
    /// Writers and later unit reads must use this same legacy byte encoding.
    public static func key(for source:EvidenceSource)throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return SHA256.hash(data:try encoder.encode(source)).map{String(format:"%02x",$0)}.joined()
    }
    /// An attempt marker is not a completed assessment. Missing results after
    /// cancellation or process exit stay terminal; never reopen dispatch.
    /// A present archive must still pass its existing authority/receipt loader.
    public static func requireSavedResult(at archive:URL)throws {
        guard FileManager.default.fileExists(atPath:archive.path)else{
            throw PinFreshProductFailure.unfinishedSourceRead
        }
    }
    /// Reserve a different initial request name in the same journal. Receipt
    /// and source archive names continue to use the original evidence key.
    public static func initialKey(root:URL,source:EvidenceSource,originalSHA256:String,
                                  session:UUID,regressions:[PinSourceRegression])throws->String {
        let key=try Self.key(for:source)
        guard let regression=regressions.first(where:{$0.source.id==source.id && $0.source.revision==source.revision}),
              let envelopeSHA=regression.undispatchedEnvelopeSHA256 else{return key}
        try regression.validate(session:session)
        guard source==regression.source,source.revision==1 else{throw PinDevelopmentError.sourceNotAllowed}
        let oldMarker=root.appendingPathComponent(key+".json")
        let oldEnvelope=root.appendingPathComponent(key+".initial-envelope.json")
        let marker=try read(oldMarker,maximum:16_384,sha256:regression.markerSHA256)
        let envelope=try read(oldEnvelope,maximum:1_048_576,sha256:envelopeSHA)
        guard try JSONDecoder().decode(EvidenceSource.self,from:marker)==source else{
            throw PinDevelopmentError.sourceNotAllowed
        }
        try PinInitialSourceRecovery.validateUndispatched(envelope,source:source,originalSHA256:originalSHA256,
                                                          session:regression.previousSession)
        let recoveryKey=key+".undispatched-recovery"
        let fm=FileManager.default
        if !fm.fileExists(atPath:root.appendingPathComponent(recoveryKey+".json").path) {
            let documents=root.deletingLastPathComponent()
            let checkpoints=[
                root.appendingPathComponent(key+".completion-started.json"),
                root.appendingPathComponent(key+".unit-initial-receipt.json"),
                root.appendingPathComponent(key+".ocr-grouping-envelope.json"),
                root.appendingPathComponent(key+".ocr-grouping-receipt.json"),
                documents.appendingPathComponent("fresh-source-assessments/"+key+".json"),
                documents.appendingPathComponent("fresh-source-groups/"+key+".json")
            ]
            guard !checkpoints.contains(where:{fm.fileExists(atPath:$0.path)})else{
                throw PinFreshProductFailure.unfinishedSourceRead
            }
        }
        return recoveryKey
    }

    private static func read(_ file:URL,maximum:Int,sha256:String)throws->Data {
        let metadata=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard metadata.isRegularFile==true,metadata.isSymbolicLink != true,
              let size=metadata.fileSize,size<=maximum else{throw PinDevelopmentError.sourceNotAllowed}
        let data=try Data(contentsOf:file)
        guard data.count==size,SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==sha256 else{
            throw PinDevelopmentError.sourceNotAllowed
        }
        return data
    }

    /// Legacy evidence is never removed or rewritten. An explicit attestation
    /// selects a separate journal only for the exact failed source and marker.
    /// A completed archive, different source, or changed marker cannot opt in.
    public static func root(documents:URL,source:EvidenceSource,session:UUID,regressions:[PinSourceRegression])throws->URL {
        let legacy=documents.appendingPathComponent("fresh-source-attempts")
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let key=try Self.key(for:source)
        let marker=legacy.appendingPathComponent(key+".json")
        guard let regression=regressions.first(where:{$0.source==source})else{return legacy}
        try regression.validate(session:session)
        if regression.undispatchedEnvelopeSHA256 != nil{return legacy}
        guard regressions.filter({$0.source==source}).count==1,
              FileManager.default.fileExists(atPath:marker.path),
              !FileManager.default.fileExists(atPath:documents.appendingPathComponent("fresh-source-assessments/"+key+".json").path),
              !FileManager.default.fileExists(atPath:documents.appendingPathComponent("fresh-source-groups/"+key+".json").path)
        else{throw PinDevelopmentError.sourceNotAllowed}
        let bytes=try Data(contentsOf:marker)
        guard bytes.count<=16384,
              SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==regression.markerSHA256,
              try JSONDecoder().decode(EvidenceSource.self,from:bytes)==source
        else{throw PinDevelopmentError.sourceNotAllowed}
        if regression.closedAllocationSHA256 != nil {
            // This exception is for a proven empty, closed allocation, not an
            // interrupted stage with a possible receipt. Never discard one.
            let suffixes=[".completion-started.json",".unit-initial-receipt.json",
                          ".ocr-grouping-envelope.json",".ocr-grouping-receipt.json",
                          ".ocr-children-started.json"]
            guard !suffixes.contains(where:{FileManager.default.fileExists(atPath:legacy.appendingPathComponent(key+$0).path)})else{
                throw PinFreshProductFailure.unfinishedSourceRead
            }
            // One recovery allocation per old source attempt, including after
            // process exit. A later session cannot turn this proof into retries.
            let claim=legacy.appendingPathComponent(key+".closed-allocation-recovery.json")
            let expected=try encoder.encode(ClosedAllocationClaim(session:session,regression:regression))
            if FileManager.default.fileExists(atPath:claim.path) {
                guard try Data(contentsOf:claim)==expected else{throw PinFreshProductFailure.unfinishedSourceRead}
            }else{try PinPrivatePayloadWithdrawal.write(expected,to:claim,options:.withoutOverwriting)}
        }
        let root=documents.appendingPathComponent("source-regression-"+session.uuidString).appendingPathComponent("fresh-source-attempts")
        // Freeze the attestation alongside the new journal. It is never a
        // substitute for host-side verification of the zero-dispatch audit.
        let proof=root.deletingLastPathComponent().appendingPathComponent(key+".authorization.json")
        let expected=try encoder.encode(regression)
        if FileManager.default.fileExists(atPath:proof.path) {
            guard try Data(contentsOf:proof)==expected else{throw PinDevelopmentError.sourceNotAllowed}
        }else{
            try FileManager.default.createDirectory(at:proof.deletingLastPathComponent(),withIntermediateDirectories:true)
            try expected.write(to:proof,options:.atomic)
        }
        return root
    }
    private struct ClosedAllocationClaim:Codable {let session:UUID;let regression:PinSourceRegression}
}
