import Foundation

/// Vision normalized image coordinates, with the origin at the bottom left.
public struct EvidenceRegion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x=x; self.y=y; self.width=width; self.height=height
    }
    public var isValid: Bool {
        [x,y,width,height].allSatisfy { $0.isFinite } && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001
    }
}

public struct CardLine: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Float
    public var region: EvidenceRegion?
    public init(_ text: String, confidence: Float = 1, region: EvidenceRegion? = nil) {
        self.text=text; self.confidence=confidence; self.region=region?.isValid == true ? region : nil
    }
}
public struct AppointmentObservation: Codable, Equatable, Sendable {
    /// Optional versioned source-value receipt/provenance; legacy records omit it.
    public var sourceValueProof: Data? = nil
    public var performer: String?
    public var components: AppointmentDateComponents?
    /// Preserves supported date-less document state without inventing a date.
    public var documentOnlyWithoutDate: Bool?
    public init(sourceID:String, title:String, date:Date?=nil, timeZoneID:String="UTC", zoneFromCard:Bool=false, address:String?=nil, instruction:String?=nil, evidence:[CardLine], reviewReason:String?=nil, printedDate:String?=nil, printedTime:String?=nil, fieldFacts:[FieldFact]?=nil, service:String?=nil, printedTimeRange:String?=nil, printedTimeZone:String?=nil, venue:String?=nil, provider:String?=nil, kind:String?=nil, cancelled:Bool?=nil, inferredYear:Int?=nil, yearBasisDate:Date?=nil, eventTicket:Bool?=nil, bookingReference:String?=nil, semanticVersion:String?=nil, calendarDay:AppointmentCalendarDay?=nil) {
        self.sourceID=sourceID;self.title=title;self.date=date;self.timeZoneID=timeZoneID;self.zoneFromCard=zoneFromCard;self.address=address;self.instruction=instruction;self.evidence=evidence;self.reviewReason=reviewReason;self.printedDate=printedDate;self.printedTime=printedTime;self.fieldFacts=fieldFacts;self.service=service;self.printedTimeRange=printedTimeRange;self.printedTimeZone=printedTimeZone;self.venue=venue;self.provider=provider;self.kind=kind;self.cancelled=cancelled;self.inferredYear=inferredYear;self.yearBasisDate=yearBasisDate;self.eventTicket=eventTicket;self.bookingReference=bookingReference;self.semanticVersion=semanticVersion;self.calendarDay=calendarDay
    }
    public var sourceID: String
    public var title: String
    public var date: Date?
    public var timeZoneID: String
    public var zoneFromCard: Bool
    public var address: String?
    public var instruction: String?
    public var evidence: [CardLine]
    public var reviewReason: String?
    public var printedDate: String?
    public var printedTime: String?
    public var fieldFacts: [FieldFact]?
    public var service: String?
    public var printedTimeRange: String?
    public var printedTimeZone: String?
    public var venue: String?
    public var provider: String?
    public var kind: String?
    public var cancelled: Bool?
    public var inferredYear: Int?
    public var yearBasisDate: Date?
    public var eventTicket: Bool?
    public var bookingReference: String?
    public var semanticVersion: String?
    public var calendarDay: AppointmentCalendarDay?
}
public enum AppointmentAttention: String, Codable, Sendable {
    case upcoming, tomorrow, today, past, review, hidden, unavailable
}
/// A source-level safety decision. This does not establish that an otherwise
/// eligible source is a booking; it only recognizes explicit contrary evidence.
public enum AppointmentSourceDisposition: String, Codable, Sendable {
    case notExcluded, nonHolder, contradictory
}
public enum AppointmentCardReader {
    public static let version = 10
    /// Pin's output is not independent evidence for a new appointment.
    /// Keep these photos searchable, but exclude their UI text from this reader.
    public static func isPinInterface(_ lines: [String]) -> Bool {
        let text=lines.joined(separator:" ").lowercased().replacingOccurrences(of:"’",with:"'")
        if text.contains("cards are read when pin is open") { return true }
        let museumMarkers=["museums in your photos","address from the museum's website","pin currently resolves names","why this place?","a visit is possible, not confirmed","visit date unknown"]
        if text.contains("pin currently resolves names") || museumMarkers.filter({ text.contains($0) }).count >= 2 { return true }
        let markers=["from photos you kept", "what are you trying", "forget this photo in pin", "pin needs one clear date", "pin couldn't confirm", "ask about your photos", "bookings with uncertain dates", "pin has read yet", "original card", "from this photo", "time zone uses this iphone's setting when read"]
        return markers.filter { text.contains($0) }.count >= 2
    }
    public static func isCandidate(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: " ").lowercased()
        guard !isPinInterface(lines), sourceDisposition(lines) == .notExcluded,
              !text.contains("invoice"), !text.contains("receipt") else { return false }
        let normalized=text.components(separatedBy:.whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator:" ")
        if isEventTicket(lines) { return true }
        return lines.contains { $0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() == "appointment" } ||
            ["next appointment", "your appointment", "appointment reminder", "appointment card", "next visit", "booking confirmed", "appointment confirmed", "your booking", "booking confirmation", "booked!", "appointment details", "appointment confirmation", "confirmed appointment", "scheduled appointment"].contains(where:normalized.contains)
    }

    /// Ticket admission needs an event/pass context and a printed date/time.
    /// A ticket number, receipt, advertisement or transit fine alone is not a booking.
    public static func isEventTicket(_ lines: [String]) -> Bool {
        let text=lines.joined(separator: " ").lowercased()
        let labels=Set(lines.map { $0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() })
        let context=text.contains("event ticket") || text.contains("admission ticket") ||
            (labels.contains("ticket") && labels.contains("guest") && labels.contains("location"))
        return context && !isPinInterface(lines) && sourceDisposition(lines) == .notExcluded && !text.contains("invoice") && !text.contains("receipt") &&
            !matches("\\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\.?\\s+[0-9]{1,2}\\b",in:text).isEmpty &&
            !matches("\\b(?:1[0-2]|0?[1-9])(?::[0-5][0-9])?\\s*(?:AM|PM)\\b",in:text).isEmpty
    }

    /// An explicit unissued, non-holder or editorial notice cannot establish a
    /// booking. Conflicting positive and negative notices require review; a
    /// model must not choose whichever line is convenient. This is a bounded
    /// safety gate, not a general document-understanding classifier.
    public static func sourceDisposition(_ lines: [String]) -> AppointmentSourceDisposition {
        let text=lines.joined(separator: " ").lowercased()
        let explicitNotBooking = !matches("\\bnot (?:a |the |your |holder )?booking\\b",in:text).isEmpty
        let editorial = !matches("\\b(?:article|journal|news story)\\b",in:text).isEmpty
        let quoted = lines.contains { line in
            !matches("^\\s*(?:quote|example|sample)\\s*:",in:line).isEmpty
        }
        let negativePatterns = [
            "\\bno (?:booking reference|tickets?|seats?|admissions?|reservations?|appointments?)(?: or (?:tickets?|seats?))? (?:(?:has|have|had) been|(?:was|were)) (?:issued|reserved|confirmed|booked)\\b",
            "\\bnot (?:a |an )?confirmed (?:admission|ticket|booking|reservation|appointment)(?: or (?:ticket|pass))?\\b",
            "\\b(?:recipient|reader|viewer|you)\\b.{0,60}\\bnot (?:the |a )?(?:ticket|pass|booking|reservation) holder\\b",
            "\\bnot (?:your|the holder's|the reader's) (?:booking|reservation|ticket|appointment|admission)\\b",
            #"\bno (?:personal |individual |holder(?:'s)? )?(?:tickets?|pass(?:es)?|reservations?|bookings?|appointments?)(?: or (?:tickets?|pass(?:es)?|reservations?|bookings?|appointments?))? (?:is|are) (?:shown|listed|included)\b"#
        ]
        let explicitNoEntitlement = lines.contains { raw in
            let line = raw.lowercased().replacingOccurrences(of: "’", with: "'")
            // Historic absence does not negate a subsequently issued pass.
            guard matches("^\\s*(?:previously|formerly|originally|before)\\b",in:line).isEmpty else { return false }
            return negativePatterns.contains { !matches($0,in:line).isEmpty }
        }
        guard explicitNotBooking || (editorial && quoted) || explicitNoEntitlement else { return .notExcluded }
        let positivePatterns = [
            "\\b(?:tickets?|passes?|admission|appointment|booking|reservation) (?:has been |is |was )?(?:issued|confirmed|reserved|booked) (?:to|for) (?:the )?(?:holder|you|recipient)\\b",
            "\\b(?:your|the holder's) (?:ticket|pass|appointment|booking|reservation) (?:is |was |has been )?(?:issued|confirmed|reserved|booked)\\b"
        ]
        let explicitHolderIssue = lines.contains { raw in
            let line = raw.lowercased().replacingOccurrences(of: "’", with: "'")
            // A quoted/sample statement describes its example, not the holder.
            guard matches("^\\s*(?:quote|example|sample)\\s*:",in:line).isEmpty else { return false }
            return positivePatterns.contains { !matches($0,in:line).isEmpty }
        }
        return explicitHolderIssue ? .contradictory : .nonHolder
    }
    public static func isNonHolderNarrative(_ lines: [String]) -> Bool {
        sourceDisposition(lines) == .nonHolder
    }

    /// Choose the nearest plausible year, including a December/January boundary.
    /// Never search distant years merely to make a printed weekday fit.
    static func screenshotYear(for printed: String, captured: Date, zone: TimeZone) -> Int? {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=zone
        let year=calendar.component(.year,from:captured)
        let clean=printed.replacingOccurrences(of:".",with:"").replacingOccurrences(of:",",with:"")
        let parser=DateFormatter();parser.locale=Locale(identifier:"en_US_POSIX");parser.timeZone=zone;parser.isLenient=false
        var candidates:[(Int,TimeInterval)]=[]
        for candidate in (year-1)...(year+1) {
            for format in ["MMMM d yyyy", "MMM d yyyy"] {
                parser.dateFormat=format
                if let date=parser.date(from:"\(clean) \(candidate)") {
                    let distance=abs(calendar.startOfDay(for:date).timeIntervalSince(calendar.startOfDay(for:captured)))
                    if distance <= 183 * 86400 { candidates.append((candidate,distance)) }
                    break
                }
            }
        }
        candidates.sort { $0.1 < $1.1 }
        guard let first=candidates.first, candidates.count < 2 || abs(candidates[1].1-first.1) > 86400 else { return nil }
        return first.0
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    public static func extract(_ lines: [CardLine], sourceID: String, deviceTimeZone: TimeZone, photographedAt: Date? = nil, isScreenshot: Bool? = nil) -> AppointmentObservation {
        let text = lines.map(\.text).joined(separator: "\n")
        let zones = [("Pacific time", "America/Los_Angeles"), ("Eastern time", "America/New_York"), ("Central time", "America/Chicago"), ("Mountain time", "America/Denver")]
        let namedZones = zones.filter { text.localizedCaseInsensitiveContains($0.0) }.map(\.1)
        let ianaZones = lines.compactMap { line -> String? in
            let token=line.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard line.confidence >= 0.8,token.contains("/"),let zone=TimeZone(identifier:token) else { return nil }
            return zone.identifier
        }
        let observedZones=Set(namedZones+ianaZones)
        let zoneFromCard = observedZones.count == 1
        let zone = zoneFromCard ? TimeZone(identifier:observedZones.first!)! : deviceTimeZone
        var result = AppointmentObservation(sourceID: sourceID,
            title: lines.first(where: { $0.text.localizedCaseInsensitiveContains("dental") })?.text ?? "Appointment",
            date: nil, timeZoneID: zone.identifier, zoneFromCard: zoneFromCard,
            evidence: lines)
        // Independent observations survive an unresolved date. Metadata inference stays explicit.
        func labelled(_ names:[String]) -> String? {
            for (index,line) in lines.enumerated() where line.confidence >= 0.5 {
                for name in names {
                    let trimmed=line.text.trimmingCharacters(in:.whitespacesAndNewlines)
                    if trimmed.lowercased().hasPrefix(name.lowercased() + ":") {
                        let value=String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in:.whitespacesAndNewlines)
                        if !value.isEmpty { return value }
                        if index + 1 < lines.count, lines[index + 1].confidence >= 0.5 {
                            let next=lines[index + 1].text.trimmingCharacters(in:.whitespacesAndNewlines)
                            if !next.isEmpty, !next.contains(":") { return next }
                        }
                    }
                }
            }
            return nil
        }
        func usableLocation(_ value:String?) -> String? {
            guard let value else { return nil }
            let token=value.trimmingCharacters(in:.whitespacesAndNewlines)
            return token.contains("/") && TimeZone(identifier:token) != nil ? nil : value
        }
        func withoutBullet(_ value:String) -> String {
            value.replacingOccurrences(of:"^[\\s•●]+",with:"",options:.regularExpression)
                .trimmingCharacters(in:.whitespacesAndNewlines)
        }
        let providerLines=lines.filter {
            !$0.text.localizedCaseInsensitiveContains("location:") && $0.text.range(of:"dental|vision|optometr|ophthalm|clinic|medical cent",options:[.regularExpression,.caseInsensitive]) != nil
        }
        // A branded logo often precedes the more useful branch name on a
        // booking screenshot. Prefer the distinct branch line when present.
        result.provider = labelled(["Provider","Practice","Clinic"]) ??
            providerLines.first(where: { let value=withoutBullet($0.text); return value.contains(" ") && !value.contains("/") })
                .map { withoutBullet($0.text) } ?? providerLines.first?.text
        result.venue = usableLocation(labelled(["Appointment location","Clinic location","Location","Venue","Where"]))
        if result.venue == nil, let provider=result.provider,
           let stem=provider.split(separator:" ").first?.lowercased() {
            // A distinct provider/branch line is evidence of the named venue,
            // not a street address or a location inferred from photo GPS.
            result.venue=lines.first { $0.confidence >= 0.5 && withoutBullet($0.text).contains("/") && withoutBullet($0.text).lowercased().hasPrefix(stem) }
                .map { withoutBullet($0.text) }.flatMap(usableLocation)
        }
        // A separate map may contain many businesses. Associate only the printed
        // name immediately above one unambiguous street address, never the first
        // name after a Location heading or a nearby map label.
        let streets=lines.filter { $0.confidence >= 0.8 && !matches("^\\s*[0-9]+\\s+.+\\b(?:Street|St|Road|Rd|Avenue|Ave|Lane|Ln)\\b",in:$0.text).isEmpty }
        var spatialAddress: CardLine?
        if result.venue == nil, streets.count == 1, let address=streets.first, let a=address.region, a.isValid {
            let adjacent=lines.filter { line in
                guard line.confidence >= 0.8,let b=line.region,b.isValid else { return false }
                let gap=b.y-(a.y+a.height)
                let overlap=max(0,min(b.x+b.width,a.x+a.width)-max(b.x,a.x))
                return gap >= 0 && gap <= max(a.height,b.height)*2 && abs(b.x-a.x) <= 0.03 && overlap >= min(b.width,a.width)*0.5 && matches("[0-9]|https?://|cancel|reschedule|location|book again",in:line.text).isEmpty && usableLocation(line.text) != nil
            }.sorted { $0.region!.y < $1.region!.y }
            if let name=adjacent.first {
                result.venue=name.text; spatialAddress=address
                // A business at a venue is not automatically the provider. The
                // business name must also occur independently in the header.
                let stem=name.text.components(separatedBy:" - ").first ?? name.text
                func normalized(_ value:String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
                let header=normalized(lines.filter { $0.confidence >= 0.5 && ($0.region?.y ?? 0) > 0.75 }.map(\.text).joined())
                if result.provider == nil, normalized(stem).count >= 5, header.contains(normalized(stem)) { result.provider=stem }
            }
        }
        let printedVisit=lines.first { $0.confidence >= 0.8 && !matches("^(?:Medical|Dental|Eye|Vision|Optometry|Consultation|Follow-up) Visit\\b",in:withoutBullet($0.text)).isEmpty }
            .flatMap { matches("^(?:Medical|Dental|Eye|Vision|Optometry|Consultation|Follow-up) Visit\\b",in:withoutBullet($0.text)).first }
        result.service=labelled(["Service","Treatment"]) ?? lines.first { $0.confidence >= 0.8 && $0.text.range(of:"^[A-Za-z ]+ Package$",options:[.regularExpression,.caseInsensitive]) != nil }?.text ?? printedVisit
        result.title = result.service ?? result.provider ?? "Appointment booking"
        result.kind = text.range(of: "\\beye\\b|optometr|ophthalm", options: [.regularExpression,.caseInsensitive]) != nil ? "Eye appointment" : (text.localizedCaseInsensitiveContains("dental") ? "Dental appointment" : nil)
        if result.kind == nil, result.provider?.localizedCaseInsensitiveContains("vision") == true {
            result.kind = "Likely an eye appointment"
        }
        result.address = labelled(["Address"]) ?? (streets.count == 1 ? streets.first?.text : nil)
        if let address=spatialAddress,let a=address.region {
            let cities=lines.filter { line in
                guard line.confidence >= 0.8,let b=line.region,b.isValid else { return false }
                let gap=a.y-(b.y+b.height)
                return gap >= 0 && gap <= max(a.height,b.height)*2 && abs(a.x-b.x) <= 0.03 && !matches("\\b[A-Z]{2}\\s+[0-9]{5}(?:-[0-9]{4})?\\b",in:line.text).isEmpty
            }
            if cities.count == 1 { result.address=address.text + ", " + cities[0].text }
        }
        result.instruction = lines.first { $0.text.localizedCaseInsensitiveContains("arrive") }?.text
        result.cancelled = text.localizedCaseInsensitiveContains("cancelled") || text.localizedCaseInsensitiveContains("canceled")
        let ticket=isEventTicket(lines.map(\.text))
        result.eventTicket=ticket
        var dateLines=lines
        if ticket {
            func valueBelow(_ heading:String) -> String? {
                guard let label=lines.first(where: { $0.confidence >= 0.8 && $0.text.lowercased() == heading }),let a=label.region else { return nil }
                return lines.filter { line in
                    guard line.confidence >= 0.8,let b=line.region else { return false }
                    let gap=a.y-(b.y+b.height)
                    return gap >= 0 && gap <= max(a.height,b.height)*2 && abs(a.x-b.x) <= 0.04
                }.sorted { $0.region!.y > $1.region!.y }.first?.text
            }
            func valueFollowing(_ heading:String) -> String? {
                guard let index=lines.firstIndex(where: { $0.confidence >= 0.8 && $0.text.lowercased() == heading }),
                      index + 1 < lines.count else { return nil }
                let label=lines[index], next=lines[index + 1]
                guard next.confidence >= 0.8, let a=label.region, let b=next.region,
                      abs(a.x-b.x) <= 0.08,
                      abs(a.y-b.y) <= max(a.height,b.height)*2.5,
                      matches("\\b(?:Guest|Ticket|Date|Time|Location)\\b|[0-9]{1,2}:?[0-9]{0,2}\\s*(?:AM|PM)",in:next.text).isEmpty else { return nil }
                // Camera photos of a pass can rotate OCR geometry even when
                // the two printed lines remain adjacent in reading order.
                return next.text
            }
            result.venue=usableLocation(labelled(["Location","Venue"]) ?? valueBelow("location") ?? valueFollowing("location"))
            let titleLine=lines.first { $0.confidence >= 0.8 && $0.text.hasPrefix("#") && ($0.region?.height ?? 0) >= 0.02 }
            result.title=labelled(["Event","Event name"]) ?? titleLine?.text ?? "Event ticket"
            result.kind=nil
            // Wallet's large date/time fields above its event title are the pass
            // schedule. Small embedded poster art is separate, noisy OCR evidence.
            // Only use this layout when BOTH primary fields are independently clear.
            if let title=titleLine?.region {
                let header=lines.filter { line in
                    guard let box=line.region else { return false }
                    return line.confidence >= 0.8 && box.y >= title.y+title.height && box.height >= title.height*0.45
                }
                let dates=header.filter { !matches("^[A-Za-z]+\\.?\\s+[0-9]{1,2},?\\s+[0-9]{4}$",in:$0.text).isEmpty }
                let times=header.filter { !matches("^(?:1[0-2]|0?[1-9])(?::[0-5][0-9])?\\s*(?:AM|PM)$",in:$0.text).isEmpty }
                if dates.count == 1 && times.count == 1 { dateLines=dates+times }
            }
        }
        let dateTextSource=dateLines.map(\.text).joined(separator:"\n")
        let monthPattern = "(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)"
        let visibleDates = matches("\\b" + monthPattern + "\\.?\\s+[0-9]{1,2}(?:,?\\s+[0-9]{4})?\\b", in: dateTextSource)
        let visibleTimes = matches("\\b(?:1[0-2]|0?[1-9])(?::[0-5][0-9])?\\s*(?:AM|PM)\\b", in: dateTextSource)
        let printedDates=matches("(?:\\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Tues|Wed|Thu|Thur|Thurs|Fri|Sat|Sun),?\\s+)?\\b" + monthPattern + "\\.?\\s+[0-9]{1,2}(?:,?\\s+[0-9]{4})?\\b",in:dateTextSource)
        result.printedDate = printedDates.isEmpty ? nil : printedDates.joined(separator:" / ")
        let timePattern="\\b(?:1[0-2]|0?[1-9])(?::[0-5][0-9])?\\s*(?:AM|PM)\\b"
        let ranges=matches(timePattern + "\\s*[-–—]\\s*" + timePattern,in:dateTextSource)
        if ranges.count == 1 && visibleTimes.count == 2 { result.printedTimeRange=ranges[0] }
        let printedZones=matches("\\b(?:PST|PDT|EST|EDT|CST|CDT|MST|MDT|CET|CEST|BST|IST|JST|AEST|AEDT|AKST|AKDT|HST)\\b",in:text)
        if printedZones.count == 1 { result.printedTimeZone=printedZones[0] }
        else if ianaZones.count == 1 { result.printedTimeZone=ianaZones[0] }
        result.printedTime = visibleTimes.isEmpty ? nil : visibleTimes.joined(separator: " / ")
        guard isCandidate(lines.map(\.text)) else {
            result.reviewReason = "This photo is not clearly an appointment card."; return result
        }
        guard result.cancelled != true else { result.reviewReason="This card says the appointment was cancelled."; return result }
        var resolvedDates=visibleDates
        if visibleDates.count == 1 && matches("[0-9]{4}\\b",in:visibleDates[0]).isEmpty {
            guard isScreenshot == true, let captured=photographedAt,
                  dateLines.filter({ $0.text.contains(visibleDates[0]) }).allSatisfy({ $0.confidence >= 0.8 }),
                  let year=screenshotYear(for:visibleDates[0],captured:captured,zone:zone) else {
                result.reviewReason="The year isn’t printed, and this photo has no reliable screenshot date nearby to infer it from."; return result
            }
            // Check the observed weekday before retaining a year, even for windows.
            let weekday=matches("\\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Tues|Wed|Thu|Thur|Thurs|Fri|Sat|Sun)\\b",in:dateTextSource)
            let parser=DateFormatter();parser.locale=Locale(identifier:"en_US_POSIX");parser.timeZone=zone;parser.isLenient=false
            parser.dateFormat="MMM d yyyy"
            let clean=visibleDates[0].replacingOccurrences(of:".",with:"").replacingOccurrences(of:",",with:"")
            var date=parser.date(from:"\(clean) \(year)")
            if date == nil { parser.dateFormat="MMMM d yyyy";date=parser.date(from:"\(clean) \(year)") }
            parser.dateFormat="EEEE"
            guard let date, weekday.isEmpty || (weekday.count == 1 && parser.string(from:date).lowercased().hasPrefix(weekday[0].lowercased().prefix(3))) else {
                result.reviewReason="The printed weekday conflicts with the year suggested by the screenshot date."; return result
            }
            result.inferredYear=year;result.yearBasisDate=captured
            resolvedDates=[visibleDates[0] + ", \(year)"]
        }
        // Day relevance survives a service window or unresolved time zone. This
        // is not an exact event instant and does not authorize a reminder.
        if resolvedDates.count == 1, dateLines.filter({ $0.text.contains(visibleDates[0]) }).allSatisfy({ $0.confidence >= 0.8 }) {
            result.calendarDay=AppointmentCalendarDay.parse(resolvedDates[0])
            if let day=result.calendarDay,!SemanticAppointmentCompiler.weekdayAgrees(dateTextSource,day:day) {result.calendarDay=nil}
        }
        if result.printedTimeRange != nil {
            result.reviewReason="The confirmation gives a service window. Check the original before making a reminder."; return result
        }
        guard observedZones.count <= 1 else { result.reviewReason = "This card names more than one time zone."; return result }
        if observedZones.isEmpty && (text.localizedCaseInsensitiveContains(" time") || text.localizedCaseInsensitiveContains("GMT") || text.localizedCaseInsensitiveContains("UTC") || !matches("\\b(?:PST|PDT|EST|EDT|CST|CDT|MST|MDT|CET|CEST|BST|IST|JST|AEST|AEDT|AKST|AKDT|HST)\\b", in: text).isEmpty) {
            result.reviewReason = "Pin couldn't confirm the time zone on this card."; return result
        }
        guard !text.localizedCaseInsensitiveContains("cancelled") && !text.localizedCaseInsensitiveContains("canceled") else {
            result.reviewReason = "This card says the appointment was cancelled."; return result
        }
        let dates = resolvedDates.filter { !matches("[0-9]{4}\\b", in: $0).isEmpty }
        let times = visibleTimes
        guard dates.count == 1, times.count == 1 else {
            result.reviewReason = visibleDates.count == 1 && dates.isEmpty ? "I couldn’t read a year. I can’t confirm which day this is for." : "I can read these details, but can’t confirm one appointment date and time."; return result
        }
        let relevant = lines.filter { visibleDates.contains(where:$0.text.contains) || $0.text.localizedCaseInsensitiveContains(times[0]) }
        guard relevant.allSatisfy({ $0.confidence >= 0.8 }) else {
            result.reviewReason = "The date or time is not clear enough to use."; return result
        }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = zone
        parser.dateFormat = "MMMM d, yyyy h:mm a"; parser.isLenient = false
        let dateText = dates[0].replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")
        let parts = dateText.split(separator: " ")
        guard parts.count == 3 else { result.reviewReason = "This date is unclear."; return result }
        var timeText = times[0].uppercased().replacingOccurrences(of: " ", with: "")
        if !timeText.contains(":") { timeText = timeText.replacingOccurrences(of: "AM", with: ":00AM").replacingOccurrences(of: "PM", with: ":00PM") }
        timeText = timeText.replacingOccurrences(of: "AM", with: " AM").replacingOccurrences(of: "PM", with: " PM")
        var parsed: Date?
        for format in ["MMMM d, yyyy h:mm a", "MMM d, yyyy h:mm a"] {
            parser.dateFormat = format
            if let date = parser.date(from: "\(parts[0]) \(parts[1]), \(parts[2]) \(timeText)") { parsed = date; break }
        }
        guard let date = parsed else { result.reviewReason = "This date or time is not valid."; return result }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = calendar.startOfDay(for: date)
        let hm = calendar.dateComponents([.hour, .minute], from: date)
        let first = calendar.nextDate(after: day.addingTimeInterval(-1), matching: hm, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: day.addingTimeInterval(-1), matching: hm, matchingPolicy: .strict, repeatedTimePolicy: .last)
        guard first == last else {
            result.reviewReason = "This time occurs twice when the clocks change. Please check the original."; return result
        }
        let weekdays = matches("\\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Tues|Wed|Thu|Thur|Thurs|Fri|Sat|Sun)\\b", in: dateTextSource)
        if !weekdays.isEmpty {
            parser.dateFormat = "EEEE"
            guard weekdays.count == 1, parser.string(from: date).lowercased().hasPrefix(String(weekdays[0].lowercased().prefix(3))) else {
                result.calendarDay=nil; result.reviewReason = "The weekday and date on this card disagree."; return result
            }
        }
        result.date = date
        if result.inferredYear != nil { result.reviewReason="The year is inferred from the screenshot date. Check the original before setting a reminder." }
        return result
    }
    /// Bind only observed fields with actual local support. Reading a field does
    /// not resolve a date, authorize a reminder, or validate an appointment.
    public static func facts(for card:AppointmentObservation,source:EvidenceSource) -> [FieldFact] {
        guard source.id == card.sourceID else { return [] }
        func normalized(_ text:String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let values:[(String,String?)]=[("provider",card.provider),("venue",card.venue),("address",card.address),("service",card.service),("printedDate",card.printedDate),("printedTime",card.printedTimeRange ?? card.printedTime),("printedTimeZone",card.printedTimeZone),("instruction",card.instruction),("bookingReference",card.bookingReference)]
        var facts=values.compactMap { field,value -> FieldFact? in
            guard let value,!value.isEmpty else { return nil }
            let key=normalized(value)
            let support=card.evidence.filter { line in
                let text=normalized(line.text)
                return line.confidence >= 0.5 && !text.isEmpty && (text.contains(key) || key.contains(text))
            }
            guard !support.isEmpty else { return nil }
            return FieldFact(field:field,value:value,origin:.observed,source:source,support:support,extractorVersion:card.semanticVersion ?? "appointment-v\(version)")
        }
        if let kind=card.kind {
            let support=card.evidence.filter { $0.confidence >= 0.5 && $0.text.range(of:"dental|vision|optometr|ophthalm|\\beye\\b",options:[.regularExpression,.caseInsensitive]) != nil }
            if !support.isEmpty { facts.append(FieldFact(field:"kind",value:kind,origin:.inferred,source:source,support:support,extractorVersion:card.semanticVersion ?? "appointment-v\(version)")) }
        }
        if let day=card.calendarDay,let printed=card.printedDate {
            let support=card.evidence.filter { $0.confidence>=0.8 && ($0.text.contains(printed) || printed.contains($0.text)) }
            if !support.isEmpty {facts.append(FieldFact(field:"calendarDay",value:day.label,origin:.inferred,source:source,support:support,extractorVersion:card.semanticVersion ?? "appointment-v\(version)"))}
        }
        if let year=card.inferredYear, card.yearBasisDate != nil {
            let support=card.evidence.filter { line in card.printedDate?.contains(line.text) == true || (card.printedDate.map { line.text.contains($0) } ?? false) }
            facts.append(FieldFact(field:"inferredYear",value:String(year),origin:.inferred,source:source,support:support,extractorVersion:card.semanticVersion ?? "appointment-v\(version)"))
        }
        if card.eventTicket == true, card.title != "Event ticket" {
            let support=card.evidence.filter { $0.text == card.title || $0.text.hasSuffix(": " + card.title) }
            if !support.isEmpty { facts.append(FieldFact(field:"event",value:card.title,origin:.observed,source:source,support:support,extractorVersion:card.semanticVersion ?? "appointment-v\(version)")) }
        }
        return facts
    }

    /// Lab policy: in-app attention from 9am the previous local day; at midnight
    /// the label becomes Today without hiding the card. Not notification delivery.
    public static func attention(_ card: AppointmentObservation, now: Date, accessible: Bool = true, hidden: Bool = false) -> AppointmentAttention {
        guard accessible else { return .unavailable }
        guard !hidden else { return .hidden }
        guard let date = card.date, card.reviewReason == nil else { return .review }
        guard now < date else { return .past }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: card.timeZoneID)!
        let day = calendar.startOfDay(for: date)
        let prior = calendar.date(byAdding: .day, value: -1, to: day)!
        let priorCue = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: prior)!
        if now >= priorCue { return calendar.isDate(now, inSameDayAs: date) ? .today : .tomorrow }
        return .upcoming
    }
}

