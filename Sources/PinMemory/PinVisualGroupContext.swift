import Foundation
import PinCore
import IBrain
import IBrainSemantics

private final class PinValidatedGroupingCache:@unchecked Sendable {
    private let lock=NSLock()
    private var value:VisualObservationGrouping?
    func load()->VisualObservationGrouping? {lock.lock();defer{lock.unlock()};return value}
    func save(_ value:VisualObservationGrouping){lock.lock();defer{lock.unlock()};self.value=value}
}

/// Derived grouping receipt and original inputs. Decoding this packet never
/// restores authority: each use reconstructs against the full current memory.
public struct PinVisualGroupContext:Codable,Sendable {
    private let cache=PinValidatedGroupingCache()
    private enum CodingKeys:String,CodingKey {case schema,ordinal,taskID,source,lines,regions,count,receipt,retainedInitialReceipt}
    public let schema:Int
    public let ordinal:Int
    private let taskID:String
    private let source:SourceSnapshot
    private let lines:[ObservedLine]
    private let regions:[String:ObservationRegion]
    private let count:Int
    public let receipt:DecisionReceipt
    public let retainedInitialReceipt:DecisionReceipt?
    public var isRetainedOCR:Bool {[2,3].contains(schema) && retainedInitialReceipt != nil}
    public var retainedRevisionPolicy:RetainedOCRGroupingRevisionPolicy? {schema==2 ? .initialSourceV1:schema==3 ? .currentSourceV2:nil}
    public init(memory:PhotoMemory,receipt:DecisionReceipt,ordinal:Int)throws {
        let request=try PinVisualReadingProjection.groupingRequest(memory)
        self.schema=1;self.ordinal=ordinal;self.taskID=request.taskID;self.source=request.source;self.lines=request.lines
        self.regions=request.observationRegions;self.count=request.reportedDocumentCount;self.receipt=receipt;self.retainedInitialReceipt=nil
        _=try evidence(memory:memory)
    }
    public init(memory:PhotoMemory,initialReceipt:DecisionReceipt,groupingReceipt:DecisionReceipt,ordinal:Int,revisionPolicy:RetainedOCRGroupingRevisionPolicy = .initialSourceV1)throws {
        guard (1...3).contains(ordinal) else{throw PinEvidenceError.invalidSupport}
        let request=try PinRetainedOCRGrouping.request(memory:memory,initialReceipt:initialReceipt,revisionPolicy:revisionPolicy)
        let grouping=try RetainedOCRSourceGrouper.compile(request,task:RetainedOCRSourceGrouper.task(request),receipt:groupingReceipt)
        self.schema=revisionPolicy == .initialSourceV1 ? 2:3;self.ordinal=ordinal;self.taskID=request.taskID;self.source=request.initialRequest.source;self.lines=request.initialRequest.lines
        self.regions=Dictionary(uniqueKeysWithValues:lines.compactMap{line in line.region.map{(line.id,$0)}})
        self.count=grouping.scopes.count;self.receipt=groupingReceipt;self.retainedInitialReceipt=initialReceipt
        _=try grouping.evidence(ordinal:ordinal);cache.save(grouping)
    }
    public func grouping(memory:PhotoMemory)throws->VisualObservationGrouping {
        if let revisionPolicy=retainedRevisionPolicy {
            guard let retainedInitialReceipt,(1...3).contains(ordinal) else{throw PinEvidenceError.staleRecord}
            guard memory.revision>0,memory.visualReading==nil,revisionPolicy == .currentSourceV2 || memory.revision==1 else{throw PinEvidenceError.staleRecord}
            let current=try PinSealedSourcePipeline.request(memory,temporalPolicy:.anchoredSpansV9)
            let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            let currentRegions=Dictionary(uniqueKeysWithValues:current.lines.compactMap{line in line.region.map{(line.id,$0)}})
            let expectedID=revisionPolicy == .initialSourceV1 ? "pin-retained-ocr-groups-"+memory.id+"-1":"pin-current-ocr-groups-"+memory.id+"-"+String(memory.revision)
            guard taskID==expectedID,current.source==source,
                  try e.encode(current.lines)==e.encode(lines),try e.encode(currentRegions)==e.encode(regions) else{throw PinEvidenceError.staleRecord}
            // Cache only an already validated immutable SDK result. Every hit
            // still compares the entire current source, text, confidence and
            // optional geometry. Decoding always starts with an empty cache.
            if let grouping=cache.load(){return grouping}
            let request=try PinRetainedOCRGrouping.request(memory:memory,initialReceipt:retainedInitialReceipt,revisionPolicy:revisionPolicy)
            let grouping=try RetainedOCRSourceGrouper.compile(request,task:RetainedOCRSourceGrouper.task(request),receipt:receipt)
            guard grouping.scopes.count==count else{throw PinEvidenceError.staleRecord};cache.save(grouping);return grouping
        }
        guard retainedInitialReceipt==nil else{throw PinEvidenceError.staleRecord}

        let current=try PinVisualReadingProjection.groupingRequest(memory)
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        guard schema==1,(1...3).contains(ordinal),current.taskID==taskID,current.source==source,current.reportedDocumentCount==count,
              try e.encode(current.lines)==e.encode(lines),try e.encode(current.observationRegions)==e.encode(regions)else{throw PinEvidenceError.staleRecord}
        return try BoundedVisualSourceGrouper.compile(current,task:BoundedVisualSourceGrouper.task(current),receipt:receipt)
    }
    public func evidence(memory:PhotoMemory)throws->VisualGroupEvidence {
        let evidence=try grouping(memory:memory).evidence(ordinal:ordinal)
        try evidence.validate(currentFullSource:PinDevelopmentSourceReader.request(memory).source);return evidence
    }
    public func request(memory:PhotoMemory,temporalPolicy:ObservationTemporalPolicy)throws->ObservationRequest {
        guard temporalPolicy == .anchoredSpansV9 else{throw PinDevelopmentError.sourceNotAllowed}
        let original=try PinSealedSourcePipeline.request(memory,temporalPolicy:temporalPolicy)
        return try grouping(memory:memory).request(ordinal:ordinal,taskID:original.taskID+"-group"+String(ordinal),temporalPolicy:temporalPolicy)
    }
    public func validate(memory:PhotoMemory,projection:MemoryProjection)throws {
        try evidence(memory:memory).validate(currentFullSource:PinDevelopmentSourceReader.request(memory).source,projection:projection)
    }
}

public enum PinVisualGroupingArchive {
    public static func save(file:URL,context:PinVisualGroupContext,memory:PhotoMemory,accessGranted:Bool)throws {
        guard accessGranted else{throw PinEvidenceError.staleRecord};_=try context.evidence(memory:memory)
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];let data=try e.encode(context)
        guard data.count<=262144 else{throw PinDevelopmentError.oversized}
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try PinPrivatePayloadWithdrawal.write(data,to:file,options:.atomic)
    }
    public static func load(file:URL,memory:PhotoMemory,accessGranted:Bool)throws->PinVisualGroupContext {
        guard accessGranted else{throw PinEvidenceError.staleRecord}
        guard try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max <= 262144 else{throw PinDevelopmentError.oversized}
        let context=try JSONDecoder().decode(PinVisualGroupContext.self,from:Data(contentsOf:file));_=try context.evidence(memory:memory);return context
    }
}
