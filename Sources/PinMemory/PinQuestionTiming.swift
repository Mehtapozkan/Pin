import Foundation

/// Private timing metadata only. No query, evidence, account or credential data.
public enum PinQuestionTiming {
    public enum SavedStage: String {
        case submitted, paired, prepared, sourcesVerified, snapshotCaptured, taskPrepared
        case witnessWritten, connecting, responseReceived, receiptValidated, answerReady, displayed
        case cancelled, failed, expired
    }

    private static let lock=NSLock()
    public static func mark(_ id:UUID?,_ stage:String,flags:[String:Bool]=[:],submissionID:UUID?=nil) {
        #if DEBUG
        guard let id,PinSealedQualification.usesReviewedSession else{return}
        record(id,stage,flags:flags,submissionID:submissionID)
        #endif
    }

    public static func markSaved(_ id: UUID, _ stage: SavedStage, error: (any Error)? = nil) {
        #if DEBUG
        #if targetEnvironment(simulator)
        if Bundle.main.bundleIdentifier == "app.pin.savedplacescandidate",
           ProcessInfo.processInfo.arguments.contains("--audit-local-saved-requests") {
            record(id,"saved.\(stage.rawValue)",flags:[:],submissionID:nil)
            return
        }
        guard Bundle.main.bundleIdentifier == "app.pin.savedcandidate",
              ProcessInfo.processInfo.arguments.contains("--test-saved-warm-context-control") else { return }
        #else
        guard PinSavedContentPhoneProfile.enabled else { return }
        #endif
        record(id,"saved.\(stage.rawValue)",flags:error.map(savedFailureFlags) ?? [:],submissionID:nil)
        #endif
    }

    static func localModelStage(_ taskID: String, _ stage: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--audit-local-saved-requests") ||
                ProcessInfo.processInfo.environment["PIN_AUDIT_LOCAL_MODEL"] == "1" else { return }
        let root = taskID.components(separatedBy: "/")[0]
        guard let id = UUID(uuidString: String(root.suffix(36))) else { return }
        #if targetEnvironment(simulator)
        record(id, stage, flags: [:], submissionID: nil)
        #elseif os(macOS)
        print("LOCAL_STAGE", id, stage, ProcessInfo.processInfo.systemUptime)
        #endif
        #endif
    }

    #if DEBUG
    private static func savedFailureFlags(_ error: any Error) -> [String: Bool] {
        // Errors may carry paths, source text or request metadata. Record only
        // fixed categories so the trace can be copied without that payload.
        switch error {
        case is CancellationError: return ["cancellation": true]
        case is PinEvidenceError: return ["evidence": true]
        case is URLError: return ["network": true]
        case PinDevelopmentError.transport: return ["transportResponse": true]
        case PinDevelopmentError.invalidReceipt: return ["receipt": true]
        case PinDevelopmentError.configuration, PinDevelopmentError.disabled,
             PinDevelopmentError.sourceNotAllowed: return ["configuration": true]
        case is CocoaError: return ["fileOrSystem": true]
        default: return ["other": true]
        }
    }

    private static func record(_ id: UUID, _ stage: String, flags: [String: Bool], submissionID: UUID?) {
        lock.lock();defer{lock.unlock()}
        do {
            let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("pin-question-timing.jsonl")
            var value:[String:Any]=["id":id.uuidString,"stage":stage,"uptime":ProcessInfo.processInfo.systemUptime,"wall":Date().timeIntervalSince1970,"flags":flags]
            if let submissionID {value["submissionID"]=submissionID.uuidString}
            var bytes=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys);bytes.append(10)
            if !FileManager.default.fileExists(atPath:url.path){try Data().write(to:url,options:.completeFileProtectionUntilFirstUserAuthentication)}
            let file=try FileHandle(forWritingTo:url);defer{try? file.close()}
            guard try file.seekToEnd()<131072 else{return};try file.write(contentsOf:bytes)
        }catch{ /* Timing cannot alter admission or answer publication. */ }
    }
    #endif
}
