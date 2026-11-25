import PinCore
import PinMemory
import SwiftUI

/// Progressive exhaustive results reuse the native cards. Counts and global
/// extrema are scoped to saved entries; source gaps remain visible separately.
struct ExhaustiveAppointmentResult:View {
    let result:PinExhaustiveQuestionAnswer
    @ObservedObject var appointments:AppointmentCoordinator
    let originals:[PhotoMemory]
    let open:(PhotoMemory)->Void
    let forget:(PhotoMemory)->Void
    let inspect:(AppointmentItem)->Void
    var continueScan:(()->Void)?=nil
    private var current:Bool {
        (result.matches+result.uncertain).allSatisfy{old in
            appointments.items.contains{row in !row.dismissed && row.hasSameEvidence(as:old) && row.canonicalRevision==old.canonicalRevision && row.previousEvidence==old.previousEvidence}
        } && result.missingEvidence.allSatisfy{target in originals.contains{EvidenceSource($0)==target.source}}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            if current {
                Text(result.coverage.notice).font(.subheadline).foregroundStyle(Color.pinMuted).accessibilityIdentifier("exhaustiveCoverage")
                Text(result.summary).font(.title3.weight(.semibold)).accessibilityIdentifier("exhaustiveSummary")
                if let evidence=result.sourceStatusEvidence {
                    VStack(alignment:.leading,spacing:10) {
                        if let notice=evidence.personalBookingNotice {Text(notice).accessibilityIdentifier("sourceEvidencePersonalLimit")}
                        if evidence.requested.contains("documentedStatus") {
                            ForEach(evidence.rows,id:\.recordID) { row in
                                let title=result.matches.first{$0.canonicalRecordID==row.recordID}?.observation.title ?? "Saved entry"
                                VStack(alignment:.leading,spacing:5) {
                                    Text(title).font(.subheadline.weight(.semibold))
                                    Text(row.notice)
                                    if row.cancellation != "cancellationNotEstablished" {
                                        ForEach(Array(row.support.enumerated()),id:\.offset) { _,support in
                                            Text("\(support.originLabel): “\(support.quote)”").font(.subheadline).foregroundStyle(Color.pinMuted)
                                        }
                                    }
                                }
                            }
                            if let notice=evidence.cancellationLimitNotice {Text(notice).foregroundStyle(Color.pinMuted)}
                        }
                    }
                }
                if !result.coverage.entireAdmittedInventory,let continueScan {
                    Button("Check remaining saved entries",action:continueScan).buttonStyle(.bordered).tint(Color.pinRose).accessibilityIdentifier("exhaustiveContinue")
                }
                if !result.displayRows.isEmpty || !result.uncertain.isEmpty {
                    SemanticAppointmentResult(snapshot:.list(AppointmentAnswer(window:.all,selection:.any,matches:result.displayRows,uncertain:result.uncertain,coverage:.incomplete)),appointments:appointments,originals:originals,checkInCodes:[],readingStatus:nil,open:open,forget:forget,inspect:inspect,inlineUnresolved:true,photoEvidenceOnly:true)
                }
                ForEach(result.displayRows+result.uncertain) { row in
                    let notices=appointments.freshTemporalNotices(for:row,answerID:result.requestID,originals:originals)
                    if !notices.isEmpty {
                        VStack(alignment:.leading,spacing:5) {
                            Text(row.observation.title).font(.headline)
                            ForEach(notices,id:\.self){Text($0).foregroundStyle(Color.pinMuted)}
                        }.accessibilityIdentifier("temporalRoleExplanation")
                    }
                }
                if !result.unresolvedDetails.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(result.unresolvedDetails.keys.sorted(),id:\.self) { id in
                            let row=(result.matches+result.uncertain).first{$0.canonicalRecordID==id}
                            let labels=["performer":"performer","provider":"provider","venue":"venue","venueAddress":"full street address","localDate":"event date","startClock":"start time","explicitTimeZone":"time zone"]
                            let missing=(result.unresolvedDetails[id] ?? []).sorted().map{labels[$0] ?? "requested detail"}.joined(separator:", ")
                            Text("\(row?.observation.title ?? "This entry"): not established from the current reading — \(missing).")
                                .foregroundStyle(Color.pinMuted)
                        }
                    }.accessibilityIdentifier("exhaustiveMissingDetails")
                }
                if !result.missingEvidence.isEmpty {
                    DisclosureGroup("Photos to check") {
                        ForEach(originals.filter{memory in result.missingEvidence.contains{$0.source==EvidenceSource(memory)}}) { memory in
                            Button{open(memory)}label:{Text("Open supporting photo").frame(minHeight:44)}.buttonStyle(.plain)
                        }
                    }.tint(Color.pinRose)
                }
            }else{
                Text("The saved evidence changed. Ask again to check the current entries.").font(.title3.weight(.semibold))
            }
        }
    }
}

enum SemanticAppointmentSnapshot {
    case list(AppointmentAnswer)
    case location(AppointmentItem)
    func refreshed(items: [AppointmentItem], originals: [PhotoMemory]) -> SemanticAppointmentSnapshot? {
        switch self {
        case .list(let answer):
            guard let current = answer.refreshed(items: items, originals: originals) else { return nil }
            return .list(current)
        case .location(let item):
            guard let current = AppointmentAnswerEngine.rebind([item], items: items, originals: originals)?.first else { return nil }
            return .location(current)
        }
    }
}

