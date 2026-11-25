import Foundation
import CryptoKit

/// Printed components remain separate from a resolved instant and capture time.
public struct AppointmentDateComponents: Codable, Equatable, Sendable {
    public var year: Int?, month: Int?, day: Int?, hour: Int?, minute: Int?
    public var timeZoneID: String?, utcOffsetSeconds: Int?
    public var certainty: String
    public var captureYearDerivation: AppointmentCaptureYearBasis?
    public var temporalDerivation: AppointmentTemporalBasis?
    public var printedDateText: String?, printedTimeText: String?
    public init(year: Int? = nil, month: Int? = nil, day: Int? = nil, hour: Int? = nil, minute: Int? = nil,
                timeZoneID: String? = nil, utcOffsetSeconds: Int? = nil, certainty: String = "explicit",
                printedDateText: String? = nil, printedTimeText: String? = nil) {
        self.year=year;self.month=month;self.day=day;self.hour=hour;self.minute=minute
        self.timeZoneID=timeZoneID;self.utcOffsetSeconds=utcOffsetSeconds;self.certainty=certainty
        self.printedDateText=printedDateText;self.printedTimeText=printedTimeText
    }
    public var hasTemporalClaim: Bool {
        [year,month,day,hour,minute,utcOffsetSeconds].contains { $0 != nil } || timeZoneID != nil ||
            captureYearDerivation != nil || temporalDerivation != nil || printedDateText != nil || printedTimeText != nil
    }
    public var isValid: Bool {
        guard ["explicit","inferred","conflicting"].contains(certainty),
              year.map({(1...9999).contains($0)}) ?? true, month.map({(1...12).contains($0)}) ?? true,
              day.map({(1...31).contains($0)}) ?? true, hour.map({(0...23).contains($0)}) ?? true,
              minute.map({(0...59).contains($0)}) ?? true,
              timeZoneID.map({TimeZone(identifier:$0) != nil}) ?? true,
              utcOffsetSeconds.map({(-50400...50400).contains($0)}) ?? true else {return false}
        if let y=year,let m=month,let d=day {
            var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
            let parts=DateComponents(year:y,month:m,day:d)
            guard let date=cal.date(from:parts),cal.component(.year,from:date)==y,
                  cal.component(.month,from:date)==m,cal.component(.day,from:date)==d else{return false}
        }
        if let temporalDerivation{return temporalDerivation.validates(self)}
        return captureYearDerivation == nil || certainty == "inferred"
    }
    /// Unknown timezone/date/time never becomes an arbitrary device-zone instant.
    public var resolvedInstant: Date? {
        guard isValid,certainty != "conflicting",let year,let month,let day,let hour,let minute,
              let zoneID=timeZoneID,let zone=TimeZone(identifier:zoneID) else{return nil}
        var cal=Calendar(identifier:.gregorian);cal.timeZone=zone
        let dayParts=DateComponents(year:year,month:month,day:day)
        guard let start=cal.date(from:dayParts),cal.dateComponents([.year,.month,.day],from:start)==dayParts else{return nil}
        let parts=DateComponents(year:year,month:month,day:day,hour:hour,minute:minute,second:0)
        guard let first=cal.nextDate(after:start.addingTimeInterval(-1),matching:parts,matchingPolicy:.strict,repeatedTimePolicy:.first),
              let last=cal.nextDate(after:start.addingTimeInterval(-1),matching:parts,matchingPolicy:.strict,repeatedTimePolicy:.last) else{return nil}
        let resolved:Date
        if let offset=utcOffsetSeconds {
            guard let match=[first,last].first(where:{zone.secondsFromGMT(for:$0)==offset}) else{return nil}
            resolved=match
        }else{guard first==last else{return nil};resolved=first}
        if certainty=="inferred",let temporalDerivation {
            guard temporalDerivation.strength=="supportedContext" else{return nil}
        }else if certainty=="inferred" {
            guard let basis=captureYearDerivation,basis.policyVersion=="original-capture-year/1",
                  basis.printedWeekday.map({(1...7).contains($0)}) ?? true else{return nil}
            let captureDay=cal.startOfDay(for:basis.originalCapturedAt),captureYear=cal.component(.year,from:captureDay)
            let candidates=((captureYear-1)...(captureYear+1)).compactMap { y -> (Int,Int)? in
                let c=DateComponents(year:y,month:month,day:day)
                guard let date=cal.date(from:c),cal.dateComponents([.year,.month,.day],from:date)==c,
                      basis.printedWeekday.map({cal.component(.weekday,from:date)==$0}) ?? true,
                      let days=cal.dateComponents([.day],from:captureDay,to:date).day,abs(days)<=183 else{return nil}
                return (y,abs(days))
            }.sorted{$0.1==$1.1 ? $0.0<$1.0:$0.1<$1.1}
            guard let nearest=candidates.first,nearest.0==year,candidates.count==1 || candidates[1].1-nearest.1>14 else{return nil}
        }
        return resolved
    }
}
public struct AppointmentCaptureYearBasis: Codable, Equatable, Sendable {
    public let policyVersion: String
    public let source: EvidenceSource
    public let originalCapturedAt: Date
    public let printedWeekday: Int?
}
public struct AppointmentSemanticAnchor: Codable, Equatable, Sendable {
    public let source: EvidenceSource
    public let observationID: String
    public let quote: String
}
/// Compiled support metadata; confidence is not an unverified model probability.
public struct AppointmentSemanticField: Codable, Equatable, Sendable {
    public let field: String
    public let origin: String
    public let anchors: [AppointmentSemanticAnchor]
    public let confidence: Double
    public let extractorVersion: String
}
public struct AppointmentBookingIdentityEvidence:Codable,Equatable,Sendable {
    public let issuer:AppointmentSemanticAnchor
    public let reference:AppointmentSemanticAnchor
}
/// Exact observed relationship support, separate from current field support and
/// the host's opaque canonical ID. It never establishes ownership/authenticity.
public struct AppointmentBookingLinkEvidence:Codable,Equatable,Sendable {
    public static let contractVersion="appointment-evidence-components-v2"
    public let identities:[AppointmentBookingIdentityEvidence]
    public let taskSHA256:String
    public let version:String
    public init(identities:[AppointmentBookingIdentityEvidence],taskSHA256:String){self.identities=identities;self.taskSHA256=taskSHA256;version=Self.contractVersion}
}
public struct CanonicalAppointmentDraft: Sendable {
    public let recordID:String
    public let recordRevision:Int
    public let observation: AppointmentObservation
    public let sources: [AppointmentSource]
    public let support: [AppointmentSemanticField]
    public let documentOnlyWithoutDate: Bool
    public let bookingLinkEvidence:AppointmentBookingLinkEvidence?
    public init(recordID:String,recordRevision:Int,observation: AppointmentObservation,sources:[AppointmentSource],support:[AppointmentSemanticField],documentOnlyWithoutDate:Bool=false,bookingLinkEvidence:AppointmentBookingLinkEvidence?=nil) {
        self.recordID=recordID;self.recordRevision=recordRevision;self.observation=observation;self.sources=sources;self.support=support;self.documentOnlyWithoutDate=documentOnlyWithoutDate;self.bookingLinkEvidence=bookingLinkEvidence
    }
}
public struct AppointmentPreviousEvidence: Codable, Equatable, Sendable {
    public let revision: Int
    public let source: AppointmentSource
    public let additionalSources: [AppointmentSource]?
    public let observation: AppointmentObservation
    public let semanticSupport: [AppointmentSemanticField]?
    public var sources:[AppointmentSource]{[source]+(additionalSources ?? [])}
}
public enum PinOCRObservationID {
    public static func make(_ line:CardLine,offset:Int)throws->String {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let digest=SHA256.hash(data:try e.encode(line)).map{String(format:"%02x",$0)}.joined()
        return "pin-ocr-v1:\(offset):\(digest)"
    }
}