/// Narrow appointment-question route. Ordinary photo search remains unchanged.
public enum AppointmentQuestion {
    public enum Intent: Equatable { case today, bookings }
    public enum ExplicitRequest: Equatable {
        case appointments(period: AppointmentPeriod, selection: AppointmentSelection)
        case unsupported
    }
    /// Exact, unambiguous ordinal location follow-ups can be resolved against
    /// the last source-bound answer without interpreting another photo query.
    /// Unhandled wording remains for the semantic interpreter or an honest hold.
    public static func locationFollowUp(_ text: String) -> Int? {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard words.count == 5, words[0...2].elementsEqual(["where", "is", "the"]),
              ["one", "appointment", "ticket"].contains(words[4]) else { return nil }
        return ["first": 1, "second": 2, "third": 3][words[3]]
    }
    /// A bounded native route for an explicit appointment question. Preserve
    /// every word: an unhandled qualifier must not turn into an all-bookings
    /// answer or an unrelated photo search. General meaning remains the
    /// semantic interpreter's job.
    public static func explicitRequest(_ text: String) -> ExplicitRequest? {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let subjects: [([String], AppointmentSelection)] = [
            (["what", "appointments", "are", "there"], .any),
            (["what", "appointments", "do", "i", "have"], .any),
            (["what", "are", "my", "appointments"], .any),
            (["which", "appointments", "do", "i", "have"], .any),
            (["do", "i", "have", "any", "appointments"], .any),
            (["my", "appointments"], .any), (["appointments"], .any),
            (["what", "tickets", "are", "there"], .eventTickets),
            (["what", "tickets", "do", "i", "have"], .eventTickets),
            (["what", "are", "my", "tickets"], .eventTickets),
            (["my", "tickets"], .eventTickets), (["tickets"], .eventTickets)
        ]
        guard let (subject, selection) = subjects.first(where: { words.starts(with: $0.0) }) else { return nil }
        var remaining = Array(words.dropFirst(subject.count))
        if remaining.first == "for" || remaining.first == "in" || remaining.first == "on" { remaining.removeFirst() }
        let period: AppointmentPeriod
        switch remaining {
        case []: period = .all
        case ["today"]: period = .today
        case ["tomorrow"]: period = .tomorrow
        case ["this", "week"]: period = .thisWeek
        case ["next", "week"]: period = .nextWeek
        case ["the", "next", "seven", "days"], ["the", "next", "7", "days"]: period = .nextSevenDays
        default: return .unsupported
        }
        return .appointments(period: period, selection: selection)
    }
    /// If a semantic provider proposes an executable operation for a bounded
    /// explicit request, it must agree with the native window and kind. A
    /// provider hold is still allowed; no generic-photo result is substituted.
    public static func mayPresent(_ plan: MemoryQueryPlan, for request: ExplicitRequest, now: Date, calendar: Calendar) -> Bool {
        switch plan {
        case .needsContext, .needsDate, .unsupported, .unclear: return true
        case .appointments(let window, let selection):
            guard case .appointments(let period, let expectedSelection) = request else { return false }
            return window == AppointmentWindow.resolve(period, now: now, calendar: calendar) && selection == expectedSelection
        default: return false
        }
    }
    public static func intent(_ text: String) -> Intent? {
        let words=text.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let set=Set(words)
        if set.contains("today") && (!set.isDisjoint(with:["anything","something","appointment","appointments","schedule","plans"]) || words.joined(separator:" ").contains("what do i have") || words.joined(separator:" ").contains("what s on")) { return .today }
        if ["appointment","appointments","my appointments","bookings","my bookings","tickets","my tickets","events","my events"].contains(words.joined(separator:" ")) { return .bookings }
        return nil
    }
    public static func isToday(_ card: AppointmentObservation, now: Date, calendar: Calendar) -> Bool {
        guard card.cancelled != true, card.reviewReason == nil, let date=card.date else { return false }
        return calendar.isDate(date,inSameDayAs:now)
    }
    public static func unresolved(_ card: AppointmentObservation) -> Bool { card.cancelled != true && card.reviewReason != nil }
}

