import Foundation
import PinCore
import IBrainSemantics
import IBrain

/// Ephemeral, opaque native answer context. Only a validated SDK answer or
/// current native inspection constructs it; it cannot be decoded from storage.
public struct PinRecordQuestionContext:Sendable {
    let sdk:EvidenceQuestionContext
    let stamp:String
    public var answerID:UUID{sdk.answerID}
    public var selectedOrdinal:Int?{sdk.selectedOrdinal}
    public var window:AppointmentWindow {
        switch EvidenceQuestionHostInspection.window(in:sdk){case .all:return .all;case .interval(let interval):return .interval(interval)}
    }
    public var submittedAt:Date{EvidenceQuestionHostInspection.submittedAt(in:sdk)}
    public var displayTimeZone:TimeZone{EvidenceQuestionHostInspection.displayTimeZone(in:sdk)}
}

/// Source-bound native rows selected by the SDK's actual question operation.
/// No model-authored field strings or native IDs become new domain facts.
public struct PinRecordQuestionAnswer:Sendable {
    public let originalViewRequest:PinOriginalViewRequest?
    public let originalViewIssue:OriginalViewIssue?
    public let route:String
    public let matched:[AppointmentItem]
    public let unresolved:[AppointmentItem]
    public let unresolvedDetails:[String:[String]]
    public let location:String?
    public let comparison:[String:String]
    public let changeExplanations:[RecordChangeExplanation]
    public let clarification:String?
    public let context:PinRecordQuestionContext?
    public let ordered:[AppointmentItem]
    public let receipt:DecisionReceipt
    /// The requested field selector only; factual before/after values still
    /// come from matched native history, never model-authored prose.
    public var requestedChangeFields:Set<String>? {
        let key=receipt.answers["route"]?.choice=="contextual" ? "contextual__changeField":"changeField"
        guard route=="changes",let selected=try? receipt.choice(key)else{return nil}
        switch selected {
        case "venue":return ["venue","venueAddress"]
        case "date","performer","title","provider","status":return [selected]
        case "all":return ["date","performer","title","provider","status","kind","venue","venueAddress"]
        default:return nil
        }
    }
}

/// Distinguish source invalidation from transport/setup failures. A network
/// failure must never tell the person that their appointment facts changed.
public enum PinRecordQuestionIssue:Sendable {
    case staleContext,unapproved,unavailable,testEnded
    public static func classify(_ error:Error)->Self {
        if error is PinEvidenceError{return .staleContext}
        if let native=error as? MemoryError {
            switch native {
            case .stalePermit,.staleResult,.invalidContext,.invalidOrdinal,.withdrawn,.closed,.needsSynchronization,.invalidSnapshot,.invalidEvidence,.unvalidatedRecord:return .staleContext
            default:return .unavailable
            }
        }
        if case .testEnded?=error as? PinDevelopmentError{return .testEnded}
        if case .sourceNotAllowed?=error as? PinDevelopmentError{return .unapproved}
        return .unavailable
    }
}
