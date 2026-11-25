import Foundation
import PinCore
import IBrain
import IBrainSemantics

public enum PinPreparedProductAnswer:Sendable {
    case inventory(PinPreparedExhaustiveAnswer)
    case contextual(PinRecordQuestionAnswer)
    case unsupported
}
public enum PinProductQuestionAnswer:Sendable {
    case units(PinUnitQuestionAnswer,reconciliation:PinProductReconciliation?=nil)
    case unitContextual(PinUnitContextualAnswer)
    case unitLinkedContextual(PinLinkedUnitContextualAnswer)
    case inventory(PinExhaustiveQuestionAnswer,reconciliation:PinProductReconciliation?=nil)
    case contextual(PinRecordQuestionAnswer)
    case unsupported
}

/// Process-local query owner. No persisted continuation, model retry or new
/// photo grant is implied by this handle.
public struct PinPreparedExhaustiveQuestion:Sendable {
    public let requestID:UUID
    let owner:UUID
    let stamp:String
    let generation:Int
    let engine:ExhaustiveAppointmentSession
    let dismissedSources:Set<PinCore.EvidenceSource>
}
public struct PinPreparedExhaustiveAnswer:Sendable {
    public let question:PinPreparedExhaustiveQuestion
    let sdk:ExhaustiveAppointmentAnswer
    let generation:Int
}
/// Same-request meaning only. It contains no native rows or source authority.
/// Explicit cancellation/new questions and a different cache owner revoke it.
public struct PinCapturedExhaustiveInterpretation:Sendable {
    let owner:UUID
    let requestID:UUID
    let generation:Int
    let sdk:ExhaustiveQuestionInterpretation
    let originalStamp:String
    let originalReceiptSHA256:String
    let missingSources:Set<PinCore.EvidenceSource>
}
public struct PinMissingQuestionEvidence:Sendable {
    public let source:PinCore.EvidenceSource
    public let recordIDs:Set<String>
    public let fields:Set<String>
    public let reasons:Set<String>
}
public struct PinExhaustiveQuestionCoverage:Sendable {
    public let totalRecords:Int
    public let inspectedRecords:Int
    public let unknownMembershipRecords:Int
    public let unprojectedRecords:Int
    public let unlinkedSources:Int
    public let sourcesWithReadingGaps:Int
    public let pendingSourcePreparations:Int
    public let dismissedSourceTargets:Int
    public var entireAdmittedInventory:Bool{inspectedRecords==totalRecords}
    public var membershipComplete:Bool{entireAdmittedInventory && unknownMembershipRecords==0}
    public var personalCalendarComplete:Bool{false}
    public var canAssertPhotoLibraryAbsence:Bool{false}
    public var notice:String {
        if !entireAdmittedInventory{return "Checked \(inspectedRecords) of \(totalRecords) saved entries. The answer may change as the remaining entries are checked."}
        if pendingSourcePreparations>0{return "Some photo evidence still needs reading or preparation. The matches and count cover saved entries only; other depicted events may remain unresolved."}
        if unknownMembershipRecords>0{return "All saved entries were checked, but some lack the facts needed to decide whether they match."}
        if unprojectedRecords>0 || unlinkedSources>0 || sourcesWithReadingGaps>0 || pendingSourcePreparations>0{return "All saved entries were checked. Some photo evidence still needs reading or preparation; these results may not include every appointment in your photos."}
        return "Based on all saved entries. This does not establish that every appointment in your photos has been found."
    }
    init(_ value:ExhaustiveAppointmentCoverage,dismissed:Int) {
        totalRecords=value.totalRecords;inspectedRecords=value.inspectedRecords
        unknownMembershipRecords=value.unknownMembershipRecords;unprojectedRecords=value.unprojectedRecords
        unlinkedSources=value.unlinkedSources;sourcesWithReadingGaps=value.sourcesWithReadingGaps;pendingSourcePreparations=value.pendingSourcePreparations
        dismissedSourceTargets=dismissed
    }
}
/// Exact native rows and admitted-record counts. It is never an unqualified
/// answer about all Photos, the person's calendar or all events on one image.
public struct PinExhaustiveQuestionAnswer:Sendable {
    public var pendingResultUnit:AppointmentResultUnit?{pending.sdk.plan.resultUnit}
    public var receipt:DecisionReceipt{pending.sdk.plan.receipt}
    public let requestID:UUID
    public let operation:String
    public let matches:[AppointmentItem]
    public let uncertain:[AppointmentItem]
    public let extremeRecords:[AppointmentItem]?
    public let unresolvedDetails:[String:Set<String>]
    public let missingEvidence:[PinMissingQuestionEvidence]
    public let coverage:PinExhaustiveQuestionCoverage
    public let admittedCountLowerBound:Int
    public let admittedCountUpperBound:Int
    public let exactAdmittedCount:Int?
    public let canAssertNoMatchInAdmittedRecords:Bool
    public let requestedAnswerComplete:Bool
    public let sourceStatusEvidence:PinSourceStatusEvidenceAnswer?
    public var canAssertNoMatchInPreparedSources:Bool{false}
    public var summary:String {
        if operation=="sourceEvidence"{return "What the saved photo evidence establishes"}
        if operation=="count" {
            if let count=exactAdmittedCount{return "\(count) matching saved \(count==1 ? "entry":"entries")"}
            return "Between \(admittedCountLowerBound) and \(admittedCountUpperBound) saved entries may match."
        }
        if operation=="earliest" || operation=="latest" {
            guard let extremeRecords else{return "The \(operation) matching entry is not settled yet. Some entries or event times still need checking."}
            if extremeRecords.isEmpty{return "No matching saved entry was established."}
            return extremeRecords.count==1 ? "\(operation.capitalized) matching saved entry":"\(extremeRecords.count) saved entries share the \(operation) event time."
        }
        if matches.isEmpty{return canAssertNoMatchInAdmittedRecords ? "No matching saved entries":"No matches established yet"}
        return coverage.membershipComplete ? "Matching saved entries":"Matches found so far"
    }
    public var displayRows:[AppointmentItem] {
        if operation=="earliest" || operation=="latest"{return extremeRecords ?? []}
        return matches
    }
    let pending:PinPreparedExhaustiveAnswer
}

