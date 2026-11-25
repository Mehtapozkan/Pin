import Foundation
import CryptoKit

/// A supported civil day can narrow relevance without inventing an instant.
/// With no trusted zone, every current civil offset (±14 hours) remains possible.
public struct AppointmentCalendarDay: Codable, Equatable, Sendable {
    public let year:Int
    public let month:Int
    public let day:Int
    public init?(year:Int,month:Int,day:Int) {
        var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(secondsFromGMT:0)!
        let p=DateComponents(year:year,month:month,day:day)
        guard (1...9999).contains(year),let d=c.date(from:p),c.dateComponents([.year,.month,.day],from:d)==p else{return nil}
        self.year=year;self.month=month;self.day=day
    }
    public var label:String {String(format:"%04d-%02d-%02d",year,month,day)}
    public func mayOverlap(_ window:AppointmentWindow)->Bool {
        guard case .interval(let range)=window else{return window == .all}
        guard let valid=Self(year:year,month:month,day:day) else{return true}
        var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(secondsFromGMT:0)!
        guard let start=c.date(from:DateComponents(year:valid.year,month:valid.month,day:valid.day)),let end=c.date(byAdding:.day,value:1,to:start) else{return true}
        return start.addingTimeInterval(-14*3600)<range.end && end.addingTimeInterval(14*3600)>range.start
    }
    static func parse(_ text:String)->Self? {
        guard let p=SemanticAppointmentCompiler.dateParts(text) else{return nil}
        return Self(year:p.0,month:p.1,day:p.2)
    }
}
public enum SemanticAppointmentTimePolicy: Sendable {
    case printedZoneOnly
    case deviceZoneAtRead(TimeZone)
}

