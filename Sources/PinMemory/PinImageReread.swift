import Foundation
import PinCore
import IBrain
import IBrainSemantics
import IBrainVision

/// Process-local authority from a current answer, never from a saved target list.
public struct PinPreparedImageReread:Sendable {
    public let source:PinCore.EvidenceSource
    let answer:PinExhaustiveQuestionAnswer
    let read:SourceReadSnapshot
    let owner:UUID
    let unitPlan:PinUnitRereadPlan?
}
/// Source-only authority for an untouched photo, before any question or
/// canonical interpretation. Minted by the current native projection owner.
public struct PinPreparedInitialImageRead:Sendable {
    public let source:PinCore.EvidenceSource
    let read:SourceReadSnapshot
    let owner:UUID
    let stamp:String
    let epoch:Int
    let requestID:UUID
}
enum PinImageReadAuthority:Sendable {
    case question(PinPreparedImageReread)
    case initial(PinPreparedInitialImageRead)
    var source:PinCore.EvidenceSource {switch self {case .question(let a):a.source;case .initial(let a):a.source}}
    var read:SourceReadSnapshot {switch self {case .question(let a):a.read;case .initial(let a):a.read}}
    var liveness:SourceInferenceLiveness {switch self {case .question:.snapshot;case .initial:.independentSource}}
}
/// Process-local routing authority derived from the entire admitted answer and
/// actual source/relation proofs. A caller cannot decode or supply a target set.
/// This grants no model dispatch, cloud permission or canonical write.
public struct PinUnitRereadPlan:Sendable {
    public let targets:[PinMissingQuestionEvidence]
    let answer:PinUnitQuestionAnswer
    let snapshot:PinProductAuthoritySnapshot
    let owner:UUID
    let submissionEpoch:Int
}
public enum PinImageRereadAdmission:Sendable {case completeTextOnly, preserveVisualEvidence}
public struct PinImageRereadResult:Sendable {
    public let visualReading:PhotoVisualReading?
    public let source:PinCore.EvidenceSource
    public let lines:[CardLine]
    public let receipt:VisualEvidenceReceipt
    public let acquisitionID:UUID
    public let originalSHA256:String
    public let frameSHA256:String
    let prepared:PreparedVisualEvidence
    let authority:PinImageReadAuthority
}