/// A reviewed subset of the current answer's targets. This is a plan only,
/// not permission to acquire pixels, call a reader or commit new facts.
public struct PinQuestionEvidencePlan:Sendable {
    public let targets:[PinMissingQuestionEvidence]
    public let withheldTargetCount:Int
    public let dismissedTargetCount:Int
    public let requiresFreshQueryAfterCanonicalCommit:Bool=true
}

/// A presentation DTO only, emitted after whole-answer admission. It grants no
/// independent source access; the parent answer remains the authority.
public struct PinSourceStatusEvidenceAnswer:Codable,Sendable {
    public struct Support:Codable,Sendable {
        public let source:PinCore.EvidenceSource
        public let observationID:String
        public let quote:String
        public let origin:String
        public var originLabel:String {
            switch origin {
            case "domainCorrection":return "Owner correction"
            case "observed":return "Photo evidence"
            default:return "Source interpretation"
            }
        }
    }
    public struct Row:Codable,Sendable {
        public let recordID:String
        public let cancellation:String
        public let support:[Support]
        public var notice:String {
            switch cancellation {
            case "observedCancellation":return "Cancellation is documented in the current photo evidence."
            case "correctedCancellation":return "An owner correction records cancellation."
            default:return "Cancellation has not been established in the extracted evidence."
            }
        }
    }
    public let requested:Set<String>
    public let rows:[Row]
    public let currentPersonalBookingNotEstablished:Bool
    public let admittedClaimReviewComplete:Bool
    public var canAssertNoCancellationInPhotos:Bool{false}
    public var personalCalendarComplete:Bool{false}
    public var personalBookingNotice:String? {
        currentPersonalBookingNotEstablished ? "These photos alone do not establish current bookings belonging to you. They also do not prove that you have no bookings.":nil
    }
    public var cancellationLimitNotice:String? {
        requested.contains("documentedStatus") ? "This does not establish that no cancellation notice appears in the photos.":nil
    }
    init(_ sdk:SourceStatusEvidenceAnswer) {
        requested=Set(sdk.requested.map(\.rawValue))
        rows=sdk.rows.map { row in
            Row(recordID:row.record.projection.recordID,cancellation:row.cancellation.rawValue,support:row.statusSupport.flatMap { support in
                support.anchors.map { anchor in
                    Support(source:.init(id:anchor.source.id,fingerprint:anchor.source.fingerprint,revision:anchor.source.revision),observationID:anchor.observationID,quote:anchor.quote,origin:support.origin.rawValue)
                }
            })
        }
        currentPersonalBookingNotEstablished=sdk.currentPersonalBooking != nil
        admittedClaimReviewComplete=sdk.admittedClaimReviewComplete
    }
}
