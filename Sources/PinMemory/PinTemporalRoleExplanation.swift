import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Optional context derived only from a validated, retained completion. No task
/// is fabricated when the original missing-start reader was not invoked.
public enum PinTemporalRoleContext {
    /// Reconstruct a saved preparation from current native authority. A saved
    /// context is proof input only; it cannot supply or replace record facts.
    public static func validate(_ context:TemporalRoleExplanationContext,memory:PhotoMemory,record:AppointmentItem,accessGranted:Bool,group:PinVisualGroupContext?=nil)throws {
        guard accessGranted,!record.dismissed,record.source==AppointmentSource(memory),[.anchoredSpansV8,.anchoredSpansV9].contains(context.effectiveTemporalPolicy) else{throw PinEvidenceError.staleRecord}
        let request=try PinSealedSourcePipeline.request(memory,temporalPolicy:context.effectiveTemporalPolicy)
        let current=try PinCanonicalMapping.projection(record,scope:request.source.scope)
        try group?.validate(memory:memory,projection:current)
        let selected=try group?.evidence(memory:memory)
        let source=selected?.source ?? request.source,lines=selected?.lines ?? request.lines
        guard context.temporalTaskID=="pin-source-start-"+memory.id+"-"+String(memory.revision)+(group.map{"-group"+String($0.ordinal)} ?? "") else{throw PinEvidenceError.staleRecord}
        let task=try PrintedStartFieldInterpreter.task(id:context.temporalTaskID,source:source,lines:lines,temporalPolicy:context.effectiveTemporalPolicy)
        try context.temporalReceipt.validate(for:task)
        _=try PrintedStartFieldInterpreter.assess(context.temporalReceipt,id:context.temporalTaskID,source:source,lines:lines,temporalPolicy:context.effectiveTemporalPolicy)
        let expected=TemporalRoleExplanationContext(source:source,current:current,lines:lines,temporalTaskID:context.temporalTaskID,temporalReceipt:context.temporalReceipt,temporalPolicy:context.effectiveTemporalPolicy)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let normalized=TemporalRoleExplanationContext(source:context.source,current:context.current,lines:context.lines,temporalTaskID:context.temporalTaskID,temporalReceipt:context.temporalReceipt,temporalPolicy:context.effectiveTemporalPolicy)
        guard try encoder.encode(expected)==encoder.encode(normalized)else{throw PinEvidenceError.staleRecord}
    }
    public static func make(_ completed:PinSealedSourceCompletion,memory:PhotoMemory)throws->TemporalRoleExplanationContext? {
        guard [.anchoredSpansV8,.anchoredSpansV9].contains(completed.temporalPolicy) else{return nil}
        let request=try PinSealedSourcePipeline.request(memory,temporalPolicy:completed.temporalPolicy)
        let selected=try completed.groupContext?.evidence(memory:memory)
        try completed.groupContext?.validate(memory:memory,projection:completed.projection)
        let source=selected?.source ?? request.source,lines=selected?.lines ?? request.lines
        let id="pin-source-start-"+memory.id+"-"+String(memory.revision)+(completed.groupContext.map{"-group"+String($0.ordinal)} ?? "")
        let task=try PrintedStartFieldInterpreter.task(id:id,source:source,lines:lines,temporalPolicy:completed.temporalPolicy)
        let digest=try task.digest(),receipts=completed.receipts.filter{$0.requestSHA256==digest}
        guard !receipts.isEmpty else{return nil}
        guard receipts.count==1 else{throw PinEvidenceError.invalidSupport}
        try receipts[0].validate(for:task)
        return TemporalRoleExplanationContext(source:source,current:completed.projection,lines:lines,temporalTaskID:id,temporalReceipt:receipts[0],temporalPolicy:completed.temporalPolicy)
    }
    public static func taskID(_ context:TemporalRoleExplanationContext)->String {
        context.temporalTaskID.replacingOccurrences(of:"pin-source-start-",with:"pin-source-clock-explanation-")
    }
}