/// Durable dispatch evidence only, never source/canonical truth. An unfinished
/// attempt blocks this ledger after restart unless one exact, locally reconciled
/// continuation is explicitly configured. Unknown dispatches never retry.
public actor PinImageRereadLedger {
    private struct Entry:Codable {let source:PinCore.EvidenceSource;let taskID:String;var status:String;let requestSHA256:String}
    private struct State:Codable {let session:UUID;let limit:Int;var attempts:[Entry];let allowedSourceIDs:Set<String>?}
    struct SavedAttempt: Sendable {
        let taskID: UUID
        let requestData: Data
        let frameData: Data
        let receipt: VisualEvidenceReceipt?
    }
    private struct ContinuationMarker: Codable {
        let authorization: PinImageAttemptContinuation
        let originalLedgerData: Data
    }
    private let continuation: PinImageAttemptContinuation?
    private let originalLedgerData: Data?
    private let directory:URL
    private var state:State
    public init(directory:URL,session:UUID,maximumReads:Int,allowedSourceIDs:Set<String>?=nil,continuation:PinImageAttemptContinuation?=nil,continuationSession:UUID?=nil)throws {
        guard (1...12).contains(maximumReads),allowedSourceIDs.map({!$0.isEmpty && $0.count==maximumReads && $0.allSatisfy{!$0.isEmpty}}) ?? true else{throw PinDevelopmentError.configuration}
        self.directory=directory
        self.continuation=continuation
        let file=directory.appendingPathComponent("attempts.json")
        if FileManager.default.fileExists(atPath:file.path){
            let data=try Data(contentsOf:file);guard data.count<=131072 else{throw PinDevelopmentError.oversized}
            state=try JSONDecoder().decode(State.self,from:data)
            guard state.session==session,state.limit==maximumReads,state.allowedSourceIDs==allowedSourceIDs else{throw PinDevelopmentError.configuration}
        }else{state=State(session:session,limit:maximumReads,attempts:[],allowedSourceIDs:allowedSourceIDs)}
        if let continuation {
            guard let continuationSession else { throw PinDevelopmentError.configuration }
            try continuation.validate(continuationSession:continuationSession)
            guard continuation.session==session,
                  let entry=state.attempts.first(where:{$0.taskID==continuation.taskID.uuidString}),
                  entry.source==continuation.source,entry.requestSHA256==continuation.requestSHA256 else{throw PinDevelopmentError.configuration}
            let current=try Data(contentsOf:file)
            let markerFile=directory.appendingPathComponent(continuation.taskID.uuidString+".continuation-started.json")
            if FileManager.default.fileExists(atPath:markerFile.path) {
                let markerBytes=try Data(contentsOf:markerFile);guard markerBytes.count<=262144 else{throw PinDevelopmentError.oversized}
                let marker=try JSONDecoder().decode(ContinuationMarker.self,from:markerBytes)
                guard marker.authorization==continuation else{throw PinDevelopmentError.configuration}
                originalLedgerData=marker.originalLedgerData
            }else{originalLedgerData=current}
            guard let originalLedgerData,originalLedgerData.count<=131072,
                  VisualEvidenceRequest.hash(originalLedgerData)==continuation.ledgerSHA256 else{throw PinDevelopmentError.configuration}
            let original=try JSONDecoder().decode(State.self,from:originalLedgerData)
            guard original.session==state.session,original.limit==state.limit,original.allowedSourceIDs==state.allowedSourceIDs,
                  original.attempts.count==state.attempts.count else{throw PinDevelopmentError.configuration}
            for (before,after) in zip(original.attempts,state.attempts) {
                guard before.source==after.source,before.taskID==after.taskID,before.requestSHA256==after.requestSHA256,
                      before.status==after.status || (after.taskID==continuation.taskID.uuidString && ["received","committed","unchanged"].contains(after.status)) else{throw PinDevelopmentError.configuration}
            }
            guard let originalEntry=original.attempts.first(where:{$0.taskID==continuation.taskID.uuidString}),
                  originalEntry.status==(continuation.mode == .retainedReceipt ? "received":"dispatched") else{throw PinDevelopmentError.configuration}
        }else{
            guard continuationSession==nil else{throw PinDevelopmentError.configuration}
            originalLedgerData=nil
        }
    }
    private func save(_ next:State)throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        try encoder.encode(next).write(to:directory.appendingPathComponent("attempts.json"),options:.atomic)
        state=next
    }
    /// A reconciled exhausted/previously-read budget withholds further work,
    /// not a valid partial answer. Unfinished work remains a terminal error.
    public func canRead(_ source:PinCore.EvidenceSource)throws->Bool {
        guard state.allowedSourceIDs?.contains(source.id) ?? true else{return false}
        let unfinished=state.attempts.filter{!["committed","unchanged"].contains($0.status)}
        if !unfinished.isEmpty {
            guard unfinished.count==1,let continuation,let entry=unfinished.first,
                  entry.source==source,entry.taskID==continuation.taskID.uuidString else{throw PinDevelopmentError.sourceNotAllowed}
            _=try savedAttempt(source:source)
            return true
        }
        return state.attempts.count<state.limit && !state.attempts.contains(where:{$0.source.id==source.id})
    }
    /// Read exact native artifacts only. Opaque current source authority is
    /// re-minted by the cache; decoded provenance never becomes a read permit.
    func savedAttempt(source:PinCore.EvidenceSource)throws->SavedAttempt? {
        guard let continuation,continuation.source==source else{return nil}
        guard let entry=state.attempts.first(where:{$0.taskID==continuation.taskID.uuidString}),entry.source==source else{throw PinEvidenceError.staleRecord}
        guard ["dispatched","received"].contains(entry.status) else{return nil}
        let attempt=directory.appendingPathComponent(entry.taskID)
        let request=try Data(contentsOf:attempt.appendingPathComponent("request.json")),frame=try Data(contentsOf:attempt.appendingPathComponent("frame.json"))
        guard request.count<=32768,frame.count<=14_000_000,
              VisualEvidenceRequest.hash(request)==continuation.requestSHA256,
              VisualEvidenceRequest.hash(frame)==continuation.frameArtifactSHA256 else{throw PinDevelopmentError.configuration}
        let receiptFile=attempt.appendingPathComponent("receipt.json")
        let receipt:VisualEvidenceReceipt?
        if FileManager.default.fileExists(atPath:receiptFile.path) {
            let bytes=try Data(contentsOf:receiptFile);guard bytes.count<=131072 else{throw PinDevelopmentError.oversized}
            receipt=try JSONDecoder().decode(VisualEvidenceReceipt.self,from:bytes)
            guard receipt?.requestSHA256==continuation.requestSHA256 else{throw PinEvidenceError.staleRecord}
        }else{receipt=try continuation.completedHostReceipt()}
        if let delivered=try continuation.completedHostReceipt(),let receipt {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            guard try encoder.encode(delivered)==encoder.encode(receipt) else{throw PinEvidenceError.staleRecord}
        }
        if receipt==nil {
            guard continuation.mode == .provenUndispatched,entry.status=="dispatched",
                  !FileManager.default.fileExists(atPath:directory.appendingPathComponent(entry.taskID+".continuation-started.json").path) else{throw PinDevelopmentError.sourceNotAllowed}
        }
        return SavedAttempt(taskID:continuation.taskID,requestData:request,frameData:frame,receipt:receipt)
    }
    func claimContinuation(_ request:VisualEvidenceRequest,source:PinCore.EvidenceSource)throws->VisualEvidenceReceipt? {
        try PinPrivatePayloadWithdrawal.withWriteAccess {
            try Task.checkCancellation()
            guard let continuation,let originalLedgerData,let saved=try savedAttempt(source:source),
                  request.taskID==saved.taskID.uuidString,try request.requestData()==saved.requestData,
                  try request.preparedFrameArtifact()==saved.frameData else{throw PinEvidenceError.staleRecord}
            try saved.receipt?.validate(for:request)
            // Atomically fence an ambiguous process death before the reader.
            // A retained receipt can be revalidated without another dispatch.
            let marker=directory.appendingPathComponent(request.taskID+".continuation-started.json")
            if !FileManager.default.fileExists(atPath:marker.path) {
                let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                try encoder.encode(ContinuationMarker(authorization:continuation,originalLedgerData:originalLedgerData)).write(to:marker,options:.withoutOverwriting)
            }
            return saved.receipt
        }
    }
    func reserve(_ request:VisualEvidenceRequest,source:PinCore.EvidenceSource)throws {
        try PinPrivatePayloadWithdrawal.withWriteAccess {
        try Task.checkCancellation()
        guard state.attempts.allSatisfy({["committed","unchanged"].contains($0.status)}),
              state.attempts.count<state.limit,
              !state.attempts.contains(where:{$0.source.id==source.id}),
              try canRead(source),!state.attempts.contains(where:{$0.taskID==request.taskID})else{throw PinDevelopmentError.sourceNotAllowed}
        let requestData=try request.requestData(),frame=try request.preparedFrameArtifact()
        let attemptDirectory=directory.appendingPathComponent(request.taskID)
        guard !FileManager.default.fileExists(atPath:attemptDirectory.path)else{throw PinDevelopmentError.sourceNotAllowed}
        try FileManager.default.createDirectory(at:attemptDirectory,withIntermediateDirectories:true)
        try requestData.write(to:attemptDirectory.appendingPathComponent("request.json"),options:.atomic)
        try frame.write(to:attemptDirectory.appendingPathComponent("frame.json"),options:.atomic)
        var next=state;next.attempts.append(Entry(source:source,taskID:request.taskID,status:"dispatched",requestSHA256:VisualEvidenceRequest.hash(requestData)));try save(next)
        }
    }
    func received(_ receipt:VisualEvidenceReceipt,taskID:String)throws {
        try PinPrivatePayloadWithdrawal.withWriteAccess {
        guard let index=state.attempts.firstIndex(where:{$0.taskID==taskID}),["dispatched","received"].contains(state.attempts[index].status),state.attempts[index].requestSHA256==receipt.requestSHA256 else{throw PinEvidenceError.staleRecord}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let receiptFile=directory.appendingPathComponent(taskID).appendingPathComponent("receipt.json"),data=try encoder.encode(receipt)
        if state.attempts[index].status=="received" {
            guard try Data(contentsOf:receiptFile)==data else{throw PinEvidenceError.staleRecord}
            return
        }
        try data.write(to:receiptFile,options:.atomic)
        var next=state;next.attempts[index].status="received";try save(next)
        }
    }
    /// Repair only the crash gap AFTER native source CAS. The native owner
    /// supplies the current whole memory; this cannot dispatch or replay a read.
    public func reconcileCommittedInitialVisualRead(_ memory:PhotoMemory)throws {
        guard let visual=memory.visualReading,visual.sourceBeforeRead.revision==1 else{return}
        try visual.validate(for:memory)
        struct TaskIdentity:Decodable {let taskID:String}
        let taskID=try JSONDecoder().decode(TaskIdentity.self,from:visual.requestData).taskID
        guard let index=state.attempts.firstIndex(where:{$0.taskID==taskID})else{return}
        let entry=state.attempts[index]
        guard entry.source==visual.sourceBeforeRead,entry.requestSHA256==PhotoVisualReading.hash(visual.requestData),
              ["received","committed"].contains(entry.status)else{throw PinEvidenceError.staleRecord}
        let root=directory.appendingPathComponent(taskID)
        let request=try Data(contentsOf:root.appendingPathComponent("request.json"))
        let receipt=try Data(contentsOf:root.appendingPathComponent("receipt.json"))
        guard request==visual.requestData,receipt.count<=262144,
              try JSONDecoder().decode(PhotoVisualReading.Receipt.self,from:receipt)==visual.validatedReceipt()else{throw PinEvidenceError.staleRecord}
        if entry.status=="received" {var next=state;next.attempts[index].status="committed";try save(next)}
    }
    public func reconciled(acquisitionID:UUID,sourceChanged:Bool)throws {
        let taskID=acquisitionID.uuidString
        guard let index=state.attempts.firstIndex(where:{$0.taskID==taskID}),state.attempts[index].status=="received" else{throw PinEvidenceError.staleRecord}
        var next=state;next.attempts[index].status=sourceChanged ? "committed":"unchanged";try save(next)
    }
}
