import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Ephemeral native binding of the SDK's typed view proposal. Creation is
/// internal and requires the actual answer, exact canonical row and proof sets.
/// No Codable/public initializer; this is not permission or durable action state.
public struct PinOriginalViewRequest: Sendable {
    let sdk: OriginalViewRequest
    let stamp: String
    public let item: AppointmentItem
    public let sources: [AppointmentSource]
    public var answerID: UUID { sdk.answerID }
    public var recordID: String { sdk.recordID }
    public var recordRevision: Int { sdk.recordRevision }
    public var supportingSources: Set<AppointmentSource> {
        Set(item.allSources+(item.previousEvidence?.sources ?? []))
    }
    init(validating request: OriginalViewRequest, item: AppointmentItem,
         scope: MemoryScope, context: PinRecordQuestionContext) throws {
        guard request.answerID==context.answerID,
              request.recordID==item.canonicalRecordID,
              request.recordRevision==item.canonicalRevision,
              request.scope==scope, !item.dismissed,
              (1...2).contains(request.versions.count),
              Set(request.versions.map(\.rawValue)).count==request.versions.count else { throw PinEvidenceError.staleRecord }
        let current=try PinCanonicalMapping.projection(item,scope:scope)
        let previous=try PinCapturedAppointmentRevision.previousRow(of:item).map{try PinCanonicalMapping.projection($0,scope:scope)}
        guard current.sources==request.currentSources else { throw PinEvidenceError.invalidSupport }
        if request.versions.contains(.previous) || !request.previousSources.isEmpty {
            guard let previous, previous.sources==request.previousSources else { throw PinEvidenceError.invalidSupport }
        }
        func reference(_ source:AppointmentSource)->SourceReference {
            SourceReference(id:source.id,revision:source.revision,fingerprint:source.fingerprint)
        }
        let resolved=try request.versions.map{version->AppointmentSource in
            switch version {
            case .current:
                guard request.currentSources.contains(reference(item.source)) else { throw PinEvidenceError.invalidSupport }
                return item.source
            case .previous:
                guard let old=item.previousEvidence?.source,
                      request.previousSources.contains(reference(old)) else { throw PinEvidenceError.invalidSupport }
                return old
            }
        }
        guard Set(resolved.map(\.id)).count==resolved.count else { throw PinEvidenceError.invalidSupport }
        self.sdk=request; self.stamp=context.stamp; self.item=item; self.sources=resolved
    }
    public func isBound(to context: PinRecordQuestionContext?) -> Bool {
        context.map{$0.answerID==answerID && $0.stamp==stamp} ?? false
    }
    public func sequence(requestID:UUID,context:PinRecordQuestionContext?,
                         authority:AppointmentOriginalAuthority)->AppointmentOriginalSequence? {
        guard isBound(to:context) else { return nil }
        return AppointmentOriginalSequence.bind(item:item,requestedSources:sources,
            answerID:answerID,requestID:requestID,authority:authority)
    }
}