/// The interpreter selects only existing OCR IDs. Source text, regions, source
/// identity, date arithmetic and publication authority remain native.
public struct AppointmentFieldObservation: Codable, Equatable, Sendable {
    public let id: String
    public let line: CardLine
    public init(id:String,line:CardLine) { self.id=id; self.line=line }
}
public struct AppointmentSourceRead: Sendable {
    public let source: AppointmentSource
    public let observations:[AppointmentFieldObservation]
    public init(source:AppointmentSource,observations:[AppointmentFieldObservation]) {self.source=source;self.observations=observations}
}
/// Stable, length-framed OCR text digest for matching an already recorded
/// decision to the exact local line order. Source identity and native support
/// checks remain separate requirements at publication time.
public enum AppointmentSourceDigest {
    public static func text(_ lines: [CardLine]) -> String {
        var bytes = Data()
        for line in lines {
            let value = Data(line.text.utf8)
            bytes.append(contentsOf: String(value.count).utf8)
            bytes.append(0x3a)
            bytes.append(value)
            bytes.append(0x0a)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
public struct SemanticAppointmentCandidate: Sendable {
    public let item:AppointmentItem
    public let facts:[FieldFact]
    fileprivate init(item:AppointmentItem,facts:[FieldFact]) {self.item=item;self.facts=facts}
}
public enum SemanticAppointmentRead: Sendable {
    case booking(SemanticAppointmentCandidate)
    case notBooking
    case unresolved(String)
}
/// Jev 1.13 returns a confidence for each bounded choice. A weak optional
/// field need not erase a strongly established booking, but its selected value
/// is never published. This policy does not calibrate Jev's scores or lower the
/// existing .80 floor. It is not wired to the ordinary app or replay route.
public struct JevAppointmentChoice: Codable, Equatable, Sendable {
    public let type: String
    public let choice: String
    public let confidence: Double
    public init(type: String = "choice", choice: String, confidence: Double) {
        self.type = type; self.choice = choice; self.confidence = confidence
    }
}
public enum JevAppointmentChoiceGate {
    public static let model = "jev-1.13.0"
    public static let minimumConfidence = 0.8
    private static let keys: Set<String> = ["document", "kind", "status", "title", "provider", "venue", "date", "time", "zone", "confirmation", "bookingID"]
    public static func project(model: String, answers: [String: JevAppointmentChoice]) -> [String: String]? {
        guard model == Self.model, Set(answers.keys) == keys,
              answers.values.allSatisfy({ $0.type == "choice" && $0.confidence.isFinite && (0...1).contains($0.confidence) }),
              let document = answers["document"], document.confidence >= minimumConfidence else { return nil }
        let blank = Dictionary(uniqueKeysWithValues: keys.map { ($0, "unknown") })
        if document.choice == "notBooking" { return blank.merging(["document": "notBooking"], uniquingKeysWith: { _, new in new }) }
        guard document.choice == "booking",
              answers["title"]!.confidence >= minimumConfidence,
              answers["confirmation"]!.confidence >= minimumConfidence else { return nil }
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            let answer = answers[key]!
            return (key, answer.confidence >= minimumConfidence ? answer.choice : "unknown")
        })
    }
}
public enum SemanticAppointmentCompiler {
    public static let version="pin-source-choices-v1"
    public static func compile(_ choices:[String:String],read:AppointmentSourceRead,current:PhotoMemory,timePolicy:SemanticAppointmentTimePolicy = .printedZoneOnly) -> SemanticAppointmentRead {
        let keys:Set<String>=["document","kind","status","title","provider","venue","date","time","zone","confirmation","bookingID"]
        guard AppointmentSource(current)==read.source,Set(choices.keys)==keys,
              !read.observations.isEmpty,read.observations.allSatisfy({current.textEvidence?.contains($0.line)==true}),Set(read.observations.map(\.id)).count==read.observations.count,
              read.observations.allSatisfy({ !$0.id.isEmpty && !["unknown","conflicting"].contains($0.id) && !$0.line.text.isEmpty && $0.line.confidence.isFinite && (0...1).contains($0.line.confidence) && ($0.line.region?.isValid ?? true) }) else {return .unresolved("The source or observation contract changed.")}
        let lines=read.observations.map(\.line),indexed=Dictionary(uniqueKeysWithValues:read.observations.map{($0.id,$0.line)})
        for key in ["title","provider","venue","date","time","zone","confirmation","bookingID"] {
            let value=choices[key]!
            guard value=="unknown" || key=="date" && value=="conflicting" || indexed[value] != nil else {return .unresolved("A selected field has no source observation.")}
        }
        guard ["booking","notBooking","unclear"].contains(choices["document"]!),["appointment","eventTicket","unknown"].contains(choices["kind"]!),["scheduled","cancelled","unknown"].contains(choices["status"]!) else {return .unresolved("An unsupported document meaning was returned.")}
        if AppointmentCardReader.isPinInterface(lines.map(\.text)) {return .notBooking}
        switch AppointmentCardReader.sourceDisposition(lines.map(\.text)) {
        case .nonHolder: return .notBooking
        case .contradictory: return .unresolved("The source has conflicting holder or issue evidence.")
        case .notExcluded: break
        }
        if choices["document"]=="notBooking" {return .notBooking}
        guard choices["document"]=="booking" else {return .unresolved("This source does not establish a booking.")}
        func line(_ field:String)->CardLine? {guard let l=indexed[choices[field]!],l.confidence>=0.5 else{return nil};return l}
        guard let title=line("title"),let confirmation=line("confirmation") else {return .unresolved("The booking purpose or confirmation is unresolved.")}
        var card=AppointmentObservation(sourceID:current.id,title:title.text,date:nil,timeZoneID:"",zoneFromCard:false,evidence:lines)
        card.semanticVersion=version;card.provider=line("provider")?.text;card.venue=line("venue")?.text
        card.printedDate=line("date")?.text;card.printedTime=line("time")?.text;card.printedTimeZone=line("zone")?.text
        card.bookingReference=line("bookingID")?.text
        card.eventTicket=choices["kind"]=="unknown" ? nil : choices["kind"]=="eventTicket"
        card.cancelled=choices["status"]=="unknown" ? nil : choices["status"]=="cancelled"
        var facts:[FieldFact]=[]
        let source=EvidenceSource(current)
        for (field,key) in [("purpose","title"),("provider","provider"),("venue","venue"),("printedDate","date"),("printedTime","time"),("printedTimeZone","zone"),("confirmation","confirmation"),("bookingReference","bookingID")] {
            if let l=line(key) {facts.append(FieldFact(field:field,value:l.text,origin:.observed,source:source,support:[l],extractorVersion:version))}
        }
        facts.append(FieldFact(field:"bookingKind",value:choices["kind"]!,origin:.inferred,source:source,support:[confirmation],extractorVersion:version))
        facts.append(FieldFact(field:"bookingStatus",value:choices["status"]!,origin:.inferred,source:source,support:[confirmation],extractorVersion:version))
        if let date=line("date"),date.confidence>=0.8 {
            card.calendarDay=AppointmentCalendarDay.parse(date.text)
            if card.calendarDay==nil,current.isScreenshot==true,let captured=current.photographedAt {
                var captureZone=line("zone").flatMap{printedIANAZone($0.text)}
                if captureZone==nil,case .deviceZoneAtRead(let assumed)=timePolicy {captureZone=assumed}
                let monthDay=matches("\\b[A-Za-z]+\\.? [0-9]{1,2}\\b",date.text)
                if matches("[0-9]{4}",date.text).isEmpty,monthDay.count==1,let zone=captureZone,let year=AppointmentCardReader.screenshotYear(for:monthDay[0],captured:captured,zone:zone),let day=AppointmentCalendarDay.parse(monthDay[0]+", \(year)"),weekdayAgrees(date.text,day:day) {
                    card.calendarDay=day;card.inferredYear=year;card.yearBasisDate=captured
                    facts.append(FieldFact(field:"inferredYear",value:String(year),origin:.inferred,source:source,support:[date],extractorVersion:version))
                }
            }
            if let day=card.calendarDay,!weekdayAgrees(date.text,day:day) {card.calendarDay=nil}
            if let day=card.calendarDay {facts.append(FieldFact(field:"calendarDay",value:day.label,origin:.inferred,source:source,support:[date],extractorVersion:version))}
        }
        let printedZone=line("zone").flatMap{printedIANAZone($0.text)}
        var effectiveZone=printedZone
        let selectedTimeText=[card.printedDate,card.printedTime].compactMap{$0}.joined(separator:" ")
        let unresolvedPrintedZone = !matches("\\b(?:PST|PDT|EST|EDT|CST|CDT|MST|MDT|CET|CEST|BST|IST|JST|AEST|AEDT|AKST|AKDT|HST|UTC|GMT)\\b",selectedTimeText).isEmpty
        if effectiveZone==nil,choices["zone"]=="unknown",!unresolvedPrintedZone,case .deviceZoneAtRead(let zone)=timePolicy {
            effectiveZone=zone
            facts.append(FieldFact(field:"assumedTimeZone",value:zone.identifier,origin:.inferred,source:source,support:[confirmation],extractorVersion:version))
        }
        if let zone=effectiveZone {card.timeZoneID=zone.identifier;card.zoneFromCard=printedZone != nil}
        if card.cancelled==true {card.reviewReason="This source says the booking was cancelled."}
        else if card.cancelled==nil || card.eventTicket==nil {card.reviewReason="The booking type or status is unresolved."}
        else if choices["date"]=="conflicting" {card.reviewReason="The source contains conflicting appointment dates."}
        else if let day=card.calendarDay,let date=line("date"),let time=line("time"),let zone=effectiveZone,let clock=timeParts(time.text) {
            if date.confidence<0.8 || time.confidence<0.8 {card.reviewReason="The date or time is not clear enough to use."}
            else {
                var c=Calendar(identifier:.gregorian);c.timeZone=zone
                let dc=DateComponents(year:day.year,month:day.month,day:day.day,hour:clock.0,minute:clock.1)
                if let value=c.date(from:dc),c.dateComponents([.year,.month,.day,.hour,.minute],from:value)==dc {
                    let midnight=c.startOfDay(for:value).addingTimeInterval(-1)
                    let matching=DateComponents(hour:clock.0,minute:clock.1)
                    let first=c.nextDate(after:midnight,matching:matching,matchingPolicy:.strict,repeatedTimePolicy:.first)
                    let last=c.nextDate(after:midnight,matching:matching,matchingPolicy:.strict,repeatedTimePolicy:.last)
                    if first != last {card.reviewReason="The local time occurs twice. Check the original."}
                    else {card.date=value}
                }else {card.reviewReason="The printed local date or time does not exist."}
            }
        }else {card.reviewReason="The printed date, time or time zone is unresolved."}
        if card.inferredYear != nil {card.reviewReason="The year is inferred from the screenshot date. Check the original before setting a reminder."}
        card.fieldFacts=facts
        return .booking(SemanticAppointmentCandidate(item:AppointmentItem(source:read.source,observation:card),facts:facts))
    }
    private static func matches(_ pattern:String,_ text:String)->[String] {
        guard let r=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else{return []}
        let n=text as NSString;return r.matches(in:text,range:NSRange(location:0,length:n.length)).map{n.substring(with:$0.range)}
    }
    static func dateParts(_ text:String)->(Int,Int,Int)? {
        let candidates=matches("\\b(?:[A-Za-z]+ [0-9]{1,2},? [0-9]{4}|[0-9]{1,2} [A-Za-z]+ [0-9]{4}|[0-9]{4}-[0-9]{2}-[0-9]{2})\\b",text)
        guard Set(candidates).count==1,let value=candidates.first else{return nil}
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(secondsFromGMT:0);f.isLenient=false
        for format in ["MMMM d, yyyy","MMMM d yyyy","MMM d, yyyy","MMM d yyyy","d MMMM yyyy","d MMM yyyy","yyyy-MM-dd"] {
            f.dateFormat=format
            if let date=f.date(from:value) {let p=Calendar(identifier:.gregorian).dateComponents(in:TimeZone(secondsFromGMT:0)!,from:date);return(p.year!,p.month!,p.day!)}
        }
        return nil
    }
    private static func printedIANAZone(_ text:String)->TimeZone? {
        let names=Set(matches("\\b[A-Za-z_]+/[A-Za-z_]+(?:/[A-Za-z_]+)?\\b",text))
        guard names.count==1,let name=names.first else{return nil}
        return TimeZone(identifier:name)
    }
    static func weekdayAgrees(_ text:String,day:AppointmentCalendarDay)->Bool {
        let names=matches("\\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Wed|Thu|Fri|Sat|Sun)\\b",text)
        guard !names.isEmpty else{return true}
        var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(secondsFromGMT:0)!
        guard names.count==1,let d=c.date(from:DateComponents(year:day.year,month:day.month,day:day.day)) else{return false}
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=c.timeZone;f.dateFormat="EEEE"
        return f.string(from:d).lowercased().hasPrefix(names[0].lowercased().prefix(3))
    }
    private static func timeParts(_ text:String)->(Int,Int)? {
        let values=matches("\\b(?:1[0-2]|0?[1-9])(?::[0-5][0-9])?\\s*(?:AM|PM)\\b",text)
        guard values.count==1 else{return nil}
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(secondsFromGMT:0);f.isLenient=false
        for format in ["h:mm a","h a","h:mma","ha"] {f.dateFormat=format;if let d=f.date(from:values[0]){let p=Calendar(identifier:.gregorian).dateComponents(in:TimeZone(secondsFromGMT:0)!,from:d);return(p.hour!,p.minute!)}}
        return nil
    }
}

/// This projection groups only exact, source-supported issuer/reference pairs.
/// It never treats a matching provider/time or a generic barcode as identity.
public struct AppointmentEvidenceGroup: Sendable {
    public let members:[AppointmentItem]
    public let conflicting:Bool
    fileprivate let identity:[String]
    public func isCurrent(items:[AppointmentItem],originals:[PhotoMemory])->Bool {
        guard let live=AppointmentEvidenceGroups.make(items:items,originals:originals).first(where:{$0.identity==identity}),live.conflicting==conflicting,live.members.count==members.count else{return false}
        return zip(members,live.members).allSatisfy{$0.hasSameEvidence(as:$1)}
    }
}
public enum AppointmentEvidenceGroups {
    public static func make(items:[AppointmentItem],originals:[PhotoMemory])->[AppointmentEvidenceGroup] {
        let current=AppointmentAnswerEngine.currentRecords(items,originals:originals,includingCancelled:true)
        func identity(_ item:AppointmentItem)->[String] {
            // Canonical identity belongs to the native writer and qualified
            // relationship receipt. A retained retrieval quote cannot merge it.
            if item.canonicalRecordID != nil{return ["source",item.id]}
            func supported(_ key:String,_ value:String?)->String? {
                guard let value,!value.isEmpty,let fact=item.observation.fieldFacts?.first(where:{$0.field==key && $0.value==value && $0.origin == .observed && $0.source==EvidenceSource(id:item.source.id,fingerprint:item.source.fingerprint,revision:item.source.revision)}),!fact.support.isEmpty,
                      fact.support.allSatisfy({line in item.observation.evidence.contains(line) && line.confidence>=0.5 && originals.first(where:{$0.id==item.sourceID})?.textEvidence?.contains(line)==true}) else{return nil}
                return value.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
            }
            if let issuer=supported("provider",item.observation.provider),let reference=supported("bookingReference",item.observation.bookingReference) {return ["booking",issuer,reference]}
            return ["source",item.id]
        }
        return Dictionary(grouping:current,by:identity).map { key,rows in
            let sorted=rows.sorted{$0.id<$1.id},first=sorted[0].observation
            let conflict=sorted.contains {row in
                let c=row.observation
                return c.title != first.title || c.calendarDay != first.calendarDay || c.date != first.date || c.printedDate != first.printedDate || c.printedTime != first.printedTime || c.timeZoneID != first.timeZoneID || c.cancelled != first.cancelled || c.eventTicket != first.eventTicket || c.reviewReason != first.reviewReason || c.venue != first.venue
            }
            return AppointmentEvidenceGroup(members:sorted,conflicting:conflict,identity:key)
        }.sorted { $0.members[0].id<$1.members[0].id }
    }
}
