import Foundation
import PinCore
import IBrain
import IBrainSemantics
import IBrainRetrieval

/// Neither mode authorizes new photo acquisition. The caller supplies only
/// current permitted observations from the existing native index owner.
public enum PinProjectionSourceInventory:Equatable,Sendable {
    case appointmentEvidence
    case permittedPhotoObservations
}

/// Coverage of this bounded query over prepared observations, NOT a count of
/// all Photos assets, iCloud downloads, personal events or completed reading.
public struct PinRetrievalCoverage:Sendable {
    public let preparedSources:Int
    public let searchableSources:Int
    public let inspectedSources:Int
    public let admittedRecords:Int
    public let candidateRecords:Int
    public let sourcesNeedingPreparation:Set<PinCore.EvidenceSource>
    public let dismissedSources:Set<PinCore.EvidenceSource>
    public let sourcesWithUncertainRelevance:Set<PinCore.EvidenceSource>
    public var entireAdmittedInventory:Bool{false}
    public var canAssertGlobalAbsence:Bool{false}
    public var personalCalendarComplete:Bool{false}
    public var sourcesWithoutSearchableEvidence:Int{preparedSources-searchableSources}
    public var notice:String {
        if !sourcesNeedingPreparation.isEmpty {
            return "Some relevant photos still need their appointment details read. These results may be incomplete."
        }
        if !sourcesWithUncertainRelevance.isEmpty {
            return "Some photos need checking for relevance. These results cover only the evidence found in this search."
        }
        return "From the evidence found in this search. Other photos may contain matching appointments."
    }
    init(_ prepared:PreparedAppointmentRetrieval,dismissedSources excluded:Set<PinCore.EvidenceSource>) {
        let c=prepared.coverage
        preparedSources=c.accessibleSources;searchableSources=c.sourcesWithSearchableText
        inspectedSources=c.inspectedSources;admittedRecords=c.admittedRecords;candidateRecords=c.candidateRecords
        func source(_ s:SourceReference)->PinCore.EvidenceSource{.init(id:s.id,fingerprint:s.fingerprint,revision:s.revision)}
        let unlinked=Set(prepared.sourcesWithoutRecords.map(source))
        dismissedSources=unlinked.intersection(excluded)
        sourcesNeedingPreparation=unlinked.subtracting(excluded)
        sourcesWithUncertainRelevance=Set(prepared.unresolvedSources.map{source($0.source)})
    }
}

public enum PinRetrievalStage:Equatable,Sendable {
    case noRankedCandidates,noRelevantCandidates,sourcePreparationRequired,candidatesReady,excludedByUser
    init(_ prepared:PreparedAppointmentRetrieval,dismissedSources:Set<PinCore.EvidenceSource>) {
        if prepared.stage == .sourcePreparationRequired,!prepared.sourcesWithoutRecords.isEmpty,prepared.sourcesWithoutRecords.allSatisfy({dismissedSources.contains(.init(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision))}) {self = .excludedByUser;return}
        switch prepared.stage {
        case .noRankedCandidates:self = .noRankedCandidates
        case .noRelevantCandidates:self = .noRelevantCandidates
        case .sourcePreparationRequired:self = .sourcePreparationRequired
        case .candidatesReady:self = .candidatesReady
        }
    }
    public var emptyNotice:String {
        switch self {
        case .excludedByUser:return "The matching entries were dismissed and remain excluded."
        case .noRankedCandidates:return "This search hasn’t found matching photo evidence. That doesn’t establish that no appointment exists."
        case .noRelevantCandidates:return "The photos checked didn’t establish a matching appointment. Other evidence may still be relevant."
        case .sourcePreparationRequired:return "Relevant photos were found, but their appointment details still need reading."
        case .candidatesReady:return "No matching appointment was established within the evidence found in this search."
        }
    }
}

/// Opaque and ephemeral. It grants no canonical writes or permission to read
/// new photos. Use the same active request through answer and publication.
public struct PinPreparedRetrievedQuestion:Sendable {
    public let requestID:UUID
    let owner:UUID
    let stamp:String
    let generation:Int
    let engine:AppointmentRetrievalSession
    let sdk:PreparedAppointmentRetrieval
    let dismissedSources:Set<PinCore.EvidenceSource>
}

/// A computed answer is not display authority. The caller must pass this to
/// admitRetrievedQuestion after its native foreground/access/request checks.
public struct PinPreparedRetrievedAnswer:Sendable {
    let prepared:PinPreparedRetrievedQuestion
    let sdk:PreparedRetrievedAppointmentAnswer
    let generation:Int
    let identity:UUID
}

public struct PinRetrievedQuestionAnswer:Sendable {
    public let requestID:UUID
    public let answer:PinRecordQuestionAnswer?
    public let coverage:PinRetrievalCoverage
    public let stage:PinRetrievalStage
    let prepared:PinPreparedRetrievedAnswer
}

struct PinCancellableDecisionProvider:DecisionProvider {
    let base:any DecisionProvider
    func decide(_ task:ChoiceTask)async throws->DecisionReceipt {
        try Task.checkCancellation()
        let result=try await base.decide(task)
        try Task.checkCancellation()
        return result
    }
}

struct PinCancellableCompactQueryProvider:CompactProductQueryProvider {
    let base:any CompactProductQueryProvider
    func decide(_ task:CompactProductQueryTask)async throws->CompactProductQueryReceipt {
        try Task.checkCancellation()
        let result=try await base.decide(task)
        try Task.checkCancellation()
        return result
    }
}
