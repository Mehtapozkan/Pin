import Foundation
import PinCore
import IBrain

/// Converts already-bound field proposals into Pin's existing canonical writer.
/// Canonical identity/revision always comes from the native write ticket.
public enum PinCanonicalMapping {
    public static func draft(_ binding: PinEvidenceBinding, primarySourceID: String) throws -> CanonicalAppointmentDraft {
        let p=binding.projection,a=p.appointment
        guard p.sources.contains(where:{$0.id==primarySourceID}) else{throw PinEvidenceError.invalidSupport}
        let encoder=JSONEncoder(),decoder=JSONDecoder()
        let date=try decoder.decode(AppointmentDateComponents.self,from:encoder.encode(a.date))
        // A newer SDK may carry proof the native domain cannot persist yet.
        // Never admit a lossy DTO conversion as the same supported date.
        guard try decoder.decode(EventDate.self,from:encoder.encode(date)) == a.date else{throw PinEvidenceError.invalidSupport}
        let support=try decoder.decode([AppointmentSemanticField].self,from:encoder.encode(p.support))
        let facts=binding.fields.flatMap(\.nativeFacts)
        var observation=AppointmentObservation(sourceID:primarySourceID,title:a.title,evidence:facts.flatMap(\.support))
        observation.performer=a.performer;observation.provider=a.provider;observation.venue=a.venue;observation.address=a.venueAddress
        observation.components=date;observation.documentOnlyWithoutDate=p.documentOnlyWithoutDate
        observation.date=date.resolvedInstant;observation.printedDate=date.printedDateText;observation.printedTime=date.printedTimeText
        observation.timeZoneID=date.timeZoneID ?? "UTC";observation.zoneFromCard=date.timeZoneID != nil
        if let basis=date.captureYearDerivation {observation.inferredYear=date.year;observation.yearBasisDate=basis.originalCapturedAt}
        observation.eventTicket=a.kind == .eventTicket;observation.cancelled=a.status == .cancelled
        observation.fieldFacts=facts;observation.semanticVersion="pin-ibrain-components-v1"
        if let basis=date.temporalDerivation{observation.reviewReason=basis.disclosure}
        else if date.resolvedInstant==nil{observation.reviewReason="Some date or time details are missing. Check the original."}
        return CanonicalAppointmentDraft(recordID:p.recordID,recordRevision:p.recordRevision,observation:observation,
            sources:p.sources.map{AppointmentSource(EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision))}.sorted{$0.id<$1.id},support:support,documentOnlyWithoutDate:p.documentOnlyWithoutDate==true)
    }
    public static func projection(_ record: AppointmentItem, scope: MemoryScope) throws -> MemoryProjection {
        guard let id=record.canonicalRecordID,let revision=record.canonicalRevision,let date=record.observation.components,
              let support=record.semanticSupport else{throw PinEvidenceError.invalidRecord}
        let encoder=JSONEncoder(),decoder=JSONDecoder(),a=record.observation
        let eventDate=try decoder.decode(EventDate.self,from:encoder.encode(date))
        guard try decoder.decode(AppointmentDateComponents.self,from:encoder.encode(eventDate)) == date else{throw PinEvidenceError.invalidRecord}
        // The native booking-reference field retains the SDK candidate's
        // observed retrieval quote. SDK AppointmentProjection has no such
        // field: validate its native proof, then keep it outside that DTO.
        // It does not establish event identity or permission to merge records.
        let valueProof=try PinSelectedSourceValueProof.retained(record)
        let references=support.filter{$0.field=="bookingReference"}
        if valueProof?.result.bookingReference != nil {guard a.bookingReference != nil else{throw PinEvidenceError.invalidRecord}}
        if a.bookingReference != nil || !references.isEmpty {
            guard references.count==1,let reference=references.first,reference.origin=="observed",
                  let value=a.bookingReference,reference.anchors.count==1,let anchor=reference.anchors.first,
                  record.allSources.contains(AppointmentSource(anchor.source)),
                  let facts=a.fieldFacts?.filter({$0.field=="bookingReference"}),facts.count==1,let fact=facts.first,
                  fact.value==value,fact.origin == .observed,fact.source==anchor.source,
                  fact.extractorVersion==reference.extractorVersion,fact.support.count==1,
                  reference.confidence==Double(fact.confidence) else{throw PinEvidenceError.invalidRecord}
            if let valueProof {
                guard reference.extractorVersion.hasPrefix("pin-source-booking-reference/2/"),
                      let selection=valueProof.result.bookingReference,
                      valueProof.context.bookingReference==selection.originalAnchor,
                      selection.originalAnchor.source.id==anchor.source.id,selection.originalAnchor.observationID==anchor.observationID,
                      selection.originalAnchor.quote==anchor.quote,selection.valueQuote==value,
                      fact.support.first?.text==anchor.quote else{throw PinEvidenceError.invalidRecord}
            }else{
                guard reference.extractorVersion.hasPrefix("pin-source-booking-reference/1/"),anchor.quote==value,
                      fact.support.first?.text==value else{throw PinEvidenceError.invalidRecord}
            }
        }
        let fields=try decoder.decode([FieldSupport].self,from:encoder.encode(support.filter{$0.field != "bookingReference"}))
        return MemoryProjection(recordID:id,recordRevision:revision,scope:scope,
            appointment:AppointmentProjection(title:a.title,provider:a.provider,venue:a.venue,date:eventDate,
                kind:a.eventTicket==true ? .eventTicket:.appointment,status:a.cancelled==true ? .cancelled:.scheduled,
                performer:a.performer,venueAddress:a.address),support:fields,documentOnlyWithoutDate:a.documentOnlyWithoutDate==true)
    }
    public static func pin(_ record: AppointmentItem) throws -> PinRecordPin {
        guard let id=record.canonicalRecordID,let revision=record.canonicalRevision else{throw PinEvidenceError.invalidRecord}
        return PinRecordPin(id:id,revision:revision,sources:Set(record.allSources.map{EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)}))
    }
}
