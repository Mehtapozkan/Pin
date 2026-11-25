import PinCore
import SwiftUI

struct AppointmentCards: View {
    @ObservedObject var appointments: AppointmentCoordinator
    let originals: [PhotoMemory]
    let checkInCodes: [CheckInCodeEvidence]
    var now: Date = Date()
    var question: String? = nil
    var readingStatus: String? = nil
    var answerOverride: AppointmentAnswer? = nil
    let open: (PhotoMemory) -> Void
    var inspect: ((AppointmentItem) -> Void)? = nil
    var willDismiss: (() -> Void)? = nil
    var inlineUnresolved=false
    var answerTimeZone:TimeZone?=nil
    var changeFields:[String:Set<String>]?=nil
    var photoEvidenceOnly=false
    var correct:((AppointmentItem)->Void)?=nil
    private func headerDate(_ date:Date)->String {
        guard let zone=answerTimeZone else{return date.formatted(date:.abbreviated,time:.omitted)}
        let formatter=DateFormatter();formatter.dateStyle = .medium;formatter.timeStyle = .none;formatter.timeZone=zone;return formatter.string(from:date)
    }
    private var visible: [AppointmentItem] { appointments.items.filter { item in !item.dismissed && item.allSources.allSatisfy({source in originals.contains(where: { AppointmentSource($0) == source && !AppointmentCardReader.isPinInterface($0.text) })}) }.sorted { ($0.observation.date ?? .distantFuture) < ($1.observation.date ?? .distantFuture) } }
    private var intent: AppointmentQuestion.Intent? { question.flatMap(AppointmentQuestion.intent) }
    private var confirmed: [AppointmentItem] { visible.filter { AppointmentQuestion.isToday($0.observation, now:now, calendar:.current) } }
    private var unresolved: [AppointmentItem] { answerOverride?.uncertain ?? visible.filter { AppointmentQuestion.unresolved($0.observation) } }
    private var displayed: [AppointmentItem] { answerOverride?.matches ?? (intent == .today ? (confirmed.isEmpty ? unresolved : confirmed) : visible) }
    private var repeatedRegistrations: [RegistrationEvidenceGroup] {
        RegistrationEvidenceGroups.make(items: displayed, originals: originals, codes: checkInCodes)
            .filter { $0.members.count > 1 }
    }
    private var heading: String {
        if let answer=answerOverride {
            if photoEvidenceOnly {
                if answer.matches.isEmpty && !answer.uncertain.isEmpty {return "\(answer.uncertain.count) saved \(answer.uncertain.count==1 ? "entry":"entries") to check"}
                return answer.matches.isEmpty ? "No matching saved entry was established.":"Entries from these photos"
            }
            if answer.window == .all && answer.matches.isEmpty && !answer.uncertain.isEmpty {
                return "\(answer.uncertain.count) appointment booking\(answer.uncertain.count == 1 ? "" : "s") to check"
            }
            if answer.matches.isEmpty {
                return answer.window == .all
                    ? "I haven’t found a matching appointment or ticket entry in these photos."
                    : "I haven’t found a dated appointment in these photos for this period."
            }
            return "Appointment entries from your photos"
        }
        guard intent == .today else { return intent == .bookings ? "Appointment entries from your photos" : "From photos you kept" }
        if !confirmed.isEmpty { return "Appointment entries for today" }
        return "I haven’t found a confirmed appointment for today."
    }
    var body: some View {
        if !visible.isEmpty || intent != nil || answerOverride != nil {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(heading).font(.title2.weight(.semibold))
                ForEach(Array(repeatedRegistrations.enumerated()), id: \.offset) { _, group in
                    Text(group.printedDetailsAgree
                         ? "\(group.members.count) photos show the same Luma registration; ticket count unconfirmed."
                         : "\(group.members.count) photos share a Luma guest registration, but their printed details do not fully agree. Review the originals; ticket count unconfirmed.")
                        .font(.subheadline).foregroundStyle(Color.pinMuted)
                        .accessibilityIdentifier("ticketRegistrationContext")
                }
                if let answer=answerOverride {
                    if case .interval(let interval)=answer.window {
                        Text(interval.end == .distantFuture
                             ? "From \(headerDate(interval.start)) onward"
                             : "\(headerDate(interval.start)) – \(headerDate(interval.end.addingTimeInterval(-1)))")
                            .font(.subheadline).foregroundStyle(Color.pinMuted)
                    }
                    Text(photoEvidenceOnly ? "These are readings of saved photos, not proof of current personal bookings.":"From photos read so far. This may not include every appointment you have.").font(.caption).foregroundStyle(Color.pinMuted)
                }
                if intent != nil, readingStatus != nil || appointments.running {
                    Text(readingStatus ?? "Reading appointment details…").font(.subheadline).foregroundStyle(Color.pinMuted)
                }
                ForEach(displayed) { item in
                    appointmentCard(item)
                }
                if answerOverride != nil && !unresolved.isEmpty {
                    if inlineUnresolved {
                        Text("These entries have dates or conditions that need checking.").font(.subheadline).foregroundStyle(Color.pinMuted)
                        ForEach(unresolved){appointmentCard($0)}
                    }else{
                    DisclosureGroup("Bookings to check (\(unresolved.count))") {
                        ForEach(unresolved) { appointmentCard($0) }
                    }.tint(Color.pinRose)
                    }
                    Text(answerOverride?.window == .all
                         ? "Check the originals before relying on these dates."
                         : "Bookings with uncertain dates aren’t counted in this period.")
                        .font(.subheadline).foregroundStyle(Color.pinMuted)
                }
                if answerOverride == nil && intent == .today && !unresolved.isEmpty {
                    if !confirmed.isEmpty {
                        DisclosureGroup("Other bookings · date unconfirmed (\(unresolved.count))") {
                            ForEach(unresolved) { appointmentCard($0) }
                        }.tint(Color.pinRose)
                    }
                    Text("Bookings with uncertain dates aren’t counted as today’s appointments.").font(.subheadline).foregroundStyle(Color.pinMuted)
                }
                Text("Cards are read when Pin is open. Changes to photo access are checked when you return.").font(.caption).foregroundStyle(Color.pinMuted)
            }
        }
        if let message = appointments.message { Text(message).font(.subheadline).foregroundStyle(Color.pinRose) }
    }
    @ViewBuilder private func appointmentCard(_ item: AppointmentItem) -> some View {
                    VStack(alignment: .leading, spacing: 12) {
                        let state = AppointmentCardReader.attention(item.observation, now: now)
                        Text(item.observation.cancelled == true ? "CANCELLED" : state == .tomorrow ? "TOMORROW" : state == .today ? "TODAY" : state == .past ? "TIME HAS PASSED" : state == .review ? "CHECK THE ORIGINAL" : "UPCOMING")
                            .font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Color.pinRose)
                        let requestedChanges=changeFields?[item.id]
                        let showsChangeAnswer=requestedChanges != nil && item.previousEvidence != nil
                        if showsChangeAnswer,let previous=item.previousEvidence {
                            Text(item.observation.kind ?? item.observation.title).font(.title3.weight(.semibold))
                            CanonicalAppointmentChanges(previous:previous.observation,current:item.observation,fields:requestedChanges)
                        }else{
                            AppointmentFacts(observation:item.observation,photoEvidenceOnly:photoEvidenceOnly)
                        }
                        if let previous=item.previousEvidence {
                            if !showsChangeAnswer {
                                CanonicalAppointmentChanges(previous:previous.observation,current:item.observation)
                            }
                            if let original=originals.first(where:{AppointmentSource($0)==previous.source}) {
                                Button("Earlier original") { open(original) }.font(.subheadline).buttonStyle(.plain)
                                    .accessibilityIdentifier("appointmentEarlierOriginal")
                            }
                        }
                        if let source = originals.first(where: { $0.id == item.sourceID && AppointmentSource($0) == item.source }) {
                            Button { if let inspect { inspect(item) } else { open(source) } } label: {
                                HStack { LibraryPhoto(id: source.id, pixelSize: 200).frame(width: 64, height: 45).clipped().clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true); Text("Original card"); Spacer(); Image(systemName: "arrow.up.right") }
                                    .frame(minHeight:45).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Original card for "+item.observation.title).accessibilityIdentifier("appointmentOriginal")
                        }
                        if showsChangeAnswer {
                            DisclosureGroup("Current details") {
                                AppointmentFacts(observation:item.observation,photoEvidenceOnly:photoEvidenceOnly)
                            }.tint(Color.pinRose).accessibilityIdentifier("appointmentCurrentDetails")
                        }
                        if !photoEvidenceOnly && item.observation.cancelled != true && item.observation.date != nil && item.observation.reviewReason == nil && state != .past {
                            if item.remindersApproved && appointments.notificationsAvailable { Label("Reminders on", systemImage: "bell.badge").font(.subheadline).foregroundStyle(Color.pinRose) }
                            else {
                                Text("Remind you the day before and on the morning, when those times are still ahead? Notification previews keep the details private.").font(.caption).foregroundStyle(Color.pinMuted)
                                Button("Remind me") { Task { await appointments.approve(item) } }.buttonStyle(.borderedProminent).tint(Color.pinRose).foregroundStyle(.white).accessibilityIdentifier("appointmentRemind")
                            }
                        }
                        if let correct,item.canonicalRecordID != nil {
                            Button("Correct details"){correct(item)}.buttonStyle(.plain).accessibilityIdentifier("correctAppointment")
                        }
                        Button("Dismiss") { willDismiss?(); Task { await appointments.dismiss(item) } }.font(.subheadline).foregroundStyle(Color.pinMuted).accessibilityIdentifier("appointmentDismiss")
                    }.padding(18).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 24))
    }

}


