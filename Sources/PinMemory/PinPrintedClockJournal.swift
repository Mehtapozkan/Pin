import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Derived dispatch journal. Incomplete attempts refuse redispatch; this is
/// never canonical authority or permission to rebind a retained receipt.
public enum PinPrintedClockJournal {
    public struct Attempt:Codable {
        public let schema:Int
        public let requestSHA256:String
        public let input:PinPrintedClockRepairInput
        public init(requestSHA256:String,input:PinPrintedClockRepairInput){schema=1;self.requestSHA256=requestSHA256;self.input=input}
    }
    public struct Terminal:Codable {
        public let schema:Int
        public let requestSHA256:String
        public let receipt:DecisionReceipt
        public let disposition:String
        public let committedRevision:Int?
        public init(requestSHA256:String,receipt:DecisionReceipt,disposition:String,committedRevision:Int?){schema=1;self.requestSHA256=requestSHA256;self.receipt=receipt;self.disposition=disposition;self.committedRevision=committedRevision}
    }
    public static func validate(directory root:URL)throws {
        let attempts=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasSuffix(".attempt.json")}
        guard attempts.count<=128 else{throw PinEvidenceError.invalidSupport}
        // A lost worker must not silently turn into another dispatch. The
        // successful native writer or held decision is recorded explicitly.
        for file in attempts {
            let bytes=try Data(contentsOf:file)
            guard bytes.count<=1048576 else{throw PinEvidenceError.invalidSupport}
            let attempt=try JSONDecoder().decode(Attempt.self,from:bytes)
            guard attempt.schema==1,let task=try attempt.input.task(),
                  try task.digest()==attempt.requestSHA256,
                  file.lastPathComponent==attempt.requestSHA256+".attempt.json" else{throw PinEvidenceError.invalidSupport}
            let terminalFile=root.appendingPathComponent(attempt.requestSHA256+".terminal.json")
            guard FileManager.default.fileExists(atPath:terminalFile.path) else{throw PinStoreError.staleResult}
            let terminalBytes=try Data(contentsOf:terminalFile)
            guard terminalBytes.count<=262144 else{throw PinEvidenceError.invalidSupport}
            let terminal=try JSONDecoder().decode(Terminal.self,from:terminalBytes)
            guard terminal.schema==1,terminal.requestSHA256==attempt.requestSHA256 else{throw PinEvidenceError.invalidSupport}
            try terminal.receipt.validate(for:task)
            let proposed=try PrintedClockNotationInterpreter.compile(terminal.receipt,id:task.id,context:attempt.input.context)
            if terminal.disposition=="held" {
                guard proposed==attempt.input.context.current,terminal.committedRevision==nil else{throw PinEvidenceError.invalidSupport}
            }else{
                guard terminal.disposition=="committed",proposed != attempt.input.context.current,
                  terminal.committedRevision==attempt.input.context.current.recordRevision+1 else{throw PinEvidenceError.invalidSupport}
            }
        }
    }
}
