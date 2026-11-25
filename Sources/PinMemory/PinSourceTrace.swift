import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Private diagnostic receipt, not a source record, action grant or model input.
public struct PinSourceTraceEvent:Codable,Sendable {
    public let stage:String
    public let outcome:String
    public let source:PinCore.EvidenceSource
    public let recordID:String?
    public let recordRevision:Int?
    public let date:AppointmentDateComponents?
    public let taskSHA256:String?
    public let error:String?
    public init(stage:String,outcome:String="pass",memory:PhotoMemory,recordID:String?=nil,recordRevision:Int?=nil,
                date:EventDate?=nil,task:ChoiceTask?=nil,error:Error?=nil) {
        self.stage=stage;self.outcome=outcome;source=PinCore.EvidenceSource(memory);self.recordID=recordID;self.recordRevision=recordRevision
        self.date=date.flatMap{try? JSONDecoder().decode(AppointmentDateComponents.self,from:JSONEncoder().encode($0))}
        taskSHA256=task.flatMap{try? $0.digest()};self.error=error.map{String(reflecting:$0)}
    }
}
public typealias PinSourceTraceSink = @Sendable(PinSourceTraceEvent)->Void
/// Each append is synchronous so tracing adds no new source-authority await.
/// The explicit fictional qualification profile alone enables this in the app.
public final class PinSourceTraceRecorder:@unchecked Sendable {
    private let lock=NSLock()
    private let url:URL
    public init(url:URL){self.url=url}
    public func append(_ event:PinSourceTraceEvent){
        lock.lock();defer{lock.unlock()}
        do {
            let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            var data=try e.encode(event);data.append(10)
            try PinPrivatePayloadWithdrawal.withWriteAccess {
                try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                if !FileManager.default.fileExists(atPath:url.path){try Data().write(to:url)}
                let file=try FileHandle(forWritingTo:url);defer{try? file.close()};try file.seekToEnd();try file.write(contentsOf:data)
            }
        }catch{ /* Diagnostic I/O cannot change source/admission authority. */ }
    }
    public var sink:PinSourceTraceSink{ { [self] in append($0) } }
}
