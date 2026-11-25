import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Derived terminal-attempt evidence, never a canonical record or read permit.
/// A cold use reconstructs the unchanged initial task from current native data.
public enum PinSourcePreparationArchive {
    private struct Packet:Codable {
        let schema:Int
        let version:String
        let source:SourceSnapshot
        let receipt:DecisionReceipt
        let temporalPolicy:ObservationTemporalPolicy?
        let initialPolicy:PinInitialSourcePolicy?
    }
    public static func assess(memory:PhotoMemory,receipt:DecisionReceipt,accessGranted:Bool,temporalPolicy:ObservationTemporalPolicy = .anchoredSpansV8,initialPolicy:PinInitialSourcePolicy = .legacy)throws->VisualSourcePreparationAssessment {
        guard accessGranted,[.anchoredSpansV8,.anchoredSpansV9].contains(temporalPolicy) else{throw PinEvidenceError.staleRecord}
        let request=try PinSealedSourcePipeline.request(memory,temporalPolicy:temporalPolicy)
        let policy=initialPolicy.selected(for:memory),task=try policy.task(request)
        let result=try policy.assess(request,task:task,receipt:receipt)
        try result.validate(source:request.source);return result
    }
    public static func save(file:URL,memory:PhotoMemory,receipt:DecisionReceipt,accessGranted:Bool,temporalPolicy:ObservationTemporalPolicy = .anchoredSpansV8,initialPolicy:PinInitialSourcePolicy = .legacy)throws {
        let result=try assess(memory:memory,receipt:receipt,accessGranted:accessGranted,temporalPolicy:temporalPolicy,initialPolicy:initialPolicy)
        guard result.state != .candidate,result.candidate==nil else{throw PinEvidenceError.invalidSupport}
        let request=try PinSealedSourcePipeline.request(memory,temporalPolicy:temporalPolicy)
        let packet=Packet(schema:initialPolicy.selected(for:memory) == .legacy ? 1:2,version:VisualSourcePreparationInterpreter.version,source:request.source,receipt:receipt,temporalPolicy:temporalPolicy == .anchoredSpansV8 ? nil:temporalPolicy,initialPolicy:initialPolicy.selected(for:memory) == .legacy ? nil:initialPolicy.selected(for:memory))
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(packet);guard bytes.count<=262144 else{throw PinDevelopmentError.oversized}
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try PinPrivatePayloadWithdrawal.write(bytes,to:file,options:.atomic)
    }
    public static func load(file:URL,memory:PhotoMemory,accessGranted:Bool,temporalPolicy:ObservationTemporalPolicy = .anchoredSpansV8,initialPolicy:PinInitialSourcePolicy = .legacy)throws->VisualSourcePreparationAssessment {
        guard accessGranted,[.anchoredSpansV8,.anchoredSpansV9].contains(temporalPolicy) else{throw PinEvidenceError.staleRecord}
        let bytes=try Data(contentsOf:file);guard bytes.count<=262144 else{throw PinDevelopmentError.oversized}
        let packet=try JSONDecoder().decode(Packet.self,from:bytes)
        guard packet.schema==(initialPolicy.selected(for:memory) == .legacy ? 1:2),(packet.initialPolicy ?? .legacy)==initialPolicy.selected(for:memory),packet.version==VisualSourcePreparationInterpreter.version,
              (packet.temporalPolicy ?? .anchoredSpansV8)==temporalPolicy,
              packet.source == (try PinSealedSourcePipeline.request(memory,temporalPolicy:temporalPolicy)).source else{throw PinEvidenceError.staleRecord}
        let result=try assess(memory:memory,receipt:packet.receipt,accessGranted:accessGranted,temporalPolicy:temporalPolicy,initialPolicy:initialPolicy)
        guard result.state != .candidate,result.candidate==nil else{throw PinEvidenceError.invalidSupport}
        return result
    }
    public static func prune(directory:URL,memories:[PhotoMemory])throws {
        guard FileManager.default.fileExists(atPath:directory.path)else{return}
        for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where file.pathExtension=="json" {
            let data=try Data(contentsOf:file)
            let packet=data.count<=262144 ? try? JSONDecoder().decode(Packet.self,from:data):nil
            let valid=packet.map{packet in memories.contains{(try? load(file:file,memory:$0,accessGranted:true,temporalPolicy:packet.temporalPolicy ?? .anchoredSpansV8,initialPolicy:packet.initialPolicy ?? .legacy)) != nil}} ?? false
            if !valid{try FileManager.default.removeItem(at:file)}
        }
    }
}