/// The same native cards and original controls render an admitted retrieval
/// result. Coverage stays visible even when the bounded answer contains rows.
/// The coordinator must re-admit before publication and invalidate on changes.
struct RetrievedAppointmentResult:View {
    let result:PinRetrievedQuestionAnswer
    @ObservedObject var appointments:AppointmentCoordinator
    let originals:[PhotoMemory]
    let checkInCodes:[CheckInCodeEvidence]
    let open:(PhotoMemory)->Void
    let forget:(PhotoMemory)->Void
    let inspect:(AppointmentItem)->Void
    var willDismiss:(()->Void)?=nil
    private var gapSources:Set<EvidenceSource> {
        result.coverage.sourcesNeedingPreparation.union(result.coverage.sourcesWithUncertainRelevance)
    }
    private var gapEvidenceCurrent:Bool {
        gapSources.allSatisfy{source in originals.contains{EvidenceSource($0)==source}}
    }
    private var snapshot:SemanticAppointmentSnapshot? {
        guard let answer=result.answer,let context=answer.context else{return nil}
        if answer.route=="location",answer.matched.count==1{return .location(answer.matched[0])}
        guard ["list","changes","originals"].contains(answer.route) else{return nil}
        return .list(AppointmentAnswer(window:context.window,selection:.any,matches:answer.matched,uncertain:answer.unresolved,coverage:.incomplete))
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            if gapEvidenceCurrent {
                Text(result.coverage.notice).font(.subheadline).foregroundStyle(Color.pinMuted)
                    .accessibilityIdentifier("retrievalCoverage")
                if let snapshot {
                    SemanticAppointmentResult(snapshot:snapshot,appointments:appointments,originals:originals,checkInCodes:checkInCodes,readingStatus:nil,open:open,forget:forget,inspect:inspect,willDismiss:willDismiss,inlineUnresolved:true,answerTimeZone:result.answer?.context?.displayTimeZone,answerNow:result.answer?.context?.submittedAt,changeFields:result.answer?.requestedChangeFields.map{fields in Dictionary(uniqueKeysWithValues:(result.answer?.matched ?? []).map{($0.id,fields)})})
                }else{
                    Text(result.answer?.clarification ?? result.stage.emptyNotice).font(.title3.weight(.semibold))
                        .accessibilityIdentifier("retrievalUnresolved")
                }
                if !gapSources.isEmpty {
                    DisclosureGroup("Photos to check") {
                        ForEach(originals.filter{gapSources.contains(EvidenceSource($0))}) { memory in
                            Button{open(memory)}label:{
                                HStack{LibraryPhoto(id:memory.id,pixelSize:200).frame(width:64,height:45).clipped().accessibilityHidden(true);Text("Open supporting photo");Spacer();Image(systemName:"arrow.up.right")}
                                    .frame(minHeight:45).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Open supporting photo for this search")
                        }
                    }.tint(Color.pinRose)
                }
            }else{
                Text("The photo evidence changed. Ask again to search the current information.").font(.title3.weight(.semibold))
            }
        }
    }
}

struct SemanticAppointmentResult: View {
    let snapshot: SemanticAppointmentSnapshot
    @ObservedObject var appointments: AppointmentCoordinator
    let originals: [PhotoMemory]
    let checkInCodes: [CheckInCodeEvidence]
    let readingStatus: String?
    let open: (PhotoMemory) -> Void
    let forget: (PhotoMemory) -> Void
    let inspect: (AppointmentItem) -> Void
    var willDismiss:(() -> Void)?=nil
    var inlineUnresolved=false
    var answerTimeZone:TimeZone?=nil
    var answerNow:Date?=nil
    var changeFields:[String:Set<String>]?=nil
    var photoEvidenceOnly=false
    var correct:((AppointmentItem)->Void)?=nil
    private var retainedChangesCurrent:Bool {
        guard changeFields != nil else{return true}
        if case .list(let answer)=snapshot {
            return (answer.matches+answer.uncertain).allSatisfy{old in
                appointments.items.contains{row in row.hasSameEvidence(as:old) && row.canonicalRevision==old.canonicalRevision && row.previousEvidence==old.previousEvidence} &&
                (old.previousEvidence?.sources ?? []).allSatisfy{source in originals.contains{AppointmentSource($0)==source}}
            }
        }
        return false
    }
    var body: some View {
        if retainedChangesCurrent,let current = snapshot.refreshed(items: appointments.items, originals: originals) {
            switch current {
            case .list(let answer):
                AppointmentCards(appointments:appointments,originals:originals,checkInCodes:checkInCodes,now:answerNow ?? Date(),
                    readingStatus:readingStatus,answerOverride:answer,open:open,inspect:inspect,willDismiss:willDismiss,inlineUnresolved:inlineUnresolved,answerTimeZone:answerTimeZone,changeFields:changeFields,photoEvidenceOnly:photoEvidenceOnly,correct:correct)
            case .location(let item):
                VStack(alignment:.leading,spacing:16) {
                    Text("Appointment location").font(.title2.weight(.semibold))
                    Text(item.observation.kind ?? item.observation.title).font(.headline)
                    if let venue=item.observation.venue { Label(venue,systemImage:"mappin").font(.title3.weight(.semibold)) }
                    if let address=item.observation.address { Text(address).font(.body) }
                    Text("From the appointment’s original photo.").font(.subheadline).foregroundStyle(Color.pinMuted)
                    if let correct,item.canonicalRecordID != nil {Button("Correct details"){correct(item)}.buttonStyle(.plain).accessibilityIdentifier("correctAppointment")}
                    if let previous=item.previousEvidence,let original=originals.first(where:{AppointmentSource($0)==previous.source}) {
                        Button("Earlier original"){open(original)}.font(.subheadline).buttonStyle(.plain).accessibilityIdentifier("appointmentEarlierOriginal")
                    }
                    if let source=originals.first(where:{AppointmentSource($0)==item.source}) {
                        Button { inspect(item) } label: {
                            HStack { LibraryPhoto(id:source.id,pixelSize:200).frame(width:64,height:45).clipped().clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true);Text("Original card");Spacer();Image(systemName:"arrow.up.right") }.frame(height:45).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("semanticAppointmentOriginal")
                        Button("Forget this photo in Pin", role: .destructive) { forget(source) }
                            .font(.footnote).accessibilityIdentifier("semanticAppointmentForget")
                    }
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.85),in:RoundedRectangle(cornerRadius:24))
            }
        } else {
            Text("These appointment details changed or are no longer available. Ask again to see the current information.").font(.title3.weight(.semibold))
        }
    }
}

