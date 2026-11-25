import Foundation
import PinCore
import IBrainSemantics

/// Rebuilds a grouping continuation from current native OCR and the unchanged
/// initial model receipt. No visual reading/count or source revision is created.
public enum PinRetainedOCRGrouping {
    public static func request(memory:PhotoMemory,initialReceipt:DecisionReceipt,revisionPolicy:RetainedOCRGroupingRevisionPolicy = .initialSourceV1)throws->RetainedOCRGroupingRequest {
        guard memory.revision>0,memory.visualReading==nil,
              revisionPolicy == .currentSourceV2 || memory.revision==1 else{throw PinDevelopmentError.sourceNotAllowed}
        let initial=try PinSealedSourcePipeline.request(memory,temporalPolicy:.anchoredSpansV9)
        let taskID=revisionPolicy == .initialSourceV1 ? "pin-retained-ocr-groups-"+memory.id+"-1":"pin-current-ocr-groups-"+memory.id+"-"+String(memory.revision)
        return RetainedOCRGroupingRequest(taskID:taskID,initialRequest:initial,
            initialTask:try PinInitialSourcePolicy.compactKeysV1.selected(for:memory).task(initial),initialReceipt:initialReceipt,revisionPolicy:revisionPolicy)
    }
}