/// Derived checkpoint between source admission and explanation generation.
/// No explanation receipt, model answer or canonical fact is manufactured.
public enum PinTemporalPreparationArchive {
    public struct Preparation:Codable,Sendable {
        public let context:TemporalRoleExplanationContext
        public let group:PinVisualGroupContext?
    }
    private struct Packet:Codable {let schema:Int;let preparation:Preparation}
    private static func file(_ directory:URL,_ id:String)->URL {
        directory.appendingPathComponent(Data(id.utf8).base64EncodedString().replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"+",with:"-")+".json")
    }
    public static func save(directory:URL,context:TemporalRoleExplanationContext,group:PinVisualGroupContext?,memory:PhotoMemory,record:AppointmentItem,accessGranted:Bool)throws {
        try PinTemporalRoleContext.validate(context,memory:memory,record:record,accessGranted:accessGranted,group:group)
        guard let id=record.canonicalRecordID,id.utf8.count<=512 else{throw PinEvidenceError.staleRecord}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let bytes=try encoder.encode(Packet(schema:1,preparation:Preparation(context:context,group:group)))
        guard bytes.count<=524288 else{throw PinDevelopmentError.oversized}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let target=file(directory,id)
        if (try? Data(contentsOf:target))==bytes{return}
        try PinPrivatePayloadWithdrawal.write(bytes,to:target,options:.atomic)
    }
    public static func load(directory:URL,memory:PhotoMemory,record:AppointmentItem,accessGranted:Bool,temporalPolicy:ObservationTemporalPolicy)throws->Preparation? {
        guard accessGranted,let id=record.canonicalRecordID,id.utf8.count<=512 else{throw PinEvidenceError.staleRecord}
        let target=file(directory,id);guard FileManager.default.fileExists(atPath:target.path)else{return nil}
        guard try target.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max <= 524288 else{throw PinDevelopmentError.oversized}
        let packet=try JSONDecoder().decode(Packet.self,from:Data(contentsOf:target)),p=packet.preparation
        guard packet.schema==1,p.context.effectiveTemporalPolicy==temporalPolicy else{throw PinEvidenceError.staleRecord}
        try PinTemporalRoleContext.validate(p.context,memory:memory,record:record,accessGranted:accessGranted,group:p.group)
        return p
    }
    public static func prune(directory:URL,memories:[PhotoMemory],records:[AppointmentItem])throws {
        guard FileManager.default.fileExists(atPath:directory.path)else{return}
        var keep=Set<String>()
        for record in records where !record.dismissed {
            guard let id=record.canonicalRecordID,let memory=memories.first(where:{AppointmentSource($0)==record.source}),
                  let bytes=try? Data(contentsOf:file(directory,id)),bytes.count<=524288,
                  let packet=try? JSONDecoder().decode(Packet.self,from:bytes),packet.schema==1,
                  (try? PinTemporalRoleContext.validate(packet.preparation.context,memory:memory,record:record,accessGranted:true,group:packet.preparation.group)) != nil else{continue}
            keep.insert(file(directory,id).lastPathComponent)
        }
        for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where !keep.contains(url.lastPathComponent){try FileManager.default.removeItem(at:url)}
    }
}

/// Process-local display evidence. Reconstruct the full current projection from
/// the native record on every read; neither a same ID nor same revision suffices.
public struct PinTemporalRoleReading:Sendable {
    private let context:TemporalRoleExplanationContext
    private let result:TemporalRoleExplanation
    private let groupContext:PinVisualGroupContext?
    public init(context:TemporalRoleExplanationContext,receipt:DecisionReceipt,groupContext:PinVisualGroupContext?=nil)throws {
        self.context=context;self.groupContext=groupContext
        self.result=try TemporalRoleExplanationInterpreter.compile(receipt,id:PinTemporalRoleContext.taskID(context),context:context)
    }
    public func printedClockContext(memory:PhotoMemory,record:AppointmentItem,accessGranted:Bool)throws->(context:TemporalRoleExplanationContext,group:PinVisualGroupContext?) {
        _=try notices(memory:memory,record:record,accessGranted:accessGranted)
        return (context,groupContext)
    }
    public func notices(memory:PhotoMemory,record:AppointmentItem,accessGranted:Bool)throws->[String] {
        guard accessGranted,!record.dismissed,record.source==AppointmentSource(memory) else{throw PinEvidenceError.staleRecord}
        let source=try PinSealedSourcePipeline.request(memory,temporalPolicy:context.effectiveTemporalPolicy).source
        let current=try PinCanonicalMapping.projection(record,scope:source.scope)
        try groupContext?.validate(memory:memory,projection:current)
        let selected=try groupContext?.evidence(memory:memory)
        try result.validate(source:selected?.source ?? source,current:current)
        let unknown=current.appointment.date.hour==nil || current.appointment.date.minute==nil
        return result.rows.map { row in
            let clock=row.span.time.map{String(format:"%02d:%02d",$0.hour,$0.minute)} ?? row.span.quote
            let role:String
            switch row.role {
            case .doorsOpening:role="is doors opening, not the event start"
            case .eventEnd:role="is the event end, not its start"
            case .issueOrTransaction:role="is an issue or transaction time, not the event start"
            case .expiry:role="is an expiry or deadline, not the event start"
            case .supersededStart:role="is a superseded start time"
            case .other:role="has another established non-start role"
            case .unclear:role="has no established specific role"
            }
            return clock+" "+role+"."+(unknown ? " The event start remains unknown.":"")+" Reading of this photo: “"+row.support.quote+"”."
        }
    }
}