/// One displayed unit retains every member's own printed claims and sources.
/// Existing native fact presentation is reused; a member is never an event proxy.
/// Box the contextual handle so PinHome scene construction stays small.
final class PinLinkedUnitViewState {
    let answer:PinLinkedUnitContextualAnswer
    let displayedAnswer:PinLinkedUnitContextualAnswer
    init(_ answer:PinLinkedUnitContextualAnswer,displayedAnswer:PinLinkedUnitContextualAnswer?=nil){self.answer=answer;self.displayedAnswer=displayedAnswer ?? answer}
}
struct UnitAppointmentResult:View {
    let result:PinUnitQuestionAnswer
    @ObservedObject var appointments:AppointmentCoordinator
    let originals:[PhotoMemory]
    let working:Bool
    let notice:String?
    let evidence:PinUnitContextualAnswer?
    let open:(String)->Void
    var correct:((AppointmentItem)->Void)?=nil
    var linked:PinLinkedUnitContextualAnswer?=nil
    private var current:Bool {
        result.rows.allSatisfy{(try? PinUnitPresentation.row($0,contextual:evidence)) != nil && (try? PinLinkedUnitPresentation.row($0,contextual:linked)) != nil} && result.rows.flatMap(\.members).allSatisfy{member in
            appointments.items.contains(member.item) && member.sources.allSatisfy{source in originals.contains{EvidenceSource($0)==source}}
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            if current {
                if working{ProgressView("Understanding your question…")}
                if let notice{Text(notice).foregroundStyle(Color.pinMuted)}
                Text(result.sourceDocumentList != nil ? "Details from these photos":result.resultUnit=="documents" ? "Tickets from these photos":"Events from these photos").font(.title2.weight(.semibold))
                    .accessibilityIdentifier("unitAppointmentResult")
                if result.operation=="count" {
                    Text(result.exactCount.map{"\($0) matching \(result.resultUnit=="documents" ? "tickets":"events")"} ?? "Between \(result.countLowerBound) and \(result.countUpperBound) may match; identity or membership remains uncertain.")
                        .accessibilityIdentifier("unitCount")
                }
                Text(result.coverage.notice).font(.subheadline).foregroundStyle(Color.pinMuted)
                if !result.identityResolved{Text("The reading does not yet establish whether all of these are distinct.").foregroundStyle(Color.pinMuted)}
                if result.requestedSourceEvidence.contains("currentPersonalBooking") || evidence?.requestedSourceEvidence.contains("currentPersonalBooking")==true || linked?.requestedSourceEvidence.contains("currentPersonalBooking")==true {
                    Text("These photos alone do not establish current personal bookings, or prove that you have none.").foregroundStyle(Color.pinMuted)
                }
                if result.requestedSourceEvidence.contains("documentedStatus") || evidence?.requestedSourceEvidence.contains("documentedStatus")==true || linked?.requestedSourceEvidence.contains("documentedStatus")==true {
                    Text("Cancellation evidence is reviewed per document. This does not establish actual non-cancellation or the absence of a printed notice.").font(.subheadline).foregroundStyle(Color.pinMuted)
                }
                ForEach(Array(result.rows.enumerated()).filter{entry in linked==nil || linked!.rows.contains(where:{$0.selection.row.id==entry.element.id})},id:\.element.id) { index,original in
                    let base=(try? PinUnitPresentation.row(original,contextual:evidence)) ?? original
                    let row=(try? PinLinkedUnitPresentation.row(base,contextual:linked)) ?? base
                    VStack(alignment:.leading,spacing:14) {
                        Text("\(result.sourceDocumentList != nil ? "Photo":result.resultUnit=="documents" ? "Ticket":"Event") \(index+1)").font(.headline)
                        if (result.sourceDocumentList?.rows.first(where:{$0.id==row.id}).map{$0.queryMembership=="uncertain"} ?? row.membershipUncertain){Text("Whether this matches is unresolved.").foregroundStyle(Color.pinMuted)}
                        if !row.conflictingFields.isEmpty{Text("These documents have differing details. Review each reading below.").foregroundStyle(Color.pinMuted)}
                        if let scoped=linked?.rows.first(where:{$0.selection.row.id==row.id}),scoped.scopedDetails != nil {
                            ScopedTicketDetails(row:scoped)
                        }else{
                        ForEach(Array(row.members.enumerated()),id:\.offset) { memberIndex,member in
                            VStack(alignment:.leading,spacing:10) {
                                if row.members.count>1{Text("Document \(memberIndex+1) of \(row.members.count)").font(.subheadline.weight(.semibold))}
                                AppointmentFacts(observation:member.item.observation,photoEvidenceOnly:true)
                                if let correct{Button("Correct details"){correct(member.item)}.disabled(working).accessibilityIdentifier("correctUnit-\(index+1)-\(memberIndex+1)")}
                                if member.selection=="excluded"{Text("This document does not meet the requested condition; it remains part of this event’s evidence.").foregroundStyle(Color.pinMuted)}
                                if member.selection=="uncertain"{Text("This document’s match is uncertain.").foregroundStyle(Color.pinMuted)}
                                let facets=linked?.requestedSourceEvidence ?? (evidence?.selection.row.id==row.id ? evidence!.requestedSourceEvidence:result.requestedSourceEvidence)
                                if facets.contains("documentedStatus") {
                                    Text(member.cancellation=="observedCancellation" ? "Cancellation is documented in this photo’s evidence.":member.cancellation=="correctedCancellation" ? "An owner correction records cancellation.":"Cancellation is not established by this reading.")
                                    ForEach(Array(member.statusSupport.enumerated()),id:\.offset){_,support in Text("\(support.originLabel): “\(support.quote)”").font(.caption)}
                                    Text("This does not establish that no cancellation notice appears in the photos.").font(.caption).foregroundStyle(Color.pinMuted)
                                }
                                if facets.contains("currentPersonalBooking"){Text("These photos alone do not establish current personal bookings, or prove that you have none.").foregroundStyle(Color.pinMuted)}
                            }
                        }
                        }
                        if let linkedRow=linked?.rows.first(where:{$0.selection.row.id==row.id}),linkedRow.scopedDetails==nil {
                            LinkedUnitEvidenceNotes(row:linkedRow)
                        }
                        if linked==nil,let gaps=result.unresolvedFieldsByUnit[row.id],!gaps.isEmpty{
                            let labels=["performer":"performer","provider":"provider","venue":"venue","venueAddress":"full street address","localDate":"event date","startClock":"start time","explicitTimeZone":"time zone"]
                            Text("Not established by this reading: "+gaps.sorted().map{labels[$0] ?? "requested detail"}.joined(separator:", ")+".").foregroundStyle(Color.pinMuted)
                        }
                        Button(row.sources.count==1 ? "Original photo":"Original photos"){open(row.id)}
                            .disabled(working).accessibilityIdentifier("unitOriginal-\(index+1)")
                    }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.85),in:RoundedRectangle(cornerRadius:24))
                }
                if result.rows.isEmpty{Text("No matching event or ticket was established in the prepared evidence.")}
                Text("Based on saved photo evidence. This does not establish ownership, attendance or a complete personal calendar.").font(.caption).foregroundStyle(Color.pinMuted)
            }else{Text("The photo evidence changed. Ask again for current details.")}
        }
    }
}

