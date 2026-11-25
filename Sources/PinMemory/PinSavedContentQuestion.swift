import Foundation
import PinCore
import IBrain
import IBrainRetrieval
import IBrainSemantics

/// Native presentation data plus opaque, process-local SDK authority.
/// Persisted IDs cannot recreate a displayed context or a read permission.
public struct PinSavedContentAnswer:Sendable {
    public let requestID:UUID
    public let answer:SavedContentAnswer
    /// Confirmed owner annotations from the exact admitted native projection.
    /// Their visibility does not depend on semantic excerpt selection.
    public var ownerInterpretations:[String:String] {
        guard answer.meaning.basis == .currentSaved else{return [:]}
        return Dictionary(uniqueKeysWithValues:answer.cards.compactMap {card in
            guard card.relevance == .relevant,
                  let row=rows.first(where:{$0.projection.recordID==card.recordID && $0.projection.recordRevision==card.recordRevision && Set($0.projection.sources)==Set(card.sources)}),
                  let claim=row.projection.claims.first(where:{$0.id=="native-saved-correction" && $0.origin == .domainCorrection}),
                  case .text(let text)=claim.value else{return nil}
            return (card.recordID,text)
        })
    }
    let owner:UUID
    let epoch:Int
    let stamp:String
    let engine:SavedContentQuestionSession
    let rows:[StoredWorldMemory]
    let replaySnapshot:SavedContentReplaySnapshot
    let replayQuery:SavedContentReplayQuery
    let replaySessionID:UUID?
}
public struct PinSavedContentContext:Sendable {
    public var orderedRecordIDs:[String]{sdk.orderedRecordIDs}
    let owner:UUID
    let sdk:SavedContentDisplayedContext
}
public enum PinSavedContentStage:Sendable,Equatable {
    case understanding
    case checkingEvidence(visited:Int,total:Int)
}

/// Native task/publication binding; implementations cannot interpret intent.
public protocol PinSavedContentReplayProviding: DecisionProvider {
    var replaySessionID: UUID { get }
    func bound(snapshot:SavedContentReplaySnapshot,query:SavedContentReplayQuery,
               history:[SavedContentReplayPublication]) throws -> any DecisionProvider
    func invalidate(requestID:UUID?)
}