/// Shared content facts for the appointment answer and its source-photo result.
/// Screenshot capture date may support an explicitly inferred year; GPS is not a venue.
struct AppointmentFacts: View {
    let observation: AppointmentObservation
    var photoEvidenceOnly=false
    private var corrected:Set<String>{observation.ownerCorrectionFields}
    private var mixedLocationOrigins:Bool{photoEvidenceOnly && observation.venue != nil && observation.address != nil && corrected.contains("venue") != corrected.contains("venueAddress")}
    private func formatted(_ date:Date) -> String {
        let f=DateFormatter();f.dateFormat="EEE, MMM d, yyyy · h:mm a";f.timeZone=TimeZone(identifier:observation.timeZoneID);return f.string(from:date)
    }
    private func captureLabel(_ basis:AppointmentTemporalBasis)->String{let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.calendar=Calendar(identifier:.gregorian);f.dateFormat="yyyy-MM-dd";f.timeZone=TimeZone(identifier:basis.contextTimeZoneID);return f.string(from:basis.originalCapturedAt)}
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if !corrected.isEmpty {Text("Corrected by you").font(.caption.weight(.semibold)).foregroundStyle(Color.pinRose)}
            if observation.eventTicket == true { Text(photoEvidenceOnly ? "EVENT DETAILS":"EVENT TICKET").font(.caption.weight(.semibold)).foregroundStyle(Color.pinRose) }
            Text(observation.kind ?? observation.title).font(.title3.weight(.semibold))
            if let performer=observation.performer,performer != observation.title {Text(performer).font(.headline)}
            if observation.kind != nil || observation.service != nil || observation.eventTicket == true || observation.components != nil, let provider=observation.provider { Text(photoEvidenceOnly ? "Provider · "+provider:provider).font(.headline) }
            if let basis=observation.components?.temporalDerivation,let d=observation.components,let y=d.year,let m=d.month,let day=d.day {
                Text("Estimated date · "+String(format:"%04d-%02d-%02d",y,m,day)).font(.headline)
                if let printed=d.printedDateText{Text("Printed wording · "+printed).font(.subheadline)}
                if let clock=d.printedTimeText{Text(clock).font(.headline)}
                Text("Photo captured · "+captureLabel(basis)).font(.caption).foregroundStyle(Color.pinMuted)
                Text(d.timeZoneID.map{"Event time zone · "+$0} ?? "Event time zone not shown").font(.caption).foregroundStyle(Color.pinMuted)
            }else if let date=observation.date { Text((observation.inferredYear == nil ? "" : "Likely · ") + formatted(date)).font(.headline) }
            else if let civil=observation.supportedCivilDateText {
                Text(civil).font(.headline)
                if let printed=observation.printedDate {Text("Printed wording · "+printed).font(.subheadline)}
                if let time=observation.printedTimeRange ?? observation.printedTime,time != observation.printedDate {Text(time).font(.subheadline)}
            }else {
                if let date=observation.printedDate { Text(date + (observation.inferredYear.map { ", \($0) (likely)" } ?? "")).font(.headline) }
                if let time=observation.printedTimeRange ?? observation.printedTime, !photoEvidenceOnly || time != observation.printedDate { Text(time + (observation.printedTimeZone.map { " " + $0 } ?? "")).font(.headline) }
            }
            if let year=observation.inferredYear, let captured=observation.yearBasisDate {
                Text("\(String(year)) inferred from screenshot taken \(captured.formatted(date:.abbreviated,time:.omitted)).").font(.caption).foregroundStyle(Color.pinMuted)
            }
            if let venue=observation.venue { Label(venue,systemImage:"mappin").font(.subheadline) }
            else if photoEvidenceOnly {Text("Venue not established by this reading.").font(.subheadline).foregroundStyle(Color.pinMuted)}
            if mixedLocationOrigins {Text(corrected.contains("venue") ? "Venue · corrected by you":"Venue · from this photo").font(.caption).foregroundStyle(Color.pinMuted)}
            if let address=observation.address, address != observation.venue { Text(address).font(.subheadline) }
            else if photoEvidenceOnly && observation.address==nil {Text("Full street address not established by this reading.").font(.subheadline).foregroundStyle(Color.pinMuted)}
            if mixedLocationOrigins {Text(corrected.contains("venueAddress") ? "Street address · corrected by you":"Street address · from this photo").font(.caption).foregroundStyle(Color.pinMuted)}
            if !mixedLocationOrigins && (observation.venue != nil || observation.address != nil) { Text(!corrected.isDisjoint(with:["venue","venueAddress"]) ? "Location details · corrected by you":(photoEvidenceOnly ? "Location details · from this photo":"Appointment location · from the confirmation")).font(.caption).foregroundStyle(Color.pinMuted) }
            if let facts=observation.fieldFacts?.filter({$0.field != "calendarDay"}),!facts.isEmpty {
                DisclosureGroup(corrected.isEmpty ? "From this photo":"Photo evidence and your corrections") {
                    ForEach(Array(facts.enumerated()),id:\.offset) { _,fact in
                        VStack(alignment:.leading,spacing:3) {
                            Text(observation.components != nil && ["eventDate","kind","status"].contains(fact.field)
                                 ? (fact.field=="eventDate" ? "Date and time":fact.field=="status" ? (corrected.contains("status") ? "Corrected status":(photoEvidenceOnly ? "Printed status":"Booking status")):"Event type")
                                 : fact.value).font(.subheadline.weight(.medium))
                            if fact.extractorVersion=="pin-owner-correction/1" {Text("Your correction. Original photo wording:").font(.caption).foregroundStyle(Color.pinMuted)}
                            else if fact.origin == .inferred { Text(fact.field == "inferredYear" ? "Suggested by the screenshot date and printed month/day" : "Suggested by the printed details").font(.caption).foregroundStyle(Color.pinMuted) }
                            Text(fact.support.map(\.text).joined(separator:" · ")).font(.caption).foregroundStyle(Color.pinMuted)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,3)
                    }
                }.tint(Color.pinRose)
            }
            if let instruction=observation.instruction { Text(instruction).font(.subheadline).foregroundStyle(Color.pinMuted) }
            if let reason=observation.presentationReviewReason { Text(reason).font(.subheadline).foregroundStyle(Color.pinMuted) }
            if observation.reviewReason == nil || photoEvidenceOnly {
                let printedZone=observation.zoneFromCard ? (observation.components?.timeZoneID ?? observation.printedTimeZone):nil
                if observation.presentationReviewReason != "Event time zone not established." {
                    Text(printedZone.map{(corrected.contains("date") ? "Corrected time zone · ":(photoEvidenceOnly ? "Time zone from this photo · ":"Time zone from the confirmation · "))+$0} ?? (photoEvidenceOnly ? "Event time zone not established":(observation.zoneFromCard ? "Time zone from the confirmation":"Time zone uses this iPhone’s setting when read"))).font(.caption).foregroundStyle(Color.pinMuted)
                }
            }
        }
    }
}