/// Scoped output is separate from the full unit proof. Never use a sibling or
/// the current corrected AppointmentFacts view to render printed values.
private struct ScopedTicketDetails:View {
    let row:PinLinkedUnitQuestionRow
    private let labels=["performer":"Performer","provider":"Provider","venue":"Venue","venueAddress":"Street address","venueLocation":"Venue location","localDate":"Event date","startClock":"Start time","explicitTimeZone":"Time zone","yearEvidence":"Printed year"]
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if let path=row.selectedMemberPath {Text("Document \(path.memberOrdinal) of \(row.selection.row.members.count)").font(.headline)}
            ForEach(Array((row.scopedDetails ?? []).enumerated()),id:\.offset){_,detail in
                VStack(alignment:.leading,spacing:4) {
                    Text(labels[detail.detail.rawValue] ?? "Requested detail").font(.subheadline.weight(.semibold))
                    if let value=detail.value {Text(value)}
                    if !detail.established {
                        Text(detail.scope == .printedOwnSource ? "Not established by this ticket’s retained printed evidence.":"Not established in this ticket’s saved details.").foregroundStyle(Color.pinMuted)
                    }
                    if detail.basis == .retainedObservedBeforeCorrection {Text("Printed value retained from before your correction.").font(.caption).foregroundStyle(Color.pinMuted)}
                    if detail.scope == .currentSaved,detail.support?.origin == .domainCorrection {Text("Your saved correction.").font(.caption).foregroundStyle(Color.pinMuted)}
                }.accessibilityIdentifier("scopedTicket-"+detail.detail.rawValue)
            }
        }.accessibilityIdentifier("scopedTicketDetails")
    }
}

private struct LinkedUnitEvidenceNotes:View {
    let row:PinLinkedUnitQuestionRow
    private let labels=["performer":"performer","provider":"provider","venue":"venue","venueAddress":"full street address","venueLocation":"venue location","localDate":"event date","startClock":"start time","explicitTimeZone":"time zone","yearEvidence":"printed year","changes":"retained comparison","expansion":"evidence reading"]
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            ForEach(Array(row.expansions.enumerated()),id:\.offset){_,expansion in
                switch expansion.payload {
                case .appointment:EmptyView()
                case .change(let change):
                    Text("What changed").font(.headline)
                    Text(change.text).font(.subheadline)
                case .world(let item):
                    Text("Linked photo evidence").font(.subheadline.weight(.semibold))
                    ForEach(Array(item.fields.enumerated()),id:\.offset){_,field in
                        if field.state != .known{Text("This linked detail is incomplete or has differing evidence.").font(.caption).foregroundStyle(Color.pinMuted)}
                        ForEach(Array(field.claims.enumerated()),id:\.offset){_,claim in
                            if case .text(let value)=claim.value {
                                Text(value).font(.subheadline)
                                ForEach(Array(claim.anchors.enumerated()),id:\.offset){_,anchor in Text("From linked photo evidence: “"+anchor.quote+"”").font(.caption).foregroundStyle(Color.pinMuted)}
                            }
                        }
                    }
                }
            }
            ForEach(Array(row.selection.row.members.enumerated()),id:\.offset){index,member in
                let fields=Set(row.gaps.filter{$0.recordID==member.item.canonicalRecordID}.map(\.field))
                if !fields.isEmpty {
                    Text((row.selection.row.members.count>1 ? "Document \(index+1): ":"")+"Not established: "+fields.sorted().map{labels[$0] ?? "requested detail"}.joined(separator:", ")+".").font(.subheadline).foregroundStyle(Color.pinMuted)
                }
            }
        }.accessibilityIdentifier("linkedUnitEvidenceNotes")
    }
}

#if DEBUG && targetEnvironment(simulator)
import IBrain
import IBrainSemantics

