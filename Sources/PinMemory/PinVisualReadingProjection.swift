import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Rebuilds derived SDK evidence from the current native source. Text keeps its
/// existing native observation IDs; visual claims retain their receipt/regions.
/// The reader's document count and partial coverage are never promoted to truth.
public enum PinVisualReadingProjection {
    public static func labelID(_ reading:PhotoVisualReading,index:Int)->String {"pin-visual-v1:\(index):\(reading.receiptSHA256)"}
    public static func source(memory:PhotoMemory,scope:MemoryScope,textObservations:[SourceObservation])throws->SourceSnapshot {
        let reference=SourceReference(id:memory.id,revision:memory.revision,fingerprint:memory.fingerprint)
        guard let reading=memory.visualReading else{return SourceSnapshot(reference:reference,scope:scope,observations:textObservations,capturedAt:memory.photographedAt)}
        try reading.validate(for:memory)
        let receipt=try reading.validatedReceipt()
        var observations=textObservations
        for (i,o) in receipt.observations.enumerated() where o.kind=="visualLabel" {
            observations.append(SourceObservation(id:labelID(reading,index:i),kind:.visualLabel,value:o.value))
        }
        if receipt.visibleDocumentCount>1 {observations.append(SourceObservation(id:labelID(reading,index:64),kind:.visualLabel,value:"reader-reports-multiple-documents"))}
        guard let coverage=SourceReadCoverage(rawValue:receipt.coverage)else{throw PinEvidenceError.invalidSupport}
        let assessment=try SourceReadAssessment(source:reference,coverage:coverage,reader:receipt.provider+"/"+receipt.model+"/verbatimFieldsV2/confidence-unavailable",receiptSHA256:reading.receiptSHA256,observations:observations)
        return SourceSnapshot(reference:reference,scope:scope,observations:observations,capturedAt:memory.photographedAt,readAssessment:assessment)
    }
    public static func groupingRequest(_ memory:PhotoMemory)throws->VisualGroupingRequest {
        guard let reading=memory.visualReading else{throw PinEvidenceError.invalidSource}
        try reading.validate(for:memory)
        let receipt=try reading.validatedReceipt(),request=try PinDevelopmentSourceReader.request(memory)
        var regions:[String:ObservationRegion]=[:],textIndex=0
        for (i,o) in receipt.observations.enumerated() {
            let id:String
            if o.kind=="text" {guard request.lines.indices.contains(textIndex)else{throw PinEvidenceError.invalidSupport};id=request.lines[textIndex].id;textIndex += 1}
            else{id=labelID(reading,index:i)}
            let b=PhotoVisualReading.region(o.box)
            regions[id]=ObservationRegion(x:b.x,y:b.y,width:b.width,height:b.height)
        }
        let result=VisualGroupingRequest(taskID:"pin-visual-groups-"+memory.id+"-"+String(memory.revision),source:request.source,lines:request.lines,observationRegions:regions,reportedDocumentCount:receipt.visibleDocumentCount)
        try result.validate();return result
    }
}