/// An explicit, confirmed native edit to one current appointment. It does not
/// alter OCR, original photos or the source revision, and is not a model draft.
public enum AppointmentOwnerCorrection: Codable, Equatable, Sendable {
    case title(String), provider(String), venue(String), performer(String), address(String)
    case schedule(AppointmentDateComponents)
    case eventTicket(Bool), cancelled(Bool)
}

public extension AppointmentObservation {
    /// Native edit metadata; never infer owner origin merely from a differing
    /// value or relabel the original source quote as the corrected value.
    var ownerCorrectionFields:Set<String> {
        Set((fieldFacts ?? []).filter{$0.extractorVersion=="pin-owner-correction/1"}.map{$0.field=="eventDate" ? "date":$0.field})
    }
}

/// Retained native-writer transition, not authority merely because it decodes.
/// A paired verifier must authenticate its origin and replay against the
/// independently reconstructed original source completion.
public struct AppointmentOwnerCorrectionTransition:Codable,Equatable,Sendable {
    public let operationID:UUID
    public let before:AppointmentItem
    public let correction:AppointmentOwnerCorrection
    public let after:AppointmentItem
}
/// Created by the current native store after replaying the entire writer
/// history. This process-local result cannot be decoded from a wire DTO.
/// Replay proves consistency, not external authentication of user confirmation;
/// a paired consumer still needs its trusted native-operation witness.
public struct AppointmentReplayedCorrectionHistory:Sendable {
    public let transitions:[AppointmentOwnerCorrectionTransition]
    public let current:AppointmentItem
    public let sources:[AppointmentSource]
}