/// Versioned derived proof cache, never a source of appointment facts. Loading
/// recompiles the receipt and validates against the current native authority.
public enum PinTemporalRoleArchive {
    private struct Packet:Codable {let schema:Int;let interpreter:String;let context:TemporalRoleExplanationContext;let receipt:DecisionReceipt;let groupContext:PinVisualGroupContext?}
    private static func file(_ directory:URL,_ id:String)->URL {
        let name=Data(id.utf8).base64EncodedString().replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"+",with:"-")
        return directory.appendingPathComponent(name+".json")
    }
    public static func save(directory:URL,context:TemporalRoleExplanationContext,receipt:DecisionReceipt,memory:PhotoMemory,record:AppointmentItem,accessGranted:Bool,groupContext:PinVisualGroupContext?=nil)throws {
        let reading=try PinTemporalRoleReading(context:context,receipt:receipt,groupContext:groupContext)
        _=try reading.notices(memory:memory,record:record,accessGranted:accessGranted)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(Packet(schema:1,interpreter:TemporalRoleExplanationInterpreter.version,context:context,receipt:receipt,groupContext:groupContext))
        guard data.count<=262144,context.current.recordID.utf8.count<=512 else{throw PinEvidenceError.invalidSupport}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try PinPrivatePayloadWithdrawal.write(data,to:file(directory,context.current.recordID),options:.atomic)
    }
    public static func load(directory:URL,memory:PhotoMemory,record:AppointmentItem,accessGranted:Bool,temporalPolicy:ObservationTemporalPolicy?=nil)throws->PinTemporalRoleReading? {
        guard accessGranted,let id=record.canonicalRecordID,id.utf8.count<=512 else{throw PinEvidenceError.staleRecord}
        let url=file(directory,id);guard FileManager.default.fileExists(atPath:url.path)else{return nil}
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard size<=262144 else{throw PinEvidenceError.invalidSupport}
        let packet=try JSONDecoder().decode(Packet.self,from:Data(contentsOf:url))
        guard temporalPolicy==nil || packet.context.effectiveTemporalPolicy==temporalPolicy else{throw PinEvidenceError.staleRecord}
        guard packet.schema==1,packet.interpreter==TemporalRoleExplanationInterpreter.version,packet.context.current.recordID==id else{throw PinEvidenceError.invalidSupport}
        let reading=try PinTemporalRoleReading(context:packet.context,receipt:packet.receipt,groupContext:packet.groupContext)
        _=try reading.notices(memory:memory,record:record,accessGranted:accessGranted);return reading
    }
    public static func prune(directory:URL,memories:[PhotoMemory],records:[AppointmentItem])throws {
        guard FileManager.default.fileExists(atPath:directory.path)else{return}
        var keep=Set<String>()
        for row in records where !row.dismissed {
            guard let id=row.canonicalRecordID,let memory=memories.first(where:{AppointmentSource($0)==row.source}),
                  (try? load(directory:directory,memory:memory,record:row,accessGranted:true)) != nil else{continue}
            keep.insert(file(directory,id).lastPathComponent)
        }
        for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where !keep.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at:url)
        }
    }
}