public extension AppointmentObservation {
    /// Render supported civil components even when no timezone can bind an instant.
    /// Printed fragments remain untouched; inferred/conflicting dates keep their disclosure.
    var supportedCivilDateText:String? {
        guard let d=components,d.isValid,d.certainty=="explicit",d.temporalDerivation==nil,
              d.captureYearDerivation==nil,let y=d.year,let m=d.month,let day=d.day else{return nil}
        var text=String(format:"%04d-%02d-%02d",y,m,day)
        if let h=d.hour,let minute=d.minute {text += String(format:" · %02d:%02d",h,minute)}
        return text
    }
    /// The legacy persisted warning conflates a missing zone with missing civil fields.
    /// Refine its presentation only; retain all other uncertainty and stored bytes.
    var presentationReviewReason:String? {
        if reviewReason=="Some date or time details are missing. Check the original.",
           supportedCivilDateText != nil,let d=components,d.hour != nil,d.minute != nil,d.timeZoneID==nil {
            return "Event time zone not established."
        }
        return reviewReason
    }
    /// Whole copied evidence lines may supply both raw date and raw time.
    /// Preserve them once; inference stays explicitly labelled.
    var previewDateText:String? {
        var parts:[String]=[]
        if date==nil,let civil=supportedCivilDateText{return civil}
        if let date=components, date.temporalDerivation != nil,let y=date.year,let m=date.month,let d=date.day {
            parts.append("Estimated · "+String(format:"%04d-%02d-%02d",y,m,d))
            if let clock=date.printedTimeText{parts.append(clock)}
            return parts.joined(separator:" · ")
        }
        for text in [printedDate,printedTime].compactMap({$0}) where !parts.contains(text){parts.append(text)}
        if let inferredYear{parts.append("likely \(inferredYear)")}
        return parts.isEmpty ? nil:parts.joined(separator:" · ")
    }
}