/// Comparison of two revisions admitted by the same native record writer.
/// Source reconciliation removes earlier details as soon as their photo withdraws.
private struct CanonicalAppointmentChanges:View {
    let previous:AppointmentObservation
    let current:AppointmentObservation
    var fields:Set<String>?=nil
    private func includes(_ field:String)->Bool{fields?.contains(field) ?? true}
    private func when(_ o:AppointmentObservation)->String {
        let d=o.components
        let date=d?.year.flatMap { y in d?.month.flatMap { m in d?.day.map{String(format:"%04d-%02d-%02d",y,m,$0)} } } ?? o.printedDate ?? "date unknown"
        let time=d?.hour.flatMap { h in d?.minute.map{String(format:"%02d:%02d",h,$0)} } ?? o.printedTime ?? "time unknown"
        return (d?.temporalDerivation==nil ? "":"Estimated ")+date+" at "+time+" ("+(d?.timeZoneID ?? "time zone unknown")+")"
    }
    private var changes:[String] {
        var values:[String]=[]
        if includes("date"),when(previous) != when(current) {values.append("Date/time: "+when(previous)+" → "+when(current))}
        for (field,label,before,after)in[("title","Event",previous.title,current.title),("provider","Provider",previous.provider,current.provider),("performer","Performer",previous.performer,current.performer),("venue","Venue",previous.venue,current.venue),("venueAddress","Address",previous.address,current.address)] {
            if includes(field),before != after {values.append(label+": "+(before ?? "not supplied")+" → "+(after ?? "not supplied"))}
        }
        if includes("kind"),previous.eventTicket != current.eventTicket {values.append("Type: "+(previous.eventTicket==true ? "Event ticket":"Service appointment")+" → "+(current.eventTicket==true ? "Event ticket":"Service appointment"))}
        if includes("status"),previous.cancelled != current.cancelled {values.append(current.ownerCorrectionFields.contains("status") ? (current.cancelled==true ? "You marked this event cancelled.":"You marked this event scheduled."):(current.cancelled==true ? "The later photo says this booking is cancelled.":"The later photo says this booking is scheduled."))}
        return values
    }
    var body:some View {
        if !changes.isEmpty || fields != nil {
            VStack(alignment:.leading,spacing:8) {
                Text("What changed").font(.headline)
                if changes.isEmpty {Text("No supported difference in these requested details is recorded in the retained photos.").font(.subheadline)}
                ForEach(changes,id:\.self){Text($0).font(.subheadline)}
                Text(current.ownerCorrectionFields.isEmpty ? "According to the earlier and current photos.":"Your correction is shown beside the earlier reading; the printed photo is unchanged.").font(.caption).foregroundStyle(Color.pinMuted)
            }.accessibilityIdentifier("appointmentSupportedChanges")
        }
    }
}

