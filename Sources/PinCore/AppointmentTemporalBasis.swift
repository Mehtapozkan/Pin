import Foundation

/// Native date provenance, independent of the derived SDK cache. These fields
/// preserve the original capture basis; they never supply an event timezone or
/// permission to create reminders. The writer validates current source metadata.
public struct AppointmentTemporalBasis:Codable,Equatable,Sendable {
    public let policyVersion:String
    public let rule:String
    public let source:EvidenceSource
    public let originalCapturedAt:Date
    public let captureOrigin:String
    public let contextTimeZoneID:String
    public let localeIdentifier:String
    public let dateAnchor:AppointmentSemanticAnchor
    public let printedWeekday:Int?
    public let relativeDayOffset:Int?
    public let components:Set<String>
    public let strength:String
    public init(policyVersion:String="source-temporal-context-v1",rule:String,source:EvidenceSource,originalCapturedAt:Date,captureOrigin:String,contextTimeZoneID:String,localeIdentifier:String="en_US_POSIX",dateAnchor:AppointmentSemanticAnchor,printedWeekday:Int?=nil,relativeDayOffset:Int?=nil,components:Set<String>,strength:String){
        self.policyVersion=policyVersion;self.rule=rule;self.source=source;self.originalCapturedAt=originalCapturedAt;self.captureOrigin=captureOrigin;self.contextTimeZoneID=contextTimeZoneID;self.localeIdentifier=localeIdentifier;self.dateAnchor=dateAnchor;self.printedWeekday=printedWeekday;self.relativeDayOffset=relativeDayOffset;self.components=components;self.strength=strength
    }
    private enum CodingKeys:String,CodingKey{case policyVersion,rule,source,originalCapturedAt,captureOrigin,contextTimeZoneID,localeIdentifier,dateAnchor,printedWeekday,relativeDayOffset,components,strength}
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(policyVersion,forKey:.policyVersion);try c.encode(rule,forKey:.rule);try c.encode(source,forKey:.source);try c.encode(originalCapturedAt,forKey:.originalCapturedAt);try c.encode(captureOrigin,forKey:.captureOrigin);try c.encode(contextTimeZoneID,forKey:.contextTimeZoneID);try c.encode(localeIdentifier,forKey:.localeIdentifier);try c.encode(dateAnchor,forKey:.dateAnchor);try c.encodeIfPresent(printedWeekday,forKey:.printedWeekday);try c.encodeIfPresent(relativeDayOffset,forKey:.relativeDayOffset);try c.encode(components.sorted(),forKey:.components);try c.encode(strength,forKey:.strength)
    }
    public var disclosure:String {
        strength=="assumedContext" ? "Date estimate assumes the wording was current when this photo was captured. Check the original; reminders remain unavailable.":"Date estimated from the original capture context. Check the original; reminders remain unavailable."
    }
    /// Mechanical proof validation only. Source access, original capture and
    /// exact quote/observation binding are checked at the owning native actor.
    public func validates(_ d:AppointmentDateComponents)->Bool {
        guard policyVersion=="source-temporal-context-v1",d.certainty=="inferred",d.captureYearDerivation==nil,
              ["originalPhoto","originalScreenshot"].contains(captureOrigin),["supportedContext","assumedContext"].contains(strength),
              originalCapturedAt.timeIntervalSinceReferenceDate.isFinite,!source.id.isEmpty,!source.fingerprint.isEmpty,source.revision>0,
              dateAnchor.source==source,!dateAnchor.observationID.isEmpty,!dateAnchor.quote.isEmpty,
              !localeIdentifier.isEmpty,localeIdentifier.utf8.count<=128,let zone=TimeZone(identifier:contextTimeZoneID),
              let y=d.year,let m=d.month,let day=d.day,printedWeekday.map({(1...7).contains($0)}) ?? true else{return false}
        var cal=Calendar(identifier:.gregorian);cal.timeZone=zone;cal.locale=Locale(identifier:localeIdentifier)
        guard (1...9999).contains(cal.component(.year,from:originalCapturedAt))else{return false}
        let value=DateComponents(year:y,month:m,day:day)
        guard let resolved=cal.date(from:value),cal.dateComponents([.year,.month,.day],from:resolved)==value,
              printedWeekday.map({cal.component(.weekday,from:resolved)==$0}) ?? true else{return false}
        switch rule {
        case "nearestPrintedMonthDayToOriginalCapture":
            guard components==["year"],relativeDayOffset==nil,strength=="supportedContext",d.printedDateText==dateAnchor.quote else{return false}
            let captureDay=cal.startOfDay(for:originalCapturedAt),captureYear=cal.component(.year,from:captureDay)
            let candidates=((captureYear-1)...(captureYear+1)).compactMap { year -> (Int,Int)? in
                let parts=DateComponents(year:year,month:m,day:day)
                guard let date=cal.date(from:parts),cal.dateComponents([.year,.month,.day],from:date)==parts,
                      printedWeekday.map({cal.component(.weekday,from:date)==$0}) ?? true,
                      let days=cal.dateComponents([.day],from:captureDay,to:date).day,abs(days)<=183 else{return nil}
                return(year,abs(days))
            }.sorted{$0.1==$1.1 ? $0.0<$1.0:$0.1<$1.1}
            guard let nearest=candidates.first else{return false}
            return nearest.0==y && (candidates.count==1 || candidates[1].1-nearest.1>14)
        case "explicitRelativeDayFromOriginalCapture":
            guard !components.isEmpty,components.isSubset(of:["year","month","day"]),components.contains("year"),
                  let offset=relativeDayOffset,(-31...31).contains(offset),
                  let expected=cal.date(byAdding:.day,value:offset,to:cal.startOfDay(for:originalCapturedAt)) else{return false}
            return cal.isDate(resolved,inSameDayAs:expected)
        default:return false
        }
    }
}
