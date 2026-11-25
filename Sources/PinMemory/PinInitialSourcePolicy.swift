import Foundation
import PinCore
import IBrainSemantics

/// Selects a native task contract. Raw receipts always retain their real task
/// identity; later group and completion decisions keep their existing contracts.
public enum PinInitialSourcePolicy:String,Codable,Sendable {
    case legacy
    case compactKeysV1 = "native-compact-question-keys-v1"
    /// Opt-in only: compact current single-document image-backed replacements.
    case compactCurrentVisualV1 = "native-compact-current-visual-v1"
    case initialImageFirstV1 = "native-image-first-current-visual-v1"
    public var usesCompactKeys:Bool {self != .legacy}
    public static func configured(_ value:String?)throws->Self {
        guard let value else{return .legacy}
        guard let policy=Self(rawValue:value),policy.usesCompactKeys else{throw PinDevelopmentError.configuration}
        return policy
    }
    public func selected(for memory:PhotoMemory)->Self {
        guard usesCompactKeys else{return .legacy}
        if memory.revision==1 && memory.visualReading==nil{return .compactKeysV1}
        if (self == .compactCurrentVisualV1 || self == .initialImageFirstV1),memory.revision>1,let visual=memory.visualReading,
           (try? visual.validate(for:memory)) != nil,let receipt=try? visual.validatedReceipt(),receipt.visibleDocumentCount==1{return .compactCurrentVisualV1}
        return .legacy
    }
    public func task(_ request:ObservationRequest)throws->ChoiceTask {
        if usesCompactKeys {
            guard request.temporalPolicy == .anchoredSpansV9,request.visualGroupScope==nil,
                  (self == .compactKeysV1 ? request.source.reference.revision==1:request.source.reference.revision>1) else{throw PinDevelopmentError.configuration}
            return try VisualObservationInterpreter.compactTask(request)
        }
        return try VisualObservationInterpreter.task(request,detailPolicy:.componentsV4)
    }
    public func assess(_ request:ObservationRequest,task:ChoiceTask,receipt:DecisionReceipt)throws->VisualSourcePreparationAssessment {
        if usesCompactKeys{return try VisualSourcePreparationInterpreter.assessCompact(request,task:task,receipt:receipt)}
        return try VisualSourcePreparationInterpreter.assess(request,task:task,receipt:receipt)
    }
    public func compile(_ request:ObservationRequest,task:ChoiceTask,receipt:DecisionReceipt)throws->AppointmentCandidate {
        if usesCompactKeys{return try VisualObservationInterpreter.compileCompact(request,task:task,receipt:receipt)}
        return try VisualObservationInterpreter.compile(request,task:task,receipt:receipt,detailPolicy:.componentsV4)
    }
}