/// Simulator-only rendering of exact retained task/receipt pairs. This control
/// exercises the production unit view, not PhotoKit or live provider dispatch.
struct PinLinkedUnitRenderControl:View {
    static var enabled:Bool{Bundle.main.bundleIdentifier=="app.pin.freshproduct" && ProcessInfo.processInfo.arguments.contains(where:{$0.hasPrefix("--test-v36-render=")})}
    struct Input:Decodable {let authority:PinProductQuestionAuthority;let recoveredAuthority:PinProductQuestionAuthority?
        var sourceDocumentListAssessmentV1:Bool?=nil;var inventoryDocumentIdentityV1:Bool?=nil;let inventory:Request;let details:Request?;let parent:PinProductPublishedParent}
    struct Request:Decodable {let question:String;let requestID:UUID;let now:Date;let task:CompactProductQueryTask;let receipt:CompactProductQueryReceipt}
    struct Retained:CompactProductQueryProvider {
        let request:Request
        func decide(_ task:CompactProductQueryTask)async throws->CompactProductQueryReceipt {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            guard try encoder.encode(task)==encoder.encode(request.task)else{throw PinEvidenceError.staleRecord}
            try request.receipt.validate(for:task);return request.receipt
        }
    }
    @MainActor final class State:ObservableObject {
        @Published var answer:PinUnitQuestionAnswer?
        @Published var linked:PinLinkedUnitViewState?
        @Published var message:String?
        @Published var handoff=false
        var memories:[PhotoMemory]=[]
        var cache:PinAppointmentProjectionCache?
        var context:PinDisplayedUnitContext?
        let appointments=AppointmentCoordinator()
        func prepare(_ owner:PinAppointmentProjectionCache,_ request:Request,previous:PinDisplayedUnitContext?)async throws->PinPreparedLinkedUnitProductAnswer {
            var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"America/Los_Angeles")!;calendar.firstWeekday=1
            if [CompactProductQueryPlanner.calendarDefaultsVersion,CompactProductQueryPlanner.photoCalendarDefaultsVersion,CompactProductQueryPlanner.locationExtentVersion].contains(request.task.version) {
                return try await owner.prepareCalendarDefaultsCompactUnitProductQuestion(request.question,requestID:request.requestID,now:request.now,calendar:calendar,previous:previous,provider:Retained(request:request),usePhotoScopeComposition:[CompactProductQueryPlanner.photoCalendarDefaultsVersion,CompactProductQueryPlanner.locationExtentVersion].contains(request.task.version),useLocationExtent:request.task.version==CompactProductQueryPlanner.locationExtentVersion)
            }
            if request.task.version==PinPublicProductScope.currentSourceScopeQueryVersion {
                guard previous==nil else{throw PinEvidenceError.staleRecord}
                return try await owner.prepareCurrentSourceScopeCompactUnitProductQuestion(request.question,requestID:request.requestID,now:request.now,calendar:calendar,provider:Retained(request:request))
            }
            if request.task.version==CompactProductQueryPlanner.photoScopeInventoryVersion {
                return try await owner.preparePhotoScopeCompactUnitProductQuestion(request.question,requestID:request.requestID,now:request.now,calendar:calendar,previous:previous,provider:Retained(request:request))
            }
            if request.task.version==CompactProductQueryPlanner.memberAwareVersion || request.task.version==CompactProductQueryPlanner.currentSavedInventoryVersion {
                return try await owner.prepareMemberCompactUnitProductQuestion(request.question,requestID:request.requestID,now:request.now,calendar:calendar,previous:previous,provider:Retained(request:request),useCurrentSavedInventory:request.task.version==CompactProductQueryPlanner.currentSavedInventoryVersion)
            }
            guard request.task.version==CompactProductQueryPlanner.linkedUnitVersion else{throw PinEvidenceError.staleRecord}
            return try await owner.prepareLinkedCompactUnitProductQuestion(request.question,requestID:request.requestID,now:request.now,calendar:calendar,previous:previous,provider:Retained(request:request))
        }
        func load()async {
            guard answer==nil else{return}
            do {
                let expected=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--test-v36-render=")})!.dropFirst("--test-v36-render=".count)
                let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("v36-render.json"),data=try Data(contentsOf:file)
                guard data.count<=2_097_152,ChoiceTask.hash(data)==expected else{throw PinEvidenceError.staleRecord}
                let input=try JSONDecoder().decode(Input.self,from:data)
                let directory=FileManager.default.temporaryDirectory.appendingPathComponent("v36-render-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try input.authority.sdkMemory.write(to:directory.appendingPathComponent("memory.json"))
                let owner=try PinAppointmentProjectionCache(directory:directory,sealedWorld:false,sourceInventory:.permittedPhotoObservations)
                cache=owner;memories=input.authority.memories;appointments.items=input.authority.records
                _=try await owner.synchronize(memories:input.authority.memories,records:input.authority.records)
                var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"America/Los_Angeles")!;calendar.firstWeekday=1
                guard case .inventory(let pending)=try await prepare(owner,input.inventory,previous:nil)else{throw PinEvidenceError.staleRecord}
                let scan=try await owner.advanceExhaustiveQuestion(pending.question,activeRequestID:input.inventory.requestID)
                let flat=try await owner.admitExhaustiveQuestion(scan,activeRequestID:input.inventory.requestID)
                guard let unit=flat.pendingResultUnit,let proof=input.authority.unitEvidence else{throw PinEvidenceError.staleRecord}
                let prepared=try proof.prepare(memories:input.authority.memories,records:input.authority.records,unit:unit,initialPolicy:.compactKeysV1)
                let relation=try PinProductUnitEvidence.crossSourceRelationTask(prepared:prepared,documentIdentityV1:input.inventoryDocumentIdentityV1==true)
                var inventory=try await owner.inventoryUnitQuestion(scan,prepared:prepared,relationTask:relation,relationReceipt:relation==nil ? nil:proof.crossSourceReceipt,documentIdentityV1:input.inventoryDocumentIdentityV1==true,activeRequestID:input.inventory.requestID)
                if let recovered=input.recoveredAuthority {
                    guard input.details==nil,[CompactProductQueryPlanner.photoScopeInventoryVersion,PinPublicProductScope.currentSourceScopeQueryVersion,CompactProductQueryPlanner.calendarDefaultsVersion,CompactProductQueryPlanner.photoCalendarDefaultsVersion,CompactProductQueryPlanner.locationExtentVersion].contains(input.inventory.task.version),
                          let currentProof=recovered.unitEvidence,let expected=input.parent.reconciliation else{throw PinEvidenceError.staleRecord}
                    let original=try await owner.captureProductAuthoritySnapshot(memories:input.authority.memories,records:input.authority.records,originalSHA256BySourceID:input.authority.originalSHA256BySourceID)
                    let plan=try await owner.planUnitReread(inventory,snapshot:original,evidence:proof,initialPolicy:.compactKeysV1,documentIdentityV1:input.inventoryDocumentIdentityV1==true,activeRequestID:input.inventory.requestID)
                    let meaning=try await owner.captureExhaustiveInterpretation(plan,activeRequestID:input.inventory.requestID)
                    _=try await owner.synchronize(memories:recovered.memories,records:recovered.records)
                    let next=try await owner.prepareExhaustiveQuestion(input.inventory.question,requestID:input.inventory.requestID,now:input.inventory.now,calendar:calendar,inferredDatePolicy:.labelledTemporalContext,interpretation:meaning)
                    let currentScan=try await owner.advanceExhaustiveQuestion(next.question,activeRequestID:input.inventory.requestID)
                    let currentPrepared=try currentProof.prepare(memories:recovered.memories,records:recovered.records,unit:unit,initialPolicy:.compactKeysV1)
                    let currentRelation=try PinProductUnitEvidence.crossSourceRelationTask(prepared:currentPrepared,documentIdentityV1:input.inventoryDocumentIdentityV1==true)
                    inventory=try await owner.inventoryUnitQuestion(currentScan,prepared:currentPrepared,relationTask:currentRelation,relationReceipt:currentRelation==nil ? nil:currentProof.crossSourceReceipt,documentIdentityV1:input.inventoryDocumentIdentityV1==true,activeRequestID:input.inventory.requestID)
                    let current=try await owner.captureProductAuthoritySnapshot(memories:recovered.memories,records:recovered.records,originalSHA256BySourceID:recovered.originalSHA256BySourceID)
                    let actual=try await owner.mintProductReconciliation(initial:original.withUnitEvidence(proof),current:current.withUnitEvidence(currentProof),interpretation:meaning,answer:inventory)
                    guard actual.questionRequestID==expected.questionRequestID,actual.originalAuthoritySHA256==expected.originalAuthoritySHA256,actual.publishedAuthoritySHA256==expected.publishedAuthoritySHA256 else{throw PinEvidenceError.staleRecord}
                    memories=recovered.memories;appointments.items=recovered.records
                }
                if input.sourceDocumentListAssessmentV1==true{inventory=try await owner.sourceDocumentListQuestion(inventory)}
                guard let publication=input.parent.units else{throw PinEvidenceError.staleRecord}
                let displayed=try await owner.contextForDisplayedUnitAnswer(inventory,displayedUnitIDs:publication.displayedUnitIDs,displayIdentity:publication.displayIdentity)
                guard displayed.bindingSHA256==publication.bindingSHA256,displayed.orderedMemberRecordIDs==publication.orderedMemberRecordIDs else{throw PinEvidenceError.staleRecord}
                if [CompactProductQueryPlanner.currentSavedInventoryVersion,CompactProductQueryPlanner.photoScopeInventoryVersion,PinPublicProductScope.currentSourceScopeQueryVersion,CompactProductQueryPlanner.calendarDefaultsVersion,CompactProductQueryPlanner.photoCalendarDefaultsVersion,CompactProductQueryPlanner.locationExtentVersion].contains(input.inventory.task.version) {
                    if input.details==nil {
                        context=displayed;answer=inventory
                        try record(["status":"RENDER_READY","inventoryReceipt":input.inventory.receipt.requestSHA256,"modelCalls":0,"sourceCalls":0,"imageCalls":0])
                        return
                    }
                    // A retained calendar publication can be the genuine parent of
                    // the additive location-extent contextual contract.
                    guard input.details?.task.version==CompactProductQueryPlanner.locationExtentVersion else{throw PinEvidenceError.staleRecord}
                }
                guard let request=input.details,case .contextual(let details)=try await prepare(owner,request,previous:displayed)else{throw PinEvidenceError.staleRecord}
                _=try await owner.readmitLinkedUnitContextualAnswer(details)
                context=displayed;answer=inventory;linked=PinLinkedUnitViewState(details)
                try record(["status":"RENDER_READY","inventoryReceipt":input.inventory.receipt.requestSHA256,"detailsReceipt":request.receipt.requestSHA256,"modelCalls":0,"sourceCalls":0,"imageCalls":0])
            }catch{message="Render control failed: "+String(describing:error)}
        }
        func open(_ unitID:String) {
            Task {
                do {
                    guard let cache,let context else{throw PinEvidenceError.staleRecord}
                    if let details=linked?.answer{_=try await cache.readmitLinkedUnitContextualAnswer(details)}
                    let selection=try await cache.selectDisplayedUnit(context,unitID:unitID)
                    for source in selection.sources{_=try await cache.readmitUnitSelection(selection,source:source)}
                    if let details=linked?.answer{_=try await cache.readmitLinkedUnitContextualAnswer(details)}
                    try record(["status":"EXACT_ORIGINAL_HANDOFF","memberIDs":selection.row.memberRecordIDs,"sourceIDs":selection.sources.map(\.id),"PhotoKitOpened":false])
                    handoff=true
                }catch{message="Original handoff failed: "+String(describing:error)}
            }
        }
        private func record(_ value:[String:Any])throws {
            let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("v36-render-audit")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:root.appendingPathComponent(UUID().uuidString+".json"),options:.atomic)
        }
    }
    @StateObject private var state=State()
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("Retained answer rendering control").font(.caption).foregroundStyle(Color.pinMuted)
                if let message=state.message{Text(message).accessibilityIdentifier("renderControlFailure")}
                else if state.handoff {
                    Text("Exact original handoff verified").accessibilityIdentifier("renderOriginalHandoff")
                    Text("This rendering control does not open PhotoKit.")
                    Button("Return to details"){state.handoff=false}.accessibilityIdentifier("renderReturn")
                }else if let answer=state.answer {
                    UnitAppointmentResult(result:answer,appointments:state.appointments,originals:state.memories,working:false,notice:nil,evidence:nil,open:state.open,linked:state.linked?.answer)
                }else{ProgressView("Preparing retained native answer…")}
            }.padding(24)
        }.background(Color.pinBackground).task{await state.load()}
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
/// Offline app integration control. Replays immutable completed transport
/// responses through the real SDK compiler and native transaction owner.
/// This is neither fresh inference nor ordinary PhotoKit intake qualification.
struct PinStageRecoveryRenderControl: View {
    static var enabled: Bool {
        Bundle.main.bundleIdentifier == "app.pin.stagerecoverycontrol" &&
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--test-stage-recovery=") }
    }
    @StateObject private var state = State()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Saved reading recovery").font(.largeTitle.bold())
                Text("Offline recorded-response control. No new model requests.").foregroundStyle(Color.pinMuted)
                Text(state.message).accessibilityIdentifier("stageRecoveryStatus")
                if state.phase == "interrupted" {
                    Text("Reading interrupted. Completed responses are saved; no new appointment was published.")
                        .accessibilityIdentifier("stageRecoveryPending")
                }
                if state.phase == "committed" || state.phase == "cold" {
                    Text("Recovered saved reading").font(.title2.bold()).accessibilityIdentifier("stageRecoveryResult")
                    ForEach(state.rows) { row in
                        AppointmentFacts(observation: row.observation, photoEvidenceOnly: true)
                            .padding().background(.white, in: RoundedRectangle(cornerRadius: 20))
                    }
                    Text(state.phase == "cold" ? "Reopened with saved records unchanged." : "Saved responses recovered without another request.")
                        .accessibilityIdentifier("stageRecoveryPersistence")
                }
                if state.phase == "failed" { Text("Recovery control failed").accessibilityIdentifier("stageRecoveryFailure") }
            }.padding(24)
        }.background(Color.pinBackground).task { await state.load() }
    }
    private struct Input: Decodable {
        let checkpoint: PinCompletedSourceCheckpoint
        let memories: Data
        let appointments: Data
        let configuration: Data
    }
    private struct Envelope: Decodable { let memory: PhotoMemory; let originalSHA256: String; let task: ChoiceTask }
    private struct Memories: Decodable { let memories: [PhotoMemory] }
    private struct Saved: Codable {
        var phase: String
        let allocated: [String]
        let before: [AppointmentItem]
        var committedSHA256: String?
    }
    @MainActor private final class State: ObservableObject {
        @Published var phase = "loading"
        @Published var message = "Checking saved reading"
        @Published var rows: [AppointmentItem] = []
        private var loaded = false
        private func require(_ condition: Bool, _ text: String) throws {
            if !condition { throw NSError(domain: "PinStageRecoveryControl", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        }
        private func hash(_ data: Data) -> String { ChoiceTask.hash(data) }
        private func write<T: Encodable>(_ value: T, to file: URL) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: file, options: .atomic)
        }
        func load() async {
            guard !loaded else { return }; loaded = true
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let root = docs.appendingPathComponent("stage-recovery-control")
            do {
                let prefix = "--test-stage-recovery="
                guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { throw PinDevelopmentError.sourceNotAllowed }
                let data = try Data(contentsOf: docs.appendingPathComponent("stage-recovery-input.json"))
                try require(data.count <= 2_097_152 && hash(data) == String(arg.dropFirst(prefix.count)), "Input digest mismatch")
                let input = try JSONDecoder().decode(Input.self, from: data)
                let packet = input.checkpoint
                let e = try JSONDecoder().decode(Envelope.self, from: packet.initial.originalEnvelope)
                let memories = try JSONDecoder().decode(Memories.self, from: input.memories).memories
                try require(memories.contains(e.memory), "Current source binding missing")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let file = root.appendingPathComponent("appointments.json"), marker = root.appendingPathComponent("state.json")
                let stages = PinSourceStageJournal.directory(in: root, transaction: packet.transactionID)
                if !FileManager.default.fileExists(atPath: file.path) {
                    try input.appointments.write(to: file, options: .withoutOverwriting)
                    try input.memories.write(to: root.appendingPathComponent("memories.json"), options: .withoutOverwriting)
                }
                try require(try Data(contentsOf: root.appendingPathComponent("memories.json")) == input.memories, "Source memories changed")
                let store = try AppointmentStore(file: file), permit = try await store.synchronize(memories)
                let current = await store.all()
                guard let status = await store.groupReplacementStatus(packet.transactionID) else { throw PinEvidenceError.staleRecord }
                let saved = FileManager.default.fileExists(atPath: marker.path) ? try JSONDecoder().decode(Saved.self, from: Data(contentsOf: marker)) : nil
                if let saved, saved.phase == "committed" {
                    try require(status.phase == .completed && status.allocatedRecordIDs == saved.allocated, "Completed transaction binding changed")
                    try require(hash(Data(contentsOf: file)) == saved.committedSHA256, "Cold native bytes changed")
                    try require(current.filter { $0.sourceID != e.memory.id } == saved.before, "Other native objects changed on reopen")
                    rows = current.filter { $0.sourceID == e.memory.id }
                    try require(rows.map(\.id) == saved.allocated, "Cold recovered IDs changed")
                    phase = "cold"; message = "Cold reopen verified"
                } else {
                    try require(status.phase == .sourceAdvanced, "Expected interrupted source transaction")
                    let before = saved?.before ?? current
                    try require(current == before, "Interrupted operation published records")
                    try require(status.allocatedRecordIDs.count == 1, "Captured transaction allocation changed")
                    if saved == nil {
                        let recording = try PinSourceStageJournal(directory: stages, transaction: packet.transactionID, memory: e.memory, originalSHA256: e.originalSHA256, replayOnly: false)
                        let recorded = [packet.initial, packet.fields] + (packet.selectedValues.map { [$0] } ?? [])
                        for (index, stage) in recorded.enumerated() {
                            let envelope = try JSONDecoder().decode(Envelope.self, from: stage.originalEnvelope)
                            if index == recorded.count - 1 {
                                // Cancel the child at the completed-response boundary. The
                                // receipt must persist, but the caller must receive cancellation.
                                let child = Task {
                                    try await recording.receipt(envelope: stage.originalEnvelope, task: envelope.task, send: {
                                        withUnsafeCurrentTask { $0?.cancel() }
                                        return stage.receipt
                                    })
                                }
                                do { _ = try await child.value; try require(false, "Cancelled stage returned success") }
                                catch is CancellationError {}
                            } else {
                                _ = try await recording.receipt(envelope: stage.originalEnvelope, task: envelope.task, send: { stage.receipt })
                            }
                        }
                    }
                    let replay = try PinSourceStageJournal(directory: stages, transaction: packet.transactionID, memory: e.memory, originalSHA256: e.originalSHA256, replayOnly: true)
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let config = try decoder.decode(PinFreshProductConfiguration.self, from: input.configuration)
                    let transaction = try await store.resumeGroupReplacement(packet.transactionID, permit: permit)
                    let provider: @Sendable (PinSourceReplacementModelInput) async throws -> PinFreshProductProvider = { value in
                        try PinFreshProductProvider(config: config, memory: e.memory, originalSHA256: e.originalSHA256, recordID: value.ticket?.id, recordRevision: value.ticket?.nextRevision, groupContext: value.group, questionRequestID: UUID(), retainedGroupingInitialReceipt: value.retainedGroupingInitialReceipt, sourceStages: replay, check: {})
                    }
                    if saved == nil {
                        do {
                            _ = try await PinWholeSourceReplacement.resumeRecordedStages(memory: e.memory, originalSHA256: e.originalSHA256, transaction: transaction, stages: replay, store: store, permit: permit, selectedSourceValues: config.selectedSourceValues == true, provider: provider, check: {}, checkpoint: { _ in throw CancellationError() })
                            try require(false, "Proof interruption did not stop commit")
                        } catch is CancellationError {}
                        let unchanged = await store.all(), pending = await store.groupReplacementStatus(packet.transactionID)
                        try require(unchanged == before && pending?.phase == .sourceAdvanced && pending?.allocatedRecordIDs == status.allocatedRecordIDs, "Interrupted commit changed native state")
                        try write(Saved(phase: "interrupted", allocated: status.allocatedRecordIDs, before: before), to: marker)
                        phase = "interrupted"; message = "Interrupted safely; completed responses retained"
                    } else {
                        let proofFile = root.appendingPathComponent("proof.json")
                        _ = try await PinWholeSourceReplacement.resumeRecordedStages(memory: e.memory, originalSHA256: e.originalSHA256, transaction: transaction, stages: replay, store: store, permit: permit, selectedSourceValues: config.selectedSourceValues == true, provider: provider, check: {}, checkpoint: { proof in
                            try JSONEncoder().encode(proof).write(to: proofFile, options: .atomic)
                        })
                        let after = await store.all(), finished = await store.groupReplacementStatus(packet.transactionID)
                        rows = after.filter { $0.sourceID == e.memory.id }
                        try require(finished?.phase == .completed && finished?.allocatedRecordIDs == status.allocatedRecordIDs && rows.map(\.id) == status.allocatedRecordIDs && after.filter { $0.sourceID != e.memory.id } == before, "Atomic recovery or preservation failed")
                        try write(Saved(phase: "committed", allocated: status.allocatedRecordIDs, before: before, committedSHA256: hash(Data(contentsOf: file))), to: marker)
                        phase = "committed"; message = "Recovered from recorded responses"
                    }
                }
                let names = try FileManager.default.contentsOfDirectory(atPath: stages.path)
                let audit: [String: String] = ["phase": phase, "newModelCalls": "0", "transportMode": "replayOnly", "inputSHA256": hash(data), "nativeSHA256": try hash(Data(contentsOf: file)), "completedReceiptFiles": String(names.filter { $0.hasSuffix(".receipt.json") }.count), "sourceID": e.memory.id, "sourceRevision": String(e.memory.revision), "recordTitles": rows.map { $0.observation.title }.joined(separator: " | ")]
                try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys]).write(to: root.appendingPathComponent("audit-" + phase + ".json"), options: .atomic)
            } catch {
                phase = "failed"; message = String(describing: error)
                try? Data(message.utf8).write(to: root.appendingPathComponent("FAILURE.txt"))
            }
        }
    }
}
#endif