/// Small reference targets keep complete records out of PinHome's value stack.
final class PinOwnerCorrectionTarget:Identifiable {
    let id=UUID()
    let item:AppointmentItem
    init(_ item:AppointmentItem){self.item=item}
}
private enum PinCorrectionField:String,CaseIterable,Identifiable {
    case title="Event name",provider="Provider",venue="Venue",performer="Performer",address="Street address",schedule="Date and time",kind="Event type",status="Status"
    var id:String{rawValue}
    func value(_ o:AppointmentObservation)->String {
        switch self {
        case .title:return o.title
        case .provider:return o.provider ?? ""
        case .venue:return o.venue ?? ""
        case .performer:return o.performer ?? ""
        case .address:return o.address ?? ""
        case .schedule:return ""
        case .kind:return o.eventTicket==true ? "ticket":"appointment"
        case .status:return o.cancelled==true ? "cancelled":"scheduled"
        }
    }
}
struct PinOwnerCorrectionSheet:View {
    let target:PinOwnerCorrectionTarget
    let save:(AppointmentOwnerCorrection)async throws->(item:AppointmentItem,current:Bool)
    let didSave:(AppointmentItem,Bool)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var field:PinCorrectionField
    @State private var value:String
    @State private var year:String
    @State private var month:String
    @State private var day:String
    @State private var hour:String
    @State private var minute:String
    @State private var zone:String
    @State private var saving=false
    @State private var saved:PinOwnerCorrectionTarget?
    @State private var current=true
    @State private var error:String?
    init(target:PinOwnerCorrectionTarget,save:@escaping(AppointmentOwnerCorrection)async throws->(item:AppointmentItem,current:Bool),didSave:@escaping(AppointmentItem,Bool)->Void) {
        self.target=target;self.save=save;self.didSave=didSave
        let o=target.item.observation,f:PinCorrectionField=o.venue==nil ? .title:.venue,d=o.components
        _field=State(initialValue:f);_value=State(initialValue:f.value(o))
        _year=State(initialValue:d?.year.map{String($0)} ?? "");_month=State(initialValue:d?.month.map{String($0)} ?? "")
        _day=State(initialValue:d?.day.map{String($0)} ?? "");_hour=State(initialValue:d?.hour.map{String($0)} ?? "")
        _minute=State(initialValue:d?.minute.map{String($0)} ?? "");_zone=State(initialValue:d?.timeZoneID ?? "")
    }
    private func correction()throws->AppointmentOwnerCorrection {
        switch field {
        case .title:return .title(value)
        case .provider:return .provider(value)
        case .venue:return .venue(value)
        case .performer:return .performer(value)
        case .address:return .address(value)
        case .kind:return .eventTicket(value=="ticket")
        case .status:return .cancelled(value=="cancelled")
        case .schedule:
            func number(_ s:String)throws->Int? {
                let t=s.trimmingCharacters(in:.whitespacesAndNewlines)
                if t.isEmpty{return nil};guard let n=Int(t)else{throw PinStoreError.staleImport};return n
            }
            let z=zone.trimmingCharacters(in:.whitespacesAndNewlines)
            return .schedule(AppointmentDateComponents(year:try number(year),month:try number(month),day:try number(day),hour:try number(hour),minute:try number(minute),timeZoneID:z.isEmpty ? nil:z))
        }
    }
    var body:some View {
        NavigationStack {
            Form {
                if let saved {
                    Section {
                        Text("Correction saved").font(.headline).accessibilityIdentifier("ownerCorrectionSaved")
                        if current{AppointmentFacts(observation:saved.item.observation,photoEvidenceOnly:true)}
                        else{Text("Saved locally. Photo access changed; reopen the details when the photos are available.")}
                        Text("The original photo is unchanged.").foregroundStyle(Color.pinMuted)
                    }
                }else {
                    Section {Text(target.item.observation.title).font(.headline);Text("Correct Pin’s reading. This changes the saved details, not the photo.").font(.subheadline)}
                    Section("Detail to correct") {Picker("Detail",selection:$field){ForEach(PinCorrectionField.allCases){Text($0.rawValue).tag($0)}}.accessibilityIdentifier("ownerCorrectionField")}
                    Section("Your correction") {
                        if field == .schedule {
                            HStack {TextField("Year",text:$year);TextField("Month",text:$month);TextField("Day",text:$day)}.keyboardType(.numberPad)
                            HStack {TextField("Hour (0–23)",text:$hour);TextField("Minute",text:$minute)}.keyboardType(.numberPad)
                            TextField("Time zone, if known",text:$zone).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Text("Leave unknown parts empty. A time zone such as Europe/Paris determines the event’s local time.").font(.caption).foregroundStyle(Color.pinMuted)
                            if let printed=target.item.observation.printedDate {Text("Photo wording · "+printed).font(.caption)}
                            if let printed=target.item.observation.printedTime {Text(printed).font(.caption)}
                        }else if field == .status {
                            Picker("Status",selection:$value){Text("Scheduled").tag("scheduled");Text("Cancelled").tag("cancelled")}
                        }else if field == .kind {
                            Picker("Type",selection:$value){Text("Event ticket").tag("ticket");Text("Appointment").tag("appointment")}
                        }else{TextField(field.rawValue,text:$value,axis:.vertical).accessibilityIdentifier("ownerCorrectionValue")}
                    }
                    if let error{Section{Text(error).foregroundStyle(Color.pinRose).accessibilityIdentifier("ownerCorrectionError")}}
                    Section {
                        Button(saving ? "Saving correction…":"Save correction") {
                            do {
                                let edit=try correction();saving=true;error=nil
                                Task {do {let result=try await save(edit);saved=PinOwnerCorrectionTarget(result.item);current=result.current;didSave(result.item,result.current);saving=false}
                                    catch{saving=false;self.error="This correction couldn’t be saved. Check the value, or reopen the current event if its photo changed."}}
                            }catch{self.error="Enter valid date and time parts. Leave any unknown parts empty."}
                        }.disabled(saving).accessibilityIdentifier("saveOwnerCorrection")
                    }
                }
            }.navigationTitle(saved==nil ? "Correct details":"Updated details").navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.confirmationAction){Button(saved==nil ? "Cancel":"Done"){dismiss()}.disabled(saving)}}
            .interactiveDismissDisabled(saving)
            .onChange(of:field){_,next in value=next.value(target.item.observation);error=nil}
        }.tint(Color.pinRose)
    }
}
struct PinCorrectedAppointmentResult:View {
    let target:PinOwnerCorrectionTarget
    let open:(AppointmentSource)->Void
    let correct:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Updated event details").font(.title2.weight(.semibold))
            AppointmentFacts(observation:target.item.observation,photoEvidenceOnly:true)
            ForEach(Array(target.item.allSources.enumerated()),id:\.offset){index,source in
                Button(target.item.allSources.count==1 ? "Original photo":"Original photo \(index+1)"){open(source)}
                    .accessibilityIdentifier("correctedOriginal-\(index+1)")
            }
            Button("Correct details",action:correct)
        }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.85),in:RoundedRectangle(cornerRadius:24))
    }
}
