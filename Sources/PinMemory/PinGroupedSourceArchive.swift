import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Completed group-attempt evidence. Never a canonical store or read permit.
public struct PinGroupedSourceResult:Codable,Sendable {
    public struct Outcome:Codable,Sendable {
        public let group:PinVisualGroupContext
        public let initialReceipt:DecisionReceipt
        public let recordID:String?
        public init(group:PinVisualGroupContext,initialReceipt:DecisionReceipt,recordID:String?){self.group=group;self.initialReceipt=initialReceipt;self.recordID=recordID}
    }
    public let outcomes:[Outcome]
    public init(outcomes:[Outcome]){self.outcomes=outcomes}
    public func validate(memory:PhotoMemory,records:[AppointmentItem])throws {
        guard let first=outcomes.first else{throw PinEvidenceError.invalidSupport}
        let grouping=try first.group.grouping(memory:memory)
        guard outcomes.count==grouping.scopes.count,Set(outcomes.map{$0.group.ordinal})==Set(grouping.scopes.map(\.ordinal)),
              Set(outcomes.compactMap(\.recordID)).count==outcomes.compactMap(\.recordID).count else{throw PinEvidenceError.invalidSupport}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        for outcome in outcomes {
            guard try encoder.encode(outcome.group.receipt)==encoder.encode(first.group.receipt) else{throw PinEvidenceError.invalidSupport}
            let request=try outcome.group.request(memory:memory,temporalPolicy:.anchoredSpansV9),task=try VisualObservationInterpreter.task(request,detailPolicy:.componentsV4)
            let result=try VisualSourcePreparationInterpreter.assess(request,task:task,receipt:outcome.initialReceipt)
            if let id=outcome.recordID {
                guard result.candidate?.disposition == .booking,let row=records.first(where:{$0.canonicalRecordID==id}),!row.dismissed else{throw PinEvidenceError.staleRecord}
                try outcome.group.validate(memory:memory,projection:PinCanonicalMapping.projection(row,scope:request.source.scope))
            }else{guard result.candidate?.disposition != .booking else{throw PinEvidenceError.invalidSupport}}
        }
    }
    public func hasUnpreparedGroups(memory:PhotoMemory,records:[AppointmentItem])throws->Bool {
        try validate(memory:memory,records:records)
        for outcome in outcomes where outcome.recordID==nil {
            let request=try outcome.group.request(memory:memory,temporalPolicy:.anchoredSpansV9)
            let assessment=try VisualSourcePreparationInterpreter.assess(request,task:VisualObservationInterpreter.task(request,detailPolicy:.componentsV4),receipt:outcome.initialReceipt)
            if assessment.candidate==nil{return true}
        }
        return false
    }
    public func save(file:URL,memory:PhotoMemory,records:[AppointmentItem])throws {
        try validate(memory:memory,records:records);let e=JSONEncoder();e.outputFormatting=[.sortedKeys]
        let data=try e.encode(self);guard data.count<=1_048_576 else{throw PinDevelopmentError.oversized}
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try PinPrivatePayloadWithdrawal.write(data,to:file,options:.atomic)
    }
    public static func load(file:URL,memory:PhotoMemory,records:[AppointmentItem])throws->Self {
        guard try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max <= 1_048_576 else{throw PinDevelopmentError.oversized}
        let result=try JSONDecoder().decode(Self.self,from:Data(contentsOf:file));try result.validate(memory:memory,records:records);return result
    }
    public static func prune(directory:URL,memories:[PhotoMemory],records:[AppointmentItem])throws {
        guard FileManager.default.fileExists(atPath:directory.path)else{return}
        for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey]) where file.pathExtension=="json" {
            let valid=memories.contains { memory in
                !records.contains{$0.dismissed && $0.allSources.contains(AppointmentSource(memory))}
                && (try? load(file:file,memory:memory,records:records)) != nil
            }
            if !valid{try FileManager.default.removeItem(at:file)}
        }
    }

}
