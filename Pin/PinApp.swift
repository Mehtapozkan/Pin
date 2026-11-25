import PinCore
import PinMemory
import IBrainSemantics
import struct IBrain.MemoryScope
import struct IBrain.SourceReference
import IBrainRetrieval
import SwiftUI
import Photos
import PhotosUI
import MapKit

extension Color {
    static let pinBackground = Color(red: 1, green: 0.96, blue: 0.98)
    static let pinSurface = Color(red: 1, green: 0.985, blue: 0.99)
    static let pinInk = Color(red: 0.13, green: 0.09, blue: 0.15)
    static let pinRose = Color(red: 0.73, green: 0.22, blue: 0.40)
    static let pinMuted = Color(red: 0.48, green: 0.42, blue: 0.47)
}

extension View {
    func pinAnswerSurface(radius: CGFloat = 24) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Color.pinSurface.opacity(0.94), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.88)).allowsHitTesting(false) }
            .shadow(color: Color.pinRose.opacity(0.07), radius: 14, x: 0, y: 5)
    }
}

private struct PinRoseBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 1, green: 0.975, blue: 0.984), .pinBackground,
                     Color(red: 0.99, green: 0.92, blue: 0.95)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            RadialGradient(colors: [.white.opacity(0.78), .clear], center: .topTrailing,
                           startRadius: 20, endRadius: 370)
        }
        .ignoresSafeArea()
    }
}

@main
struct PinApp: App {
    private let library: PhotoLibrary?
    private let background: PhotoIndexBackground?
    @StateObject private var appointments: AppointmentCoordinator
    init() {
        #if DEBUG && targetEnvironment(simulator)
        if PinSavedAnnotationRenderControl.enabled {
            _appointments = StateObject(wrappedValue: AppointmentCoordinator(connectionProbeOnly: true))
            library = nil; background = nil
            return
        }
        if PinStageRecoveryRenderControl.enabled {
            _appointments = StateObject(wrappedValue: AppointmentCoordinator(connectionProbeOnly: true))
            library = nil; background = nil
            return
        }
        #endif
        #if DEBUG && !targetEnvironment(simulator)
        if PinFreshConnectionControl.id != nil {
            _appointments = StateObject(wrappedValue: AppointmentCoordinator(connectionProbeOnly: true))
            library = nil
            background = nil
            return
        }
        #endif
        _appointments = StateObject(wrappedValue: AppointmentCoordinator())
        let store = Result {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return try MemoryStore(file: PinPublicProductScope.applicationDirectory(directory).appendingPathComponent("memories-v1.json"))
        }
        let library = try? store.get().mapLibrary()
        self.library = library
        self.background = PhotoIndexBackground(library: library)
    }
    var body: some Scene {
        WindowGroup { launchContent }
    }
    // Keep the large stateful home value out of the scene builder's nested
    // conditional values. The physical main-thread stack is smaller than the
    // Simulator's; a concrete nested root copied PinHome during initialization.
    private var launchContent: AnyView {
        #if DEBUG && !targetEnvironment(simulator)
        if let id = PinFreshConnectionControl.id { return AnyView(PinFreshConnectionControl(id: id)) }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if PinSavedAnnotationRenderControl.enabled {return AnyView(PinSavedAnnotationRenderControl())}
        if PinStageRecoveryRenderControl.enabled {return AnyView(PinStageRecoveryRenderControl())}
        if PinOriginalNavigationControl.enabled,let library {return AnyView(PinOriginalNavigationControl(library:library))}
        if PinFreshLocalSourceChangeControl.enabled {return AnyView(PinFreshLocalSourceChangeControl())}
        if PinLinkedUnitRenderControl.enabled {return AnyView(PinLinkedUnitRenderControl())}
        #endif
        if PinFreshNativeFramePreparation.enabled {
            return AnyView(Text("Preparing public photo frames").task{PinFreshNativeFramePreparation.run()})
        }
        if PinFreshRetainedTransportControl.enabled {
            return AnyView(Text("Checking saved result delivery").task{await PinFreshRetainedTransportControl.run()})
        }
        if let library, let background {
            return AnyView(PinHome(library: library, appointments: appointments, background: background).preferredColorScheme(.light))
        }
        return AnyView(ContentUnavailableView("Pin couldn't open its memory", systemImage: "externaldrive.badge.exclamationmark", description: Text("Your data has not been reset. Close Pin and try again.")))
    }
}

#if DEBUG && !targetEnvironment(simulator)
private struct PinFreshConnectionControl: View {
    static var id: UUID? {
        guard PinPublicProductScope.usesExistingPhotoIntake else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--fresh-network-probe"),
              arguments.indices.contains(flag + 1) else { return nil }
        return UUID(uuidString: arguments[flag + 1])
    }

    let id: UUID
    @Environment(\.scenePhase) private var phase
    @State private var attempted = false
    @State private var status = "Waiting for Pin Fresh Test to come to the foreground"

    var body: some View {
        Text(status).padding().task(id: phase) {
            guard phase == .active, UIApplication.shared.applicationState == .active, !attempted else { return }
            attempted = true
            do {
                try await PinFreshProductProvider.runConnectionProbe(id: id)
                try Task.checkCancellation()
                status = "Paired Mac reached"
            } catch is CancellationError {
                status = "Connection check interrupted"
            } catch {
                status = "Couldn’t reach the paired Mac"
            }
        }
    }
}
#endif

/// The sheet item carries its navigation affordance atomically with the photo.
/// Reading companion @State only inside a sheet builder can capture the prior
/// presentation on its first asynchronous open.
struct PinOriginalPhotoPresentation:Identifiable {
    let memory:PhotoMemory
    let hasNext:Bool
    var id:String{memory.id}
}

#if DEBUG && targetEnvironment(simulator)
/// Local presentation regression only. No semantic provider, receipt admission,
/// fixture import or persisted appointment changes. Uses current PhotoKit sources.
struct PinOriginalNavigationControl:View {
    static var enabled:Bool{Bundle.main.bundleIdentifier=="app.pin.intakecandidate" && ProcessInfo.processInfo.arguments.contains("--test-original-navigation-atomic")}
    @ObservedObject var library:PhotoLibrary
    @State private var presented:PinOriginalPhotoPresentation?
    @State private var sources:[PhotoMemory]=[]
    @State private var position=0
    @State private var advancing=false
    @State private var message="Checking current originals"
    @State private var opened:[String]=[]
    var body:some View {
        VStack {
            Text(message).accessibilityIdentifier("navigationControlStatus")
            Button("Open current originals") {Task{await open(position:0)}}.accessibilityIdentifier("navigationControlOpen")
                .disabled(!library.accessReady)
        }
        .task {await library.connect()}
        .sheet(item:$presented,onDismiss:{
            if advancing {advancing=false;Task{await open(position:position+1)}}
            else{message="Returned to the same source set";save()}
        }) { presentation in
            NavigationStack {
                LibraryPhoto(id:presentation.memory.id,full:true).scaledToFit()
                    .navigationTitle("Original photo")
                    .toolbar {ToolbarItem(placement:.confirmationAction){
                        if presentation.hasNext {Button("Next original"){advancing=true;presented=nil}.accessibilityIdentifier("originalNext")}
                        else {Button("Done"){presented=nil}}
                    }}
            }
        }
    }
    private func open(position next:Int)async {
        do {
            let ids=["0FA9840F-5C4C-43EC-9DA9-85076EB135FD/L0/001","30E7D5DA-940C-4C95-8887-8C336E93C068/L0/001"]
            guard library.authorized,library.accessReady,UIApplication.shared.applicationState == .active else{throw PinStoreError.staleResult}
            let current=try ids.map {id in guard let m=library.memories.first(where:{$0.id==id})else{throw PinStoreError.staleResult};return m}
            for m in current {guard try await library.store.current(RecallHit(memory:m,score:0))==m,PhotoLibrary.currentFingerprint(for:m.id)==m.fingerprint else{throw PinStoreError.staleResult}}
            guard current.indices.contains(next),sources.isEmpty || sources==current else{throw PinStoreError.staleResult}
            sources=current;position=next;opened.append(current[next].id)
            // Same atomic item as the production sheet, after asynchronous reads.
            presented=PinOriginalPhotoPresentation(memory:current[next],hasNext:next+1<current.count)
            message="Opening current original \(next+1)";save()
        }catch {message="Current original check failed";save()}
    }
    private func save(){
        let value:[String:Any]=["mode":"local presentation control; not semantic answer admission","status":message,"openedSourceIDs":opened,"modelCalls":0]
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:docs.appendingPathComponent("original-navigation-control.json"),options:.atomic)
    }
}
#endif

struct PinHome: View {
    @ObservedObject private var library: PhotoLibrary
    private let background: PhotoIndexBackground
    @StateObject private var voice = VoiceInput()
    @ObservedObject private var appointments: AppointmentCoordinator
    @State private var appointmentOriginal: PinOriginalPhotoPresentation?
    @State private var ticketCodes: [CheckInCodeEvidence] = []
    @State private var forgetAfterOriginal: PhotoMemory?
    @State private var ownerCorrectionTarget:PinOwnerCorrectionTarget?
    @State private var correctedPresentation:PinOwnerCorrectionTarget?
    @State private var savedQuestionVisible = false
    @State private var savedAnswer:PinSavedContentAnswer?
    @State private var savedContext:PinSavedContentContext?
    @State private var savedCards:[SavedScreenshotCard]=[]
    @State private var savedSources:[String:PhotoMemory]=[:]
    @State private var savedCorrection:SavedScreenshotCorrectionTarget?
    @State private var savedOriginalSequence:[(answer:PinSavedContentAnswer,recordID:String,position:Int)]=[]
    @State private var savedPlaceDisplay: SavedPlaceDisplay?
    @State private var placeQuestionVisible = false
    @State private var personPlans: PinPersonPlans.Answer?
    @State private var personPlansVisible = false
    @State private var personPlanCorrection: PersonPlanCorrectionTarget?
    @State private var itinerary: RailItinerary?
    @State private var itineraryWork: Task<Void, Never>?
    @State private var itineraryDecision: NativItinerary.Decision?
    @State private var visits: PinVisitReconstruction.Answer?
    @State private var visitsVisible = false
    #if canImport(FoundationModels)
    @State private var localPlaceReader: PinLocalSavedPlaceReader?
    #endif
    @State private var placeOriginals: [SourceReference] = []
    @State private var placeCorrection: SavedPlaceCorrectionTarget?
    @State private var homeRevision = 0
    @AppStorage("Pin.questionDraft") private var query = ""
    @State private var searched = false
    @State private var submittedQuery = ""
    @State private var searchEpoch = 0
    @State private var unitAnswer:PinUnitQuestionAnswer?
    @State private var unitContext:PinDisplayedUnitContext?
    @State private var unitEvidenceAnswer:PinUnitContextualAnswer?
    @State private var linkedUnitAnswer:PinLinkedUnitViewState?
    @State private var remainingUnitOriginals:[PinUnitQuestionSelection]=[]
    @State private var unitOriginalSelection:PinUnitQuestionSelection?
    @State private var unitOriginalPosition=0
    @State private var exhaustiveAnswer:PinExhaustiveQuestionAnswer?
    @State private var exhaustivePresentationContext:PinRecordQuestionContext?
    @State private var semanticEnabled = false
    @State private var semanticChoiceMade = false
    @State private var showSemanticConsent = false
    @State private var semanticWorking = false
    @State private var foregroundRequestLease = PinForegroundRequestLease()
    @State private var semanticUpdating = false
    @State private var semanticAnswerUpdate: AppointmentAnswerUpdate?
    @State private var showAppointmentUpdate = false
    @State private var semanticNotice: String?
    @State private var semanticPlan: MemoryQueryPlan?
    @State private var semanticScope: AppointmentScopeClarification?
    @State private var semanticScopeMeaning: MemoryQueryMeaning?
    @State private var semanticSnapshot: SemanticAppointmentSnapshot?
    @State private var clockResult: ClockResult?
    @State private var clockNotice: String?
    @State private var clockPending: (question: String, parent: [AppointmentItem])?
    @State private var clockPosition: Int?
    @State private var semanticContext: AppointmentConversationContext?
    @State private var recordQuestionContext:PinRecordQuestionContext?
    @State private var productPublishedParent:PinProductPublishedParent?
    @State private var recordChangeFields:[String:Set<String>]?
    @State private var semanticContextPeriod: String?
    @State private var semanticContextQuestion: String?
    @State private var semanticWork: Task<Void,Never>?
    @State private var semanticRequestID=UUID()
    @State private var semanticPendingQuestion: String?
    @State private var pendingNativeSubmission:(question:String,now:Date,calendar:Calendar)?
    @State private var pendingSubmissionTimingID:UUID?
    @State private var freshContinuation=PinQuestionContinuation<UUID>()
    @AppStorage("Pin.interruptedQuestionDraft") private var interruptedQuestionDraft=""

    @State private var photoQueryPlan: PhotoQueryPlan?
    @State private var photoQueryResult: PhotoQueryResult?
    @State private var hits: [RecallHit] = []
    @State private var selection: String?
    @State private var showSettings = false
    @State private var originalViewRequest:PinOriginalViewRequest?
    @State private var originalViewSequence:AppointmentOriginalSequence?
    @State private var originalViewRequestID=UUID()
    @State private var originalViewWork:Task<Void,Never>?
    @State private var originalViewNotice:String?
    @State private var pendingNextOriginal=false
    @State private var showOriginal = false
    @State private var showForget = false
    @State private var forgetTarget: PhotoMemory?
    @State private var message: String?
    @Environment(\.scenePhase) private var phase
    @FocusState private var inputFocused: Bool

    init(library: PhotoLibrary, appointments: AppointmentCoordinator, background: PhotoIndexBackground) {
        self.library = library; self.appointments = appointments; self.background = background
    }
    private var selected: PhotoMemory? { hits.first(where: { $0.id == selection })?.memory ?? hits.first?.memory }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal,22).padding(.top,12).padding(.bottom,8)
            if SemanticQueryLab.replaysRetainedResponses {
                Text("Recorded test answers · no live model")
                    .font(.caption).foregroundStyle(Color.pinMuted)
                    .accessibilityIdentifier("semanticReplayNotice")
            }
            if SemanticSourceReplay.enabled {
                Text(SemanticSourceReplay.isLive
                     ? "Fictional source test · Mac interpreter for new readings"
                     : "Recorded fictional source test · no live model")
                    .font(.caption).foregroundStyle(Color.pinMuted)
                    .accessibilityIdentifier("semanticSourceReplayNotice")
            }
            if PinPublicProductScope.usesExistingPhotoIntake {
                Text("Answers use only the photos approved for this test. Other photo readings stay on this device.")
                    .font(.caption).foregroundStyle(Color.pinMuted)
                    .accessibilityIdentifier("nativeProcessingScopeNotice")
            }
            if AppointmentCoordinator.usesDevelopmentSourceReader || AppointmentCoordinator.usesDevelopmentQuestions {
                Text(AppointmentCoordinator.usesDevelopmentQuestions ? "Fictional photo questions · paired Mac interpreter":"Fictional photo understanding · paired Mac interpreter").font(.caption).foregroundStyle(Color.pinMuted)
                    .accessibilityIdentifier("canonicalLiveNotice")
            }
            if AppointmentCoordinator.usesRecordedAppointments {
                Text("Authored appointment test · no live model").font(.caption).foregroundStyle(Color.pinMuted)
                    .accessibilityIdentifier("canonicalRecordedNotice")
            }
            if SavedPlacesDevelopmentControl.enabled {
                Text("Authored saved places test").font(.caption).foregroundStyle(Color.pinMuted)
            } else if SavedPlacesQualification.localReaderEnabled && !AppointmentCoordinator.usesCombinedSavedContent {
                Text("Saved places test · On-device reader").font(.caption).foregroundStyle(Color.pinMuted)
            } else if PeoplePlansQualification.enabled && !AppointmentCoordinator.usesCombinedSavedContent {
                Text("People’s plans test").font(.caption).foregroundStyle(Color.pinMuted)
            }
            ScrollViewReader { scroll in
            ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                primaryAnswer
                if let notice=originalViewNotice,library.authorized,library.accessReady,searched {
                    Text(notice).font(.subheadline).foregroundStyle(Color.pinMuted)
                        .accessibilityIdentifier("originalViewNotice")
                }
                if library.authorized && library.accessReady && searched { readingCoverage }
            }
            .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 28).id("pageStart")
            }
            .onChange(of: homeRevision) { _, _ in scroll.scrollTo("pageStart", anchor:.top) }
            .onChange(of: submittedQuery) { _, _ in scroll.scrollTo("pageStart", anchor:.top) }
            }
        }
        .background { PinRoseBackdrop() }.foregroundStyle(Color.pinInk)
        .safeAreaInset(edge: .bottom) { if library.authorized { questionDock } }
        .task {
            restoreInterruptedQuestionDraft()
            await BackgroundAudit.storageProbe()
            // The isolated replay requests PhotoKit permission at launch;
            // iOS may still show its normal consent sheet. The ordinary app
            // continues to wait for its Allow tap.
            await library.connect(requestPermission: SemanticSourceReplay.enabled || AppointmentCoordinator.usesRecordedAppointments)
            if !library.authorized { appointments.synchronize([], photoStore: library.store) }
        }
        .task(id: ticketEvidenceTaskID) { await readTicketCodes() }
        .onChange(of: appointments.notificationContext) { _, _ in openNotificationCard() }
        .onChange(of: library.authorized) { _, allowed in
            if !allowed {
                #if canImport(FoundationModels)
                localPlaceReader = nil
                #endif
                ownerCorrectionTarget=nil;correctedPresentation=nil
                searchEpoch += 1;resetSemantic();searched=false;hits=[];selection=nil
                appointmentOriginal=nil;showOriginal=false;appointments.synchronize([], photoStore: library.store)
                ticketCodes=[]
            }
        }
        .sheet(item:$ownerCorrectionTarget) { target in
            PinOwnerCorrectionSheet(target:target,save:{edit in try await appointments.correct(target.item,with:edit,library:library)},didSave:{item,current in
                clearUnitDisplay();productPublishedParent=nil;recordQuestionContext=nil;exhaustiveAnswer=nil
                correctedPresentation=current ? PinOwnerCorrectionTarget(item):nil
                semanticNotice=current ? nil:"Your correction was saved. Reopen the details to check current photo access."
            })
        }
        .sheet(item:$savedCorrection) { target in
            SavedScreenshotCorrectionSheet(title:target.title,initialText:target.expected?.correction ?? "",save:{text in
                try await appointments.saveInterpretation(text,source:target.source,expected:target.expected,library:library)
            },didSave:{result in
                clearSavedDisplay()
                switch result {
                case .ready: semanticNotice="Correction saved. Ask again to use your current interpretation."
                case .preparationPending: semanticNotice="Correction saved. Pin will prepare your updated interpretation when you ask again."
                }
            })
        }
        .sheet(item: $personPlanCorrection) { target in
            PersonPlanCorrectionSheet(target: target, save: { field, value in
                try await savePersonPlanCorrection(target, field: field, value: value)
            })
        }
        .sheet(item: $placeCorrection) { target in
            SavedPlaceCorrectionSheet(target: target, save: savePlaceCorrection)
        }
        .sheet(item: $appointmentOriginal, onDismiss: originalDismissed, content: originalSheet)
        .onChange(of: phase) { _, next in
            updateForegroundRequestLease(active:next == .active)
            if next == .active {
                restoreInterruptedQuestionDraft()
                // Keep the object and question; changed access is reconciled
                // before results become visible again.
                searchEpoch += 1
                Task {
                    await library.connect()
                    // connect starts an asynchronous catalogue reconciliation.
                    // An initial empty array is not confirmed source withdrawal.
                    if library.accessReady {
                        appointments.synchronize(library.memories, photoStore: library.store)
                        reconcileOriginalViews()
                        openNotificationCard()
                    }
                }
            } else {
                if originalViewWork != nil {cancelOriginalViews()}
                if next == .background { voice.cancel() }
                if semanticWorking || freshContinuation.waitingForAccess != nil {
                    if AppointmentCoordinator.usesSavedContent || savedQuestionVisible {savedContext=nil}
                    preserveQueuedQuestionDraft()
                    let wasPreparingPhotos=appointments.freshQuestionPhase == .preparingPhotos
                    searchEpoch += 1;cancelSemanticWork(preservingContinuation:true);semanticWorking=false
                    semanticNotice=wasPreparingPhotos ? "Photo reading was interrupted. Your photos and completed readings are kept.":"Question interpretation was interrupted. Ask again when you’re ready."
                }
                if next == .background { appointments.pauseForBackground(); background.didEnterBackground() }
            }
        }
        .onChange(of: semanticWorking) { _, _ in updateForegroundRequestLease(active:phase == .active) }
        .onChange(of: semanticRequestID) { _, _ in updateForegroundRequestLease(active:phase == .active) }
        .onDisappear { updateForegroundRequestLease(active:false) }
        .onChange(of: appointments.running) { _,running in
            if !running,(AppointmentCoordinator.usesDevelopmentSourceReader || AppointmentCoordinator.usesDevelopmentQuestions),let pending=semanticPendingQuestion,
               library.accessReady,phase == .active {semanticWorking=false;search(submittedQuestion:pending)}
        }
        .onChange(of: appointments.items) { _, _ in
            reconcileClockSearch()
            if let corrected=correctedPresentation,!appointments.items.contains(corrected.item){correctedPresentation=nil}
            if let answer=unitAnswer,!answer.rows.flatMap(\.members).allSatisfy({appointments.items.contains($0.item)}){clearUnitDisplay();cancelOriginalViews(close:true)}
            reconcileOriginalViews()
        }
        .onChange(of: library.memories) { _, _ in
            if let current = itinerary, !current.needsModel { itinerary = RailItinerary.answer(submittedQuery, photos: library.memories, decision: itineraryDecision) }
            reconcileSavedDisplay()
            reconcilePlaceDisplay()
            if let visits, !visits.photoInventory.matches(library.memories) {
                self.visits = nil
                semanticNotice = "The supporting photos changed. Ask again to check the current photos."
            }
            if let personPlans, !personPlans.photoInventory.matches(library.memories) {
                self.personPlans = nil
                personPlanCorrection = nil
                semanticNotice = "The supporting photos changed. Ask again to check the current photos."
            }
            if let corrected=correctedPresentation,!corrected.item.allSources.allSatisfy({source in library.memories.contains{AppointmentSource($0)==source}}){correctedPresentation=nil;ownerCorrectionTarget=nil}
            clearUnitDisplay();cancelOriginalViews(close:true)
            exhaustiveAnswer=nil
            if PinFreshProductConfiguration.enabled{recordQuestionContext=nil;productPublishedParent=nil}
            if library.accessReady { reconcilePresentedSources(onlyOriginals:true) }
            if library.accessReady && phase == .active { appointments.synchronize(library.memories, photoStore: library.store) }
            if library.accessReady && searched && !inputFocused && !submittedQuery.isEmpty { refreshResults(for: submittedQuery) }
        }
        .onChange(of: library.accessReady) { _, ready in
            if !ready {itinerary=nil;clearSavedDisplay();clearPlaceDisplay();personPlans=nil;personPlanCorrection=nil;visits=nil}
            if !ready{cancelSemanticWork();semanticWorking=false;clearUnitDisplay();cancelOriginalViews(close:true);exhaustiveAnswer=nil;if PinFreshProductConfiguration.enabled{recordQuestionContext=nil;productPublishedParent=nil}}
            if ready { reconcilePresentedSources() } else { PinQuestionTiming.mark(semanticRequestID,"ui.accessInvalidated");searchEpoch += 1 }
            if ready && phase == .active { appointments.synchronize(library.memories, photoStore: library.store); openNotificationCard() }
            if ready && freshContinuation.waitingForAccess != nil { resumeFreshQuestionAfterAccess() }
            else if ready && !inputFocused && !submittedQuery.isEmpty { refreshResults(for: submittedQuery) }
        }
        .onChange(of: library.indexing) { _, reading in
            if !reading,freshContinuation.waitingForAccess != nil {
                resumeFreshQuestionAfterAccess()
            }
        }
        .sheet(isPresented: $showSettings) { settings }
        .sheet(isPresented: $showOriginal) {
            if let selected {
                NavigationStack {
                    Group {
                        if library.accessReady { LibraryPhoto(id: selected.id, full: true).scaledToFit().clipped() }
                        else { ProgressView("Checking photo access…") }
                    }.background(Color.pinBackground)
                        .navigationTitle("Original photo").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showOriginal = false } } }
                }
            }
        }
        .alert(SemanticQueryLab.consentTitle, isPresented:$showSemanticConsent) {
            Button(SemanticQueryLab.consentAction) { semanticChoiceMade=true;semanticEnabled=true;search(submittedQuestion:submittedQuery) }
            Button("Keep search local",role:.cancel) { semanticChoiceMade=true;semanticEnabled=false;search(submittedQuestion:submittedQuery) }
        } message: {
            Text(SemanticQueryLab.privacyDescription)
        }
        .onChange(of:semanticEnabled) { _,enabled in
            semanticChoiceMade=true
            if !enabled { searchEpoch += 1;resetSemantic();searched=false;hits=[];selection=nil }
        }
        .confirmationDialog("Forget this photo in Pin?", isPresented: $showForget, titleVisibility: .visible) {
            Button("Forget photo", role: .destructive) { forgetConfirmedSource() }
        } message: { Text("Pin removes its observations and stops using this photo in recall. The original stays in your Photos library.") }
        .alert("Pin", isPresented: Binding(get: { message != nil || library.error != nil }, set: { if !$0 { message = nil; library.error = nil } })) {
            Button("OK", role: .cancel) { message = nil; library.error = nil }
        } message: { Text(message ?? library.error ?? "") }
    }

    private func originalDismissed() {
            if PinFreshProductConfiguration.enabled,forgetAfterOriginal==nil,!pendingNextOriginal,phase == .active,let parent=productPublishedParent {
                PinFreshProductAudit.recordNavigation(stage:"originalReturned",parent:parent)
            }
            if let memory=forgetAfterOriginal {
                cancelOriginalViews();forgetAfterOriginal=nil;requestForget(memory)
            }else if pendingNextOriginal, let position = clockPosition {
                pendingNextOriginal=false; openClockPhoto(at:position+1)
            }else if pendingNextOriginal,!placeOriginals.isEmpty {
                pendingNextOriginal=false;presentNextPlaceOriginal()
            }else if pendingNextOriginal,!savedOriginalSequence.isEmpty {
                pendingNextOriginal=false;presentNextSavedOriginal()
            }else if pendingNextOriginal,let selection=unitOriginalSelection {
                pendingNextOriginal=false
                if unitOriginalPosition+1<selection.sources.count {presentUnitOriginal(selection,position:unitOriginalPosition+1)}
                else if !remainingUnitOriginals.isEmpty {let next=remainingUnitOriginals.removeFirst();presentUnitOriginal(next,position:0)}
            }else if pendingNextOriginal,let request=originalViewRequest {
                pendingNextOriginal=false;presentOriginalView(request,advancing:true)
            }else{cancelOriginalViews()}
    }

    private func originalSheet(_ presentation: PinOriginalPhotoPresentation) -> some View {
            let memory=presentation.memory
            return NavigationStack {
                Group {
                    if library.accessReady { LibraryPhoto(id: memory.id, full: true).scaledToFit() }
                    else { ProgressView("Checking photo access…") }
                }.background(Color.pinBackground)
                    .safeAreaInset(edge:.bottom) {
                        Button("Forget this photo in Pin",role:.destructive) {
                            cancelOriginalViews();forgetAfterOriginal=memory;appointmentOriginal=nil
                        }.font(.subheadline).padding()
                            .accessibilityIdentifier("originalForget")
                    }
                    .navigationTitle("Original photo").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        if presentation.hasNext {
                            Button("Next original") { pendingNextOriginal=true;appointmentOriginal=nil }
                                .accessibilityIdentifier("originalNext")
                        }else{Button("Done") { cancelOriginalViews();appointmentOriginal=nil }}
                    } }
            }.tint(Color.pinRose)
    }

    private func reconcilePresentedSources(onlyOriginals:Bool=false) {
        reconcileClockSearch()
        reconcileOriginalViews()
        if onlyOriginals && !showOriginal && appointmentOriginal == nil { return }
        let originals=(showOriginal ? selected.map { [$0] } ?? [] : []) + (appointmentOriginal.map { [$0.memory] } ?? [])
        let checked=onlyOriginals ? originals : hits.map(\.memory) + originals
        guard !checked.isEmpty else { return }
        let native=PhotoLibrary.currentFingerprints(for:checked.map(\.id))
        let known=Dictionary(uniqueKeysWithValues:library.memories.map { ($0.id,$0) })
        func visible(_ memory:PhotoMemory) -> Bool {
            known[memory.id]?.fingerprint == memory.fingerprint && known[memory.id]?.revision == memory.revision
                && native[memory.id] == memory.fingerprint
        }
        if let original=selected, showOriginal && !visible(original) { showOriginal=false }
        if let original=appointmentOriginal, !visible(original.memory) { appointmentOriginal=nil }
        if !onlyOriginals {
            hits.removeAll { !visible($0.memory) }
            if !hits.contains(where:{ $0.id == selection }) { selection=hits.first?.id }
        }
    }

    private func cancelOriginalViews(close:Bool=false,clearNotice:Bool=false) {
        originalViewWork?.cancel();originalViewWork=nil
        savedOriginalSequence=[]
        placeOriginals=[]
        originalViewRequest=nil;originalViewSequence=nil;unitOriginalSelection=nil;unitOriginalPosition=0;pendingNextOriginal=false;remainingUnitOriginals=[]
        originalViewRequestID=UUID()
        if close {appointmentOriginal=nil}
        if clearNotice {originalViewNotice=nil}
    }
    private func originalViewMessage(_ issue:OriginalViewIssue)->String {
        switch issue {
        case .noEarlierOriginal:return "I couldn’t find an earlier original for that entry."
        case .ambiguousTarget:return "Which appointment’s original photos should I open?"
        case .missingContext:return "Ask about an appointment first so I know which originals you mean."
        case .unresolvedTarget:return "I couldn’t confirm every requested original from the available evidence."
        case .unsupportedRequest,.unsupportedOperation:return "I can’t yet fulfill that original-photo request."
        }
    }
    private func originalViewAuthority(_ request:PinOriginalViewRequest)->AppointmentOriginalAuthority {
        AppointmentOriginalAuthority(activeAnswerID:recordQuestionContext?.answerID,
            activeRequestID:originalViewRequestID,authorized:library.authorized,
            accessReady:library.accessReady,foreground:phase == .active,
            items:appointments.items,originals:library.memories,
            nativeFingerprints:PhotoLibrary.currentFingerprints(for:request.supportingSources.map(\.id)))
    }
    private func invalidateForNativeDismiss() {
        searchEpoch += 1;cancelSemanticWork();semanticWorking=false
        cancelOriginalViews(close:true)
        semanticSnapshot=nil;semanticContext=nil;recordQuestionContext=nil;recordChangeFields=nil
        semanticNotice="The displayed appointment list changed. Ask again for current entries."
    }
    private func reconcileOriginalViews() {
        guard let request=originalViewRequest else{return}
        guard library.authorized else{cancelOriginalViews(close:true);return}
        // A normal foreground catalogue check temporarily hides the picture;
        // it is not explicit withdrawal and never advances the sequence.
        guard library.accessReady,phase == .active else{return}
        let authority=originalViewAuthority(request)
        let sequence=originalViewSequence ?? request.sequence(requestID:originalViewRequestID,context:recordQuestionContext,authority:authority)
        guard request.isBound(to:recordQuestionContext),sequence?.validatedMemory(in:authority) != nil else {
            cancelOriginalViews(close:true)
            originalViewNotice="Those originals changed or are no longer available. Ask again for the current sources."
            return
        }
    }
    private func presentOriginalView(_ request:PinOriginalViewRequest,advancing:Bool=false) {
        guard AppointmentCoordinator.usesOriginalViewDevelopmentQuestions,
              let context=recordQuestionContext,request.isBound(to:context),
              library.authorized,library.accessReady,phase == .active else{return}
        let nonce=originalViewRequestID,prior=originalViewSequence
        if advancing && prior?.hasNext != true {return}
        originalViewWork?.cancel();originalViewRequest=request;pendingNextOriginal=false
        originalViewWork=Task {
            do {
                let inspected=try await appointments.inspectRecordQuestion(request.item,context:context)
                guard !Task.isCancelled,nonce==originalViewRequestID,phase == .active,
                      library.authorized,library.accessReady,recordQuestionContext?.answerID==context.answerID,
                      request.isBound(to:inspected) else{throw CancellationError()}
                for source in request.supportingSources {
                    guard let memory=library.memories.first(where:{AppointmentSource($0)==source})else{throw PinEvidenceError.staleRecord}
                    _=try await library.store.current(RecallHit(memory:memory,score:0))
                    guard !Task.isCancelled,nonce==originalViewRequestID,phase == .active,
                          library.authorized,library.accessReady else{throw CancellationError()}
                }
                // Renew the SDK permit/inspection again AFTER actor reads. No
                // model call, fact write or reconstructed previous capture.
                let checked=try await appointments.inspectRecordQuestion(request.item,context:inspected)
                guard !Task.isCancelled,nonce==originalViewRequestID,phase == .active,
                      library.authorized,library.accessReady,recordQuestionContext?.answerID==context.answerID,
                      request.isBound(to:checked) else{throw CancellationError()}
                let authority=originalViewAuthority(request)
                let sequence=advancing ? prior?.advanced(in:authority):request.sequence(requestID:nonce,context:checked,authority:authority)
                guard let sequence,let memory=sequence.validatedMemory(in:authority)else{throw PinEvidenceError.staleRecord}
                recordQuestionContext=checked;originalViewSequence=sequence
                originalViewWork=nil;appointmentOriginal=PinOriginalPhotoPresentation(memory:memory,hasNext:sequence.hasNext)
            }catch is CancellationError {
                if nonce==originalViewRequestID {cancelOriginalViews()}
            }catch {
                guard nonce==originalViewRequestID else{return}
                cancelOriginalViews(close:true)
                originalViewNotice="I couldn’t open all of those originals. They may have changed or become unavailable."
            }
        }
    }

    private func showUnitOriginal(_ unitID:String) {
        guard let context=unitContext,!semanticWorking else{return}
        cancelOriginalViews();let epoch=searchEpoch,nonce=originalViewRequestID
        originalViewWork=Task {
            do {
                if let linked=linkedUnitAnswer?.answer{try await appointments.readmitLinkedUnitAnswer(linked,library:library)}
                let selection=try await appointments.selectUnit(unitID,context:context,library:library)
                guard !Task.isCancelled,epoch==searchEpoch,nonce==originalViewRequestID,unitContext?.id==context.id,phase == .active else{return}
                presentUnitOriginal(selection,position:0)
            }catch{if epoch==searchEpoch{message="This event’s original photos are no longer current or accessible."}}
        }
    }
    private func presentUnitOriginal(_ selection:PinUnitQuestionSelection,position:Int) {
        let nonce=originalViewRequestID,epoch=searchEpoch
        guard unitContext?.id==selection.contextID else{return}
        originalViewWork=Task {
            do {
                let memory=try await appointments.inspectUnitOriginal(selection,position:position,library:library,linked:linkedUnitAnswer?.answer)
                guard !Task.isCancelled,epoch==searchEpoch,nonce==originalViewRequestID,unitContext?.id==selection.contextID,phase == .active,library.accessReady else{return}
                unitOriginalSelection=selection;unitOriginalPosition=position;appointmentOriginal=PinOriginalPhotoPresentation(memory:memory,hasNext:position+1<selection.sources.count || !remainingUnitOriginals.isEmpty)
                if let parent=productPublishedParent{PinFreshProductAudit.recordNavigation(stage:"unitOriginalOpened",parent:parent,source:EvidenceSource(memory),answerID:unitContext?.answerRequestID)}
            }catch{if epoch==searchEpoch{cancelOriginalViews(close:true);message="This event’s original photos changed or are no longer accessible."}}
        }
    }
    private func showPhoto(_ memory: PhotoMemory) { showPhoto(memory, itineraryID: nil) }
    private func showPhoto(_ memory: PhotoMemory, itineraryID: UUID?) {
        cancelOriginalViews()
        let requestID = originalViewRequestID
        originalViewWork = Task {
            do {
                _ = try await library.store.current(RecallHit(memory: memory, score: 0))
                guard !Task.isCancelled, requestID == originalViewRequestID, phase == .active,
                      library.authorized, library.accessReady else { return }
                if let itineraryID, itinerary?.id != itineraryID { return }
                guard PhotoLibrary.currentFingerprint(for: memory.id) == memory.fingerprint else {
                    throw PinStoreError.staleResult
                }
                appointmentOriginal = PinOriginalPhotoPresentation(memory: memory, hasNext: false)
            } catch {
                if !Task.isCancelled && requestID == originalViewRequestID {
                    message = "This photo changed or is no longer accessible."
                }
            }
        }
    }
    private func showAppointmentPhoto(_ item: AppointmentItem) {
        cancelOriginalViews()
        if let answer=exhaustiveAnswer {
            let epoch=searchEpoch
            originalViewWork=Task {
                do {
                    let memory:PhotoMemory
                    if let context=exhaustivePresentationContext {
                        let selected=try await appointments.inspectRecordQuestion(item,context:context)
                        guard let original=library.memories.first(where:{AppointmentSource($0)==item.source})else{throw PinEvidenceError.staleRecord}
                        _=try await library.store.current(RecallHit(memory:original,score:0))
                        let checked=try await appointments.inspectRecordQuestion(item,context:selected)
                        guard !Task.isCancelled,epoch==searchEpoch,exhaustiveAnswer?.requestID==answer.requestID,phase == .active,library.accessReady else{return}
                        exhaustivePresentationContext=checked;recordQuestionContext=checked;memory=original
                    }else{memory=try await appointments.inspectFreshProductOriginal(item,answer:answer,library:library)}
                    guard !Task.isCancelled,epoch==searchEpoch,exhaustiveAnswer?.requestID==answer.requestID,
                          phase == .active,library.accessReady,PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{return}
                    if let context=recordQuestionContext {
                        let selected=try await appointments.inspectRecordQuestion(item,context:context)
                        guard !Task.isCancelled,epoch==searchEpoch,exhaustiveAnswer?.requestID==answer.requestID,phase == .active,library.accessReady else{return}
                        recordQuestionContext=selected;productPublishedParent=productPublishedParent?.selecting(selected.selectedOrdinal)
                    }
                    appointmentOriginal=PinOriginalPhotoPresentation(memory:memory,hasNext:false)
                    if let parent=productPublishedParent {PinFreshProductAudit.recordNavigation(stage:"originalOpened",parent:parent,source:EvidenceSource(memory),answerID:recordQuestionContext?.answerID)}
                }catch{if epoch==searchEpoch{message="This photo changed or is no longer accessible."}}
            }
            return
        }
        guard let memory = library.memories.first(where: { AppointmentSource($0) == item.source }) else { return }
        let answerID=semanticContext?.answerID
        let reviewOnly:Bool
        if recordQuestionContext==nil,case .list(let answer)=semanticSnapshot {reviewOnly=answer.uncertain.contains(item)}else{reviewOnly=false}
        guard answerID != nil || reviewOnly else{return}
        let epoch = searchEpoch
        Task {
            do {
                _ = try await library.store.current(RecallHit(memory: memory, score: 0))
                guard epoch == searchEpoch, phase == .active,library.authorized,library.accessReady,
                      PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{return}
                // A native unresolved card can be reviewed without fabricating
                // a dated-list ordinal or an SDK inspection grant. Discard any
                // older native selection so a later 'that' cannot name it.
                if reviewOnly {
                    guard appointments.items.contains(item),case .list(let answer)=semanticSnapshot,answer.uncertain.contains(item)else{return}
                    semanticContext=nil;appointmentOriginal=PinOriginalPhotoPresentation(memory:memory,hasNext:false);return
                }
                guard let answerID,var current=semanticContext,current.answerID==answerID else{return}
                guard library.authorized, library.accessReady,
                      PhotoLibrary.currentFingerprint(for: memory.id) == memory.fingerprint,
                      current.select(item, items: appointments.items, originals: library.memories) else {
                    message = "This appointment changed or is no longer accessible."; return
                }
                if AppointmentCoordinator.usesDevelopmentQuestions,let context=recordQuestionContext {
                    let selected=try await appointments.inspectRecordQuestion(item,context:context)
                    guard epoch==searchEpoch,phase == .active,library.authorized,library.accessReady,recordQuestionContext?.answerID==context.answerID,PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{return}
                    recordQuestionContext=selected
                    productPublishedParent=productPublishedParent?.selecting(selected.selectedOrdinal)
                }
                semanticContext = current
                appointmentOriginal = PinOriginalPhotoPresentation(memory:memory,hasNext:false)
            } catch { message = "This photo changed or is no longer accessible." }
        }
    }
    private func appointmentAnswer(_ question: String?) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            AppointmentCards(appointments: appointments, originals: library.memories, checkInCodes:ticketCodes,
                now: context.date, question: question, readingStatus: library.indexing ? library.status : nil, open: showPhoto,correct:requestOwnerCorrection)
        }
    }
    @ViewBuilder private func explicitAppointmentAnswer(_ request: AppointmentQuestion.ExplicitRequest) -> some View {
        switch request {
        case .appointments(let period, let selection):
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let answer = AppointmentAnswerEngine.answer(window: AppointmentWindow.resolve(period, now: context.date, calendar: .current),
                    selection: selection, items: appointments.items, originals: library.memories,
                    coverage: library.indexing ? .incomplete : .unknown)
                AppointmentCards(appointments: appointments, originals: library.memories, checkInCodes:ticketCodes, now: context.date,
                    readingStatus: library.indexing ? library.status : nil, answerOverride: answer, open: showPhoto,correct:requestOwnerCorrection)
            }
        case .unsupported:
            Text("I can’t answer every part of that appointment question from your photos yet. Try a day or week, or ask about all appointments.")
                .font(.title3.weight(.semibold))
        }
    }
    private var currentAppointments: [AppointmentItem] {
        AppointmentAnswerEngine.currentRecords(appointments.items,originals:library.memories)
    }
    private var ticketEvidenceTaskID: String {
        let keys=currentAppointments.filter { $0.observation.eventTicket == true }
            .map { "\($0.sourceID)|\($0.source.fingerprint)|\($0.source.revision)" }.sorted()
        return "\(phase == .active && library.authorized && library.accessReady)|\(keys.joined(separator:";"))"
    }
    private var repeatedRegistrations: [RegistrationEvidenceGroup] {
        RegistrationEvidenceGroups.make(items: currentAppointments, originals: library.memories, codes: ticketCodes)
            .filter { $0.members.count > 1 }
    }
    private func readTicketCodes() async {
        ticketCodes=[]
        guard phase == .active, library.authorized, library.accessReady else { return }
        let ids=Set(currentAppointments.filter { $0.observation.eventTicket == true }.map(\.sourceID))
        let sources=library.memories.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
        var found:[CheckInCodeEvidence]=[]
        for source in sources {
            guard !Task.isCancelled else { return }
            if let code=await PhotoLibrary.localCheckInCode(for:source) { found.append(code) }
        }
        guard !Task.isCancelled, phase == .active, library.authorized, library.accessReady,
              sources.allSatisfy({ source in
                  library.memories.contains(source) && PhotoLibrary.currentFingerprint(for:source.id) == source.fingerprint
              }) else { return }
        ticketCodes=found
    }
    private func showNativeAppointments(_ question: String, period: AppointmentPeriod, selection: AppointmentSelection, now:Date=Date(),calendar:Calendar = .current,preserveDraft:Bool=false) {
        guard library.authorized, library.accessReady else { return }
        // Exact recognized appointment requests need no model call. Keep the
        // displayed order and event IDs for source-bound follow-up references.
        searchEpoch += 1; resetSemantic()
        let window = AppointmentWindow.resolve(period, now: now, calendar: calendar)
        let answer = AppointmentAnswerEngine.answer(window: window,
            selection: selection, items: appointments.items, originals: library.memories,
            coverage: library.indexing ? .incomplete : .unknown)
        semanticSnapshot = .list(answer)
        semanticAnswerUpdate = AppointmentAnswerUpdate(
            plan: .appointments(window: window, selection: selection), answer: answer, now: now, calendar: calendar)
        semanticContext = AppointmentConversationContext(answerID: UUID(), answer: answer)
        semanticContextPeriod = period.rawValue; semanticContextQuestion = question
        if !preserveDraft {query = "";inputFocused = false}
        submittedQuery = question; hits = []; self.selection = nil; searched = true
    }
    private struct ClockResult {
        let parent: [AppointmentItem]
        let matches: [AppointmentItem]
        let originals: [PhotoMemory]
        let unresolved: Int
    }

    private func clockParentIsCurrent(_ parent: [AppointmentItem]) -> Bool {
        guard library.accessReady, library.authorized,
              AppointmentAnswerEngine.rebind(parent, items: appointments.items, originals: library.memories) != nil else { return false }
        let sources = Set(parent.flatMap(\.allSources))
        let current = PhotoLibrary.currentFingerprints(for: sources.map(\.id))
        return sources.allSatisfy { current[$0.id] == $0.fingerprint }
    }

    private func clearClockSearch() {
        clockResult = nil; clockNotice = nil; clockPending = nil; clockPosition = nil
    }

    private func reconcileClockSearch() {
        guard let parent = clockResult?.parent ?? clockPending?.parent, !clockParentIsCurrent(parent) else { return }
        clearClockSearch()
        cancelOriginalViews(close: true)
        clockNotice = "The appointments changed. Ask for the list again."
    }

    private func openClockPhoto(at position: Int) {
        guard let result = clockResult, result.originals.indices.contains(position),
              clockParentIsCurrent(result.parent), phase == .active else { reconcileClockSearch(); return }
        clockPosition = position
        appointmentOriginal = PinOriginalPhotoPresentation(memory: result.originals[position], hasNext: position + 1 < result.originals.count)
    }

    private var clockAnswerView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice = clockNotice { Text(notice).accessibilityIdentifier("clockNotice") }
            if let result = clockResult {
                Text(result.originals.isEmpty ? "No matching originals" : "Matching originals").font(.title.bold())
                    .accessibilityIdentifier("clockHeading")
                ForEach(result.originals) { photo in
                    let title = result.matches.first(where: { $0.sourceID == photo.id })?.observation.title ?? "Appointment"
                    Button {
                        if let index = result.originals.firstIndex(where: { $0.id == photo.id }) { openClockPhoto(at: index) }
                    } label: { Label(title, systemImage: "photo").frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .pinAnswerSurface().accessibilityLabel("Original for " + title)
                }
                if result.unresolved > 0 { Text("Some appointments have details that need checking.").foregroundStyle(Color.pinMuted) }
            }
        }
    }

    private func dispatchClockSearch(_ input: String) -> Bool {
        typealias Search = PinAppointmentClockSearch
        let meridiem = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let question: String
        let parent: [AppointmentItem]
        if ["am", "pm"].contains(meridiem), let pending = clockPending {
            question = pending.question.replacingOccurrences(of: #"(?<=\d)\s*,\s*"#, with: " " + meridiem + ", ", options: .regularExpression)
            parent = pending.parent
        } else {
            guard Search.owns(input) else { clearClockSearch(); return false }
            question = input
            if let result = clockResult { parent = result.matches }
            else if clockNotice == nil, case .list(let answer) = semanticSnapshot, semanticContext != nil, !savedQuestionVisible,
                    !visitsVisible, !personPlansVisible, !placeQuestionVisible {
                // Use only rows published in this dated list. Review-only records have no established visit clock.
                parent = answer.matches
            } else {
                clearClockSearch()
                searched = true; clockNotice = "Ask for your appointments first so I know which ones you mean."
                return true
            }
        }
        clearClockSearch(); cancelOriginalViews(close: true)
        searched = true
        guard clockParentIsCurrent(parent) else { clockNotice = "The appointments changed. Ask for the list again."; return true }
        let byID = Dictionary(uniqueKeysWithValues: library.memories.map { ($0.id, $0) })
        func minute(_ date: Date?, zone: TimeZone) -> Int? {
            guard let date else { return nil }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let time = calendar.dateComponents([.hour, .minute], from: date)
            guard let hour = time.hour, let minute = time.minute else { return nil }
            return hour * 60 + minute
        }
        do {
            let request = try Search.parse(question, providers: parent.compactMap { $0.observation.provider })
            guard request.minute != nil else {
                clockPending = (question, parent)
                clockNotice = "Did you mean AM or PM?"; return true
            }
            // For compound-source appointments the exact contributing original needs stronger attribution.
            let usable = parent.filter { $0.allSources.count == 1 && byID[$0.sourceID] != nil }
            var matches: [AppointmentItem] = [], originals: [PhotoMemory] = [], seen = Set<String>()
            var unresolved = parent.count - usable.count
            for item in usable {
                guard let photo = byID[item.sourceID] else { continue }
                let obs = item.observation
                let row = Search.Row(sourceID: photo.id, provider: obs.provider,
                    visitMinute: obs.printedTime != nil && obs.reviewReason == nil ? TimeZone(identifier: obs.timeZoneID).flatMap { minute(obs.date, zone: $0) } : nil,
                    captureMinute: minute(photo.photographedAt, zone: .current), screenshot: photo.isScreenshot)
                let match = try Search.select([row], request: request, role: request.role)
                unresolved += match.unresolved
                if !match.ids.isEmpty { matches.append(item); if seen.insert(photo.id).inserted { originals.append(photo) } }
            }
            clockResult = ClockResult(parent: parent, matches: matches, originals: originals, unresolved: unresolved)
            if question.lowercased().contains("originals"), !originals.isEmpty { openClockPhoto(at: 0) }
        } catch {
            clockNotice = "I couldn’t apply all those conditions. Try naming one clock, one cutoff, and one practice from the list to exclude."
        }
        return true
    }

    private func showNativeLocation(_ question: String, ordinal: Int,preserveDraft:Bool=false) {
        searchEpoch += 1; cancelSemanticWork(); semanticWork = nil
        semanticWorking = false; semanticUpdating = false; semanticPendingQuestion = nil
        semanticScope = nil; semanticScopeMeaning = nil; semanticSnapshot = nil; semanticNotice = nil
        semanticPlan = .appointmentLocation(ordinal: ordinal)
        submittedQuery = question; hits = []; selection = nil; searched = true
        if !preserveDraft {inputFocused = false}
        guard let previous = semanticContext else {
            semanticNotice = "Ask about your appointments first so I know which one you mean."; return
        }
        let location = previous.location(of: ordinal, answerID: previous.answerID,
            items: appointments.items, originals: library.memories)
        if case .location = location,
           let item = previous.item(of: ordinal, answerID: previous.answerID,
               items: appointments.items, originals: library.memories),
           PhotoLibrary.currentFingerprint(for: item.sourceID) == item.source.fingerprint {
            semanticContext?.select(item, items: appointments.items, originals: library.memories)
            semanticSnapshot = .location(item)
        } else if location == .unknownLocation {
            semanticNotice = "I couldn’t find a location in that appointment’s photo."
        } else {
            semanticNotice = "That appointment changed or is no longer available. Ask about your appointments again."
        }
    }
    @ViewBuilder private var appointmentPreview: some View {
        if let first=currentAppointments.sorted(by:{ ($0.observation.date ?? .distantFuture) < ($1.observation.date ?? .distantFuture) }).first {
            Button {
                showNativeAppointments("Appointments", period: .all, selection: .any)
            } label: {
                HStack(alignment:.top,spacing:12) {
                    Image(systemName:"calendar").foregroundStyle(Color.pinRose)
                    VStack(alignment:.leading,spacing:5) {
                        Text("Appointments from your photos").font(.headline)
                        Text(first.observation.kind ?? first.observation.title).font(.subheadline)
                        if let date=first.observation.previewDateText { Text(date).font(.caption).foregroundStyle(Color.pinMuted) }
                        Text("View \(currentAppointments.count) appointment \(currentAppointments.count == 1 ? "entry" : "entries")")
                            .font(.caption).foregroundStyle(Color.pinRose)
                        if let group=repeatedRegistrations.first {
                            Text(group.printedDetailsAgree
                                 ? "\(group.members.count) photos show the same Luma registration; ticket count unconfirmed."
                                 : "\(group.members.count) photos share a Luma guest registration, but their printed details do not fully agree. Review the originals; ticket count unconfirmed.")
                                .font(.caption).foregroundStyle(Color.pinMuted)
                                .accessibilityIdentifier("ticketRegistrationContext")
                        }
                    }
                    Spacer();Image(systemName:"chevron.right").foregroundStyle(Color.pinRose)
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color.pinSurface,in:RoundedRectangle(cornerRadius:22))
            }.buttonStyle(.plain).accessibilityIdentifier("homeAppointments")
        }
    }

    /// Keep each alternative behind one view boundary. Building the entire
    /// nested result type on the iPhone exhausted the SwiftUI startup stack.
    private var primaryAnswer: AnyView {
        if !library.authorized { return AnyView(Group {
welcome
        }) }
        if !library.accessReady { return AnyView(Group {
if let failure=library.accessFailure {Text(failure).accessibilityIdentifier("photoAccessFailure")}
                    else{ProgressView("Checking photo access…")}
        }) }
        if !searched { return AnyView(Group {
introduction
    .onAppear {PinFreshProductAudit.recordLifecycle(stage:"homeViewAppeared",requestID:semanticRequestID,epoch:searchEpoch,busy:semanticWorking)}
        }) }
        if let itinerary { return AnyView(ItineraryResult(answer: itinerary) { photo in
            showPhoto(photo, itineraryID: itinerary.id)
        }) }
        if clockResult != nil || clockNotice != nil { return AnyView(clockAnswerView) }
        if SavedPlacesDevelopmentControl.enabled || placeQuestionVisible {return AnyView(savedPlacesResult)}
        if personPlansVisible {return AnyView(personPlansResult)}
        if visitsVisible {return AnyView(visitsResult)}
        if AppointmentCoordinator.usesSavedContent || savedQuestionVisible {return AnyView(savedContentResult)}
        if PinFreshProductConfiguration.enabled,freshContinuation.waitingForAccess != nil,library.indexing {
            return AnyView(ProgressView("Reading your photos…").accessibilityIdentifier("questionWaitingForPhotoReading"))
        }
        if let corrected=correctedPresentation,!semanticWorking,appointments.items.contains(corrected.item) {
            return AnyView(PinCorrectedAppointmentResult(target:corrected,open:{source in openCorrectedOriginal(corrected,source:source)},correct:{requestOwnerCorrection(corrected.item)}))
        }
        if semanticWorking && unitAnswer==nil { return AnyView(Group {
ProgressView(semanticUpdating ? "Updating appointments…" : (appointments.freshQuestionPhase?.title ?? "Understanding your question…"))
        }) }
        if let answer=unitAnswer { return AnyView(Group {
UnitAppointmentResult(result:answer,appointments:appointments,originals:library.memories,working:semanticWorking,notice:semanticNotice,evidence:unitEvidenceAnswer,open:showUnitOriginal,correct:requestOwnerCorrection,linked:linkedUnitAnswer?.displayedAnswer)
    .task(id:answer.requestID) {PinFreshProductAudit.recordLifecycle(stage:"unitViewAppeared",requestID:answer.requestID,epoch:searchEpoch,busy:semanticWorking)}
        }) }
        if let answer=exhaustiveAnswer { return AnyView(Group {
ExhaustiveAppointmentResult(result:answer,appointments:appointments,originals:library.memories,open:showPhoto,forget:requestForget,inspect:showAppointmentPhoto)
        }) }
        if let pending=semanticScope { return AnyView(Group {
VStack(alignment:.leading,spacing:16) {
                        Text("All appointments or only tickets?").font(.title2.weight(.semibold))
                        if case .interval(let interval)=pending.window {
                            Text("\(interval.start.formatted(date:.abbreviated,time:.omitted)) – \(interval.end.addingTimeInterval(-1).formatted(date:.abbreviated,time:.omitted))")
                                .font(.subheadline).foregroundStyle(Color.pinMuted)
                        }
                        Button("All appointments") { resolveAppointmentScope(.any) }
                            .buttonStyle(.borderedProminent).tint(Color.pinRose).foregroundStyle(.white)
                            .accessibilityIdentifier("scopeAllAppointments")
                        Button("Only event tickets") { resolveAppointmentScope(.eventTickets) }
                            .buttonStyle(.bordered).tint(Color.pinRose)
                            .accessibilityIdentifier("scopeEventTickets")
                    }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                        .background(.white.opacity(0.85),in:RoundedRectangle(cornerRadius:24))
        }) }
        if let notice=semanticNotice { return AnyView(Group {
VStack(alignment:.leading,spacing:16) {
                        Text(notice).font(.title3.weight(.semibold))
                        if showAppointmentUpdate, let update=semanticAnswerUpdate {
                            if case .interval(let interval)=update.window {
                                Text("\(interval.start.formatted(date:.abbreviated,time:.omitted)) – \(interval.end.addingTimeInterval(-1).formatted(date:.abbreviated,time:.omitted))")
                                    .font(.subheadline).foregroundStyle(Color.pinMuted)
                            }
                            Button("Update this list",action:updateAppointmentAnswer)
                                .buttonStyle(.borderedProminent).tint(Color.pinRose).foregroundStyle(.white)
                                .accessibilityIdentifier("updateAppointmentAnswer")
                        }
                    }
        }) }
        if let snapshot=semanticSnapshot { return AnyView(Group {
SemanticAppointmentResult(snapshot:snapshot,appointments:appointments,originals:library.memories,
                        checkInCodes:ticketCodes,readingStatus:library.indexing ? library.status : nil,open:showPhoto,forget:requestForget,inspect:showAppointmentPhoto,willDismiss:invalidateForNativeDismiss,inlineUnresolved:recordQuestionContext != nil,answerTimeZone:recordQuestionContext?.displayTimeZone,answerNow:recordQuestionContext?.submittedAt,changeFields:recordChangeFields,correct:requestOwnerCorrection)
        }) }
        if let plan = photoQueryPlan { return AnyView(Group {
VStack(alignment: .leading, spacing: 20) {
                        photoQueryScope(plan)
                        if hits.isEmpty { noResults } else { result }
                    }
        }) }
        if semanticEnabled && semanticPlan == nil { return AnyView(Group {
Text("Ask again to see the current information.").font(.title3.weight(.semibold))
        }) }
        if semanticPlan == nil, let request = AppointmentQuestion.explicitRequest(submittedQuery) { return AnyView(Group {
explicitAppointmentAnswer(request)
        }) }
        if semanticPlan == nil && AppointmentQuestion.intent(submittedQuery) != nil { return AnyView(Group {
appointmentAnswer(submittedQuery)
        }) }
        if semanticPlan == .museums || (semanticPlan == nil && MuseumQuestion.matches(submittedQuery)) { return AnyView(Group {
MuseumCards(memories:hits.map(\.memory),open:showPhoto,forget:requestForget)
        }) }
        if hits.isEmpty { return AnyView(Group {
noResults
        }) }
        return AnyView(Group {
result
        })
    }

    private var header: some View {
        HStack {
            Button {
                PinFreshProductAudit.recordLifecycle(stage:"homeTapped",requestID:semanticRequestID,epoch:searchEpoch,busy:semanticWorking)
                voice.cancel()
                searchEpoch += 1;resetSemantic()
                searched = false; hits = []; selection = nil
                submittedQuery = ""; query = ""; inputFocused = false; homeRevision += 1
            } label: {
                Image("PinBrand")
                    .resizable().scaledToFit()
                    .frame(width: 112, height: 46)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }.accessibilityLabel("Pin home")
            Spacer()
            Button { voice.cancel(); showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3.weight(.medium)).foregroundStyle(Color.pinMuted)
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.52), in: Circle())
                    .overlay(Circle().strokeBorder(Color.pinRose.opacity(0.15)))
            }.accessibilityLabel("Photo access and privacy")
        }
    }
    private var welcome: some View {
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let requiresLimited = PinPublicProductScope.requiresLimitedPhotoAccess ||
            SavedPlacesQualification.localReaderEnabled || PeoplePlansQualification.enabled || VisitsQualification.enabled
        let canEditSelection = requiresLimited && permission == .limited
        return VStack(alignment: .leading, spacing: 22) {
            Text("You took the photo.\nPin helps you find it.").font(.system(size: 38, weight: .semibold)).tracking(-1)
            Text("Ask about those shoes you photographed the other day. Pin looks for the photo, its visible details and where it was taken.")
                .font(.body).foregroundStyle(Color.pinMuted)
            Button {
                if canEditSelection {
                    editLimitedPhotoSelection()
                } else {
                    Task { await library.connect(requestPermission: true) }
                }
            } label: {
                Label(canEditSelection ? "Edit selected photos" : "Allow photo access", systemImage: "photo.on.rectangle")
                    .font(.headline).frame(maxWidth: .infinity).padding(17)
                    .background(Color.pinRose, in: Capsule()).foregroundStyle(.white)
            }.accessibilityIdentifier("allowPhotos")
            Text(library.status).font(.footnote).foregroundStyle(Color.pinMuted)
            if permission == .denied ||
                (requiresLimited && permission != .notDetermined) {
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
        }.padding(.top, 34)
    }
    private func editLimitedPhotoSelection() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
              let presenter = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive && $0.keyWindow != nil })?
                  .keyWindow?.rootViewController,
              presenter.presentedViewController == nil else { return }
        Task {
            _ = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
            await library.connect()
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 23) {
            Text("What are you trying to remember?")
                .font(.largeTitle.weight(.semibold)).tracking(-0.9)
                .accessibilityAddTraits(.isHeader)
            readingCoverage
            if !library.memories.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent photos").font(.headline).accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(library.memories.prefix(8))) { memory in
                                Button { showPhoto(memory) } label: {
                                    LibraryPhoto(id: memory.id, pixelSize: 480)
                                        .frame(width: 154, height: 184).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 22))
                                }.buttonStyle(.plain).accessibilityLabel(memory.title)
                            }
                        }
                    }.frame(height: 184)
                }
            }
            appointmentPreview
        }.padding(.top, 16)
    }
    private func photoQueryScope(_ plan: PhotoQueryPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let interval = plan.captureInterval {
                let style = Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: plan.calendar, timeZone: plan.calendar.timeZone)
                Text("Photo dates · \(interval.start.formatted(style)) – \(interval.end.addingTimeInterval(-1).formatted(style))")
            }
            if let text = plan.request.recognizedText { Text("Recognized text contains “\(text)”") }
            if plan.request.media == .screenshots { Text("Screenshots") }
            if plan.request.media == .nonScreenshots { Text("Excluding screenshots") }
            if let result = photoQueryResult {
                if result.withoutPhotoDate > 0 { Text("\(result.withoutPhotoDate) photos have no recorded date and couldn’t be checked.") }
                if result.withoutScreenshotStatus > 0 { Text("\(result.withoutScreenshotStatus) photos have no confirmed screenshot status.") }
                if result.withoutRecognizedText > 0 { Text("\(result.withoutRecognizedText) photos have no recognized text to check.") }
            }
        }.font(.subheadline).foregroundStyle(Color.pinMuted)
            .accessibilityElement(children: .combine).accessibilityIdentifier("photoQueryScope")
    }
    private var noResults: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(library.indexing ? "Still looking through\nyour photos." : "No match in the photos\nPin has read yet.")
                .font(.system(size: 34, weight: .semibold)).tracking(-0.8)
            Text((library.readingSummary?.incomplete ?? 0) > 0
                 ? "Some photos have not been read. Check reading coverage below or retry them before drawing a conclusion."
                 : "Try another way of asking. Photos read without usable details may not appear in search.")
                .foregroundStyle(Color.pinMuted)
            if LocalRecall.requestsShoeColour(submittedQuery) {
                Text("I couldn’t confirm those shoe details from the available observations.")
                    .font(.subheadline).foregroundStyle(Color.pinMuted)
            }
            if (library.readingSummary?.partialRecognition ?? 0) > 0 {
                Text("Image recognition was unavailable for some reads. Text recall still works; appearance searches may miss photos.")
                    .font(.footnote).foregroundStyle(Color.pinMuted)
            }
            Button("Photo access") { showSettings = true }.tint(Color.pinRose)
        }
    }
    private func appointment(for memory:PhotoMemory) -> AppointmentItem? {
        appointments.items.first { !$0.dismissed && $0.source == AppointmentSource(memory) && !AppointmentCardReader.isPinInterface(memory.text) }
    }
    private var result: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(hits.count > 1 ? "Are these the photos?" : "Is this the photo?")
                .font(.largeTitle.weight(.semibold)).tracking(-0.9)
                .accessibilityAddTraits(.isHeader)
            GeometryReader { geometry in
            TabView(selection: Binding(get: { selected?.id ?? "" }, set: { selection = $0 })) {
                ForEach(hits) { hit in
                    ZStack(alignment: .bottom) {
                        LibraryPhoto(id: hit.id).frame(width: geometry.size.width, height: 390).clipped()
                        let capturedAt = (appointment(for: hit.memory) == nil ? "" : "Photo saved · ") +
                            (hit.memory.photographedAt.map { $0.formatted(.dateTime.weekday(.wide).hour().minute()) } ?? "Date not recorded")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Label(capturedAt, systemImage: "clock")
                                Spacer(minLength: 8)
                                searchOriginalButton(hit)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Label(capturedAt, systemImage: "clock")
                                searchOriginalButton(hit)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.subheadline).foregroundStyle(Color.pinInk)
                        .padding(.horizontal, 14).padding(.vertical, 3)
                        .background {
                            RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
                                .overlay(RoundedRectangle(cornerRadius: 22).fill(Color.pinSurface.opacity(0.72)))
                        }
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.7)))
                        .padding(12)
                    }.frame(width: geometry.size.width, height: 390).clipShape(RoundedRectangle(cornerRadius: 28)).tag(hit.id)
                }
            }.tabViewStyle(.page(indexDisplayMode: hits.count > 1 ? .always : .never))
            }.frame(height: 390)
            if let selected {
                VStack(alignment: .leading, spacing: 12) {
                    if let booking=appointment(for:selected) {
                        AppointmentFacts(observation:booking.observation)
                    } else {
                    Text(selected.title).font(.system(size: 29, weight: .semibold)).tracking(-0.6)
                    if let coordinate = selected.coordinate {
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(Color.pinRose)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Location recorded").font(.headline)
                                Text("From the photo’s location. This does not verify the shop.").font(.footnote).foregroundStyle(Color.pinMuted)
                            }
                        }
                        Map(initialPosition: .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude), span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)))) {
                            Marker("Photo location", coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)).tint(Color.pinRose)
                        }.frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 18)).id(selected.id)
                    } else {
                        Label("No location was recorded", systemImage: "mappin.slash").foregroundStyle(Color.pinMuted)
                    }
                    }
                    if !selected.text.isEmpty {
                        DisclosureGroup("Text visible in the photo") {
                            Text(selected.text.joined(separator: "\n")).font(.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.top, 8)
                        }.tint(Color.pinRose)
                    }
                    if selected.isFootwear {
                        Text(LocalRecall.requestsShoeColour(submittedQuery) ? "Check the original to confirm the requested colour. A word in the photo doesn’t confirm the shoe’s colour." : "I can't verify the exact shoe model from these observations.").font(.footnote).foregroundStyle(Color.pinMuted)
                    }
                    Button("Forget this photo in Pin", role: .destructive) { requestForget(selected) }.font(.footnote).padding(.top, 8)
                }
            }
        }
    }
    private func searchOriginalButton(_ hit: RecallHit) -> some View {
        Button { openOriginal(hit) } label: {
            Label("Original", systemImage: "photo.on.rectangle")
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.pinRose)
        .accessibilityIdentifier("openOriginal")
    }

    private var questionDock: some View {
        VStack(alignment:.leading,spacing:6) {
        if let pending=freshContinuation.pending {
            Text("Next, after this answer: \(pending.question)").font(.caption).foregroundStyle(Color.pinMuted).padding(.horizontal,22)
                .lineLimit(2).accessibilityIdentifier("queuedQuestion")
        }
        HStack(spacing: 8) {
            TextField("Ask about your photos…", text: $query,
                      prompt: Text("Ask about your photos…").foregroundStyle(Color.pinMuted))
                .font(.body).foregroundStyle(Color.pinInk).tint(Color.pinRose)
                .focused($inputFocused).submitLabel(.search)
                .onSubmit { search() }.accessibilityIdentifier("question")
            Button { toggleVoice() } label: {
                Image(systemName: voice.active ? "stop.fill" : "mic.fill").font(.title3.weight(.medium))
                    .frame(width: 48, height: 48)
                    .background {
                        Circle().fill(LinearGradient(colors: [Color(red: 0.77, green: 0.29, blue: 0.43), .pinRose],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                    }.foregroundStyle(.white)
            }.accessibilityLabel(voice.active ? "Stop listening" : "Ask by voice")
        }.padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 8)
            .background {
                Capsule().fill(.regularMaterial)
                    .overlay(Capsule().fill(Color.pinSurface.opacity(0.82)))
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.92)))
            .shadow(color: Color.pinRose.opacity(0.17), radius: 14, x: 0, y: 7)
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
            .background {
                LinearGradient(colors: [.clear, Color.pinBackground.opacity(0.96)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
    // The same durable coverage and recovery controls appear on every answer
    // and in privacy settings. Counts describe reads, never understanding.
    private var readingCoverage: some View {
        let readCount = library.readingSummary.map {
            "\($0.read) photo\($0.read == 1 ? "" : "s") read"
        }
        let statusIsCompleteCount = library.readingSummary.map { $0.read == $0.total } == true &&
            !library.indexing && readCount == library.status
        return VStack(alignment: .leading, spacing: 9) {
            if !statusIsCompleteCount {
                Text(library.status).font(.footnote).accessibilityIdentifier("indexStatus")
            }
            if let summary = library.readingSummary {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(summary.read) read · \(summary.unread) unread")
                        if summary.sourceMetadataPending > 0 {
                            Text("Of the unread photos: \(summary.sourceMetadataPending) are waiting for photo details to be confirmed. Saved observations are kept.")
                        }
                        Text("\(summary.needsDownload) awaiting iCloud download")
                        Text("\(summary.unavailable) couldn’t be opened · \(summary.failed) couldn’t be analyzed")
                        Text("Of the read photos: \(summary.withoutUsableDetails) without usable text or image details; \(summary.partialRecognition) with image recognition unavailable.")
                        Text("Reading a photo doesn’t confirm its meaning.")
                    }.font(.caption).lineLimit(nil).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                } label: {
                    if statusIsCompleteCount {
                        Label(library.status, systemImage: "photo.stack")
                            .font(.subheadline.weight(.medium)).accessibilityIdentifier("indexStatus")
                    } else {
                        Label("\(summary.read) of \(summary.total) photos read", systemImage: "photo.stack")
                            .font(.subheadline.weight(.medium))
                    }
                }.tint(Color.pinRose).accessibilityIdentifier("readingCoverage")
                if !library.indexing && summary.needsDownload > 0 {
                    Button {
                        library.downloadMissingPhotos()
                    } label: {
                        Label("Download \(summary.needsDownload) missing photo\(summary.needsDownload == 1 ? "" : "s") from iCloud",
                              systemImage: "icloud.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(Color.pinRose).foregroundStyle(.white)
                    .accessibilityIdentifier("downloadMissingPhotos")
                }
                if !library.indexing && summary.incomplete > summary.needsDownload {
                    Button("Retry unfinished reads") { library.refresh(retryFailedReads: true) }.font(.subheadline)
                        .accessibilityIdentifier("retryReading")
                }
            }
            if library.indexing {
                Button { background.continueCurrentScan() } label: {
                    Text("Continue reading in background").font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 8).foregroundStyle(.white)
                }.buttonStyle(.borderedProminent).tint(Color.pinRose)
                    .accessibilityIdentifier("continueIndexing")
            }
            if let state = library.backgroundStatus { Text(state).font(.caption) }
        }
        .foregroundStyle(Color.pinMuted).buttonStyle(.borderless)
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 19))
        .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(.white.opacity(0.82)).allowsHitTesting(false) }
    }

    private var settings: some View {
        NavigationStack {
            List {
                Section("Your photo access") {
                    readingCoverage
                    Button("Refresh allowed photos") { library.refresh() }
                    Button("Manage photo access in Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
                Section("What Pin uses") {
                    Text("This first build reads available photos on this iPhone using Apple Vision. It stores observed text, image categories, dates and available photo locations locally.")
                    if PinFreshProductConfiguration.enabled {
                        Text(PinPublicProductScope.usesExistingPhotoIntake
                             ? "Photo reading stays on this device. Only the declared test photos and your test questions can be interpreted through the paired Mac. Other local photo readings are excluded."
                             : "This test reads only the public sample photos prepared for it. Their text and your test questions are sent through the paired Mac for model interpretation. Your personal photo library is outside this test’s reading scope.")
                    } else if SemanticQueryLab.endpoint != nil {
                        Toggle(SemanticQueryLab.replaysRetainedResponses ? "Replay recorded test answers" : "Interpret fictional test questions",isOn:$semanticEnabled)
                        Text(SemanticQueryLab.privacyDescription)
                    } else {
                        Text("No photos or questions are sent to a model service. Jev and gbrain are not connected in this baseline.")
                    }
                    Text("Forgetting removes Pin’s observations, not the original photo. Pin does not create notes or tags for you to fill in.")
                }
                Section("Build status") { Text("Native first-journey baseline · model-backed recall not verified") }
            }.navigationTitle("Privacy & access").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }.tint(Color.pinRose)
    }
    private func openNotificationCard() {
        guard phase == .active, library.accessReady, let context = appointments.notificationContext else { return }
        appointments.notificationContext = nil
        guard let memory = library.memories.first(where: { $0.id == context.sourceID && $0.fingerprint == context.fingerprint }),
              PhotoLibrary.currentFingerprint(for: memory.id) == memory.fingerprint else {
            message = "This appointment photo changed or is no longer accessible."; return
        }
        Task {
            do { _ = try await library.store.current(RecallHit(memory: memory, score: 0)); appointmentOriginal = PinOriginalPhotoPresentation(memory:memory,hasNext:false) }
            catch { message = "This card is no longer available." }
        }
    }
    private var usesNativeQuestionContinuation:Bool {
        PinFreshProductConfiguration.enabled || AppointmentCoordinator.usesSavedContent ||
        SavedPlacesDevelopmentControl.enabled || SavedPlacesQualification.localReaderEnabled || PeoplePlansQualification.enabled || VisitsQualification.enabled
    }
    private var personPlansResult: some View {
        VStack(alignment: .leading, spacing: 18) {
            if semanticWorking { ProgressView("Checking your photos…") }
            if let semanticNotice {
                Text(semanticNotice).foregroundStyle(Color.pinMuted).accessibilityIdentifier("personPlansNotice")
            }
            if let personPlans {
                PersonPlansResult(answer: personPlans, openOriginal: openPersonPlanOriginal,
                                  correct: requestPersonPlanCorrection)
            }
        }
    }

    private func requestPersonPlanCorrection(_ source: SourceReference) {
        guard !semanticWorking, phase == .active, personPlanCorrection == nil,
              let card = personPlans?.cards.first(where: { $0.source == source }) else { return }
        let epoch = searchEpoch
        Task {
            do {
                _ = try await library.currentSavedPlaceOriginals(card.originalSources)
                let interpretations = await library.store.savedPhotoInterpretations()
                guard searchEpoch == epoch, phase == .active, library.accessReady,
                      personPlanCorrection == nil, personPlans?.cards.contains(card) == true else { return }
                let expected = interpretations.first { $0.source.id == source.id }
                personPlanCorrection = PersonPlanCorrectionTarget(card: card, epoch: epoch, expected: expected)
            } catch {
                guard searchEpoch == epoch, phase == .active else { return }
                semanticNotice = "The supporting photos changed. Ask again before correcting the plan."
            }
        }
    }

    private func savePersonPlanCorrection(_ target: PersonPlanCorrectionTarget,
                                          field: SavedPlanDetailCorrection.Field, value: String?) async throws {
        let card = target.card
        guard target.epoch == searchEpoch, phase == .active, !semanticWorking, let prior = personPlans,
              prior.cards.contains(card) else { throw PinEvidenceError.staleRecord }
        let photos = try await library.currentSavedPlaceOriginals(card.originalSources)
        guard target.epoch == searchEpoch, phase == .active, library.accessReady,
              personPlanCorrection?.id == target.id, personPlans?.cards.contains(card) == true,
              let primary = photos.first(where: { $0.id == card.source.id }) else { throw PinEvidenceError.staleRecord }
        _ = try await library.store.savePlanDetail(source: EvidenceSource(primary), person: card.person.value,
                                                   field: field, value: value,
                                                   additionalSources: card.correctionSources, expected: target.expected)
        do {
            let (evidence, interpretations) = try await currentPersonPlanEvidence()
            let refreshed = try PinPersonPlans.refresh(prior, in: evidence, interpretations: interpretations)
            let references = refreshed.cards.flatMap(\.originalSources)
            if !references.isEmpty { _ = try await library.currentSavedPlaceOriginals(references) }
            guard searchEpoch == target.epoch, phase == .active, library.accessReady else { return }
            guard refreshed.photoInventory.matches(library.memories) else { throw PinEvidenceError.staleRecord }
            personPlans = refreshed
            semanticNotice = value == nil ? "Correction removed." : "Correction saved."
        } catch {
            guard searchEpoch == target.epoch, phase == .active else { return }
            personPlans = nil
            semanticNotice = "Your change was saved. Ask again to check the current plan."
        }
    }

    private func currentPersonPlanEvidence() async throws -> (PinEvidenceSnapshot, [SavedPhotoInterpretation]) {
        let readings = try await library.currentSavedPlaceReadings()
        let interpretations = await library.store.savedPhotoInterpretations()
        let evidence = try PinEvidenceSnapshot(memories: readings, records: [],
            scope: MemoryScope(ownerID: "local-photo-owner", namespace: "people-plans"))
        return (evidence, interpretations)
    }

    private func openPersonPlanOriginal(_ source: SourceReference) {
        guard !semanticWorking, personPlans?.cards.contains(where: { $0.originalSources.contains(source) }) == true else { return }
        openCurrentEvidencePhoto(source)
    }

    private func openCurrentEvidencePhoto(_ source: SourceReference) {
        cancelOriginalViews(close: true, clearNotice: true)
        let request = originalViewRequestID
        originalViewWork = Task {
            do {
                let originals = try await library.currentSavedPlaceOriginals([source])
                guard !Task.isCancelled, request == originalViewRequestID, phase == .active,
                      let original = originals.first else { return }
                appointmentOriginal = PinOriginalPhotoPresentation(memory: original, hasNext: false)
            } catch {
                guard !Task.isCancelled, request == originalViewRequestID else { return }
                originalViewNotice = "That source changed. Ask again to see the current photo."
            }
        }
    }

    private func dispatchPersonPlansIfSupported(_ question: String, requestID: UUID) -> Bool {
        personPlanCorrection = nil
        guard PeoplePlansQualification.enabled, let request = PinPersonPlans.Request(question: question),
              request != .confirmedSubset || personPlansVisible else {
            personPlans = nil
            personPlansVisible = false
            return false
        }
        let previous = personPlans
        clearPlaceDisplay()
        placeQuestionVisible = false
        personPlans = nil
        personPlansVisible = true
        pendingNativeSubmission = nil
        semanticPendingQuestion = nil
        semanticWork?.cancel()
        cancelOriginalViews(close: true, clearNotice: true)
        searchEpoch += 1
        let epoch = searchEpoch
        semanticRequestID = requestID
        semanticWorking = true
        semanticNotice = nil
        searched = true
        submittedQuery = question
        interruptedQuestionDraft = question
        semanticWork = Task {
            var completed = false
            defer { finishSemanticWork(requestID, completed: completed) }
            do {
                let (evidence, interpretations) = try await currentPersonPlanEvidence()
                let answer: PinPersonPlans.Answer
                switch request {
                case .person(let person):
                    answer = try PinPersonPlans.search(person: person, in: evidence, interpretations: interpretations)
                case .confirmedSubset:
                    guard let previous else {
                        semanticNotice = "Ask for the person’s plans first."
                        return
                    }
                    answer = try PinPersonPlans.confirmedSubset(of: previous, in: evidence, interpretations: interpretations)
                }
                let references = answer.cards.flatMap(\.originalSources)
                if !references.isEmpty { _ = try await library.currentSavedPlaceOriginals(references) }
                guard !Task.isCancelled, semanticRequestID == requestID, searchEpoch == epoch,
                      phase == .active, library.accessReady else { return }
                guard answer.photoInventory.matches(library.memories) else { throw PinEvidenceError.staleRecord }
                personPlans = answer
                completed = true
            } catch {
                guard !Task.isCancelled, semanticRequestID == requestID, searchEpoch == epoch else { return }
                semanticNotice = "Pin couldn’t check the current plan photos. Ask again to retry."
            }
        }
        return true
    }
    private var visitsResult: some View {
        VStack(alignment: .leading, spacing: 18) {
            if semanticWorking { ProgressView("Checking your photos…") }
            if let semanticNotice { Text(semanticNotice).foregroundStyle(Color.pinMuted) }
            if let visits {
                VisitReconstructionResult(answer: visits) { source in
                    guard !semanticWorking, self.visits?.cards.contains(where: { $0.sources.contains(source) }) == true else { return }
                    openCurrentEvidencePhoto(source)
                }
            }
        }
    }

    private func dispatchVisitQuestion(_ question: String, requestID: UUID) -> Bool {
        guard VisitsQualification.enabled, let request = PinVisitReconstruction.Request(question: question) else {
            visits = nil
            visitsVisible = false
            return false
        }
        let previous = visits
        visits = nil
        visitsVisible = true
        clearPlaceDisplay()
        placeQuestionVisible = false
        personPlans = nil
        personPlanCorrection = nil
        personPlansVisible = false
        pendingNativeSubmission = nil
        semanticPendingQuestion = nil
        semanticWork?.cancel()
        cancelOriginalViews(close: true, clearNotice: true)
        searchEpoch += 1
        let epoch = searchEpoch
        semanticRequestID = requestID
        semanticWorking = true
        semanticNotice = nil
        searched = true
        submittedQuery = question
        interruptedQuestionDraft = question
        semanticWork = Task {
            var completed = false
            defer { finishSemanticWork(requestID, completed: completed) }
            do {
                let readings = try await library.currentSavedPlaceReadings()
                let evidence = try PinEvidenceSnapshot(memories: readings, records: [],
                    scope: MemoryScope(ownerID: "local-photo-owner", namespace: "visited-places"))
                let answer: PinVisitReconstruction.Answer
                switch request {
                case .city(let city):
                    answer = PinVisitReconstruction.search(city: city, in: evidence)
                case .all:
                    answer = PinVisitReconstruction.search(in: evidence)
                case .allWithReceipts:
                    answer = try PinVisitReconstruction.allWithReceipts(in: evidence)
                case .receiptSubset:
                    guard let previous else {
                        semanticNotice = "Ask where you visited first."
                        return
                    }
                    answer = try PinVisitReconstruction.receiptSubset(of: previous, in: evidence)
                }
                let references = answer.cards.flatMap(\.sources)
                if !references.isEmpty { _ = try await library.currentSavedPlaceOriginals(references) }
                guard !Task.isCancelled, semanticRequestID == requestID, searchEpoch == epoch,
                      phase == .active, library.accessReady else { return }
                guard answer.photoInventory.matches(library.memories) else { throw PinEvidenceError.staleRecord }
                visits = answer
                completed = true
            } catch {
                guard !Task.isCancelled, semanticRequestID == requestID, searchEpoch == epoch else { return }
                semanticNotice = "Pin couldn’t check the current visit photos. Ask again to retry."
            }
        }
        return true
    }

    private var savedPlacesResult: some View {
        VStack(alignment: .leading, spacing: 18) {
            if semanticWorking { ProgressView("Checking saved places…") }
            if let semanticNotice {
                Text(semanticNotice).foregroundStyle(Color.pinMuted)
                    .accessibilityIdentifier("savedPlacesNotice")
            }
            if let display = savedPlaceDisplay {
                SavedPlacesResult(answer: display.answer, openSources: openPlaceOriginals, correct: requestPlaceCorrection)
            }
        }
    }
    private func clearPlaceDisplay() {
        savedPlaceDisplay = nil
        placeCorrection = nil
    }
    private func reconcilePlaceDisplay() {
        guard let display = savedPlaceDisplay else { return }
        let references = (display.answer.cards + display.answer.unresolved).flatMap(\.sources)
        guard !references.isEmpty else { return }
        if (try? PinSavedPlaceSourceBinding.resolve(references, in: library.memories)) == nil {
            clearPlaceDisplay()
            semanticNotice = "The supporting photos changed. Ask again to check the current photos."
        }
    }
    private func currentPlaceCatalog(scope: PinSavedPlaceEvidenceScope) async throws -> SavedPlaceCatalog {
        if SavedPlacesDevelopmentControl.enabled {
            let memories = await library.store.all()
            let interpretations = await library.store.savedPhotoInterpretations()
            try Task.checkCancellation()
            return try SavedPlacesDevelopmentControl.catalog(memories: scope.select(memories), interpretations: interpretations)
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SavedPlacesQualification.localReaderEnabled {
            let memories = try await library.currentSavedPlaceReadings()
            let interpretations = await library.store.savedPhotoInterpretations()
            try Task.checkCancellation()
            let reader = localPlaceReader ?? PinLocalSavedPlaceReader()
            localPlaceReader = reader
            return try await reader.catalog(memories: scope.select(memories), interpretations: interpretations)
        }
        #endif
        throw PinStoreError.staleResult
    }
    @discardableResult
    private func dispatchPlaceQuestionIfSupported(_ question: String, requestID: UUID) -> Bool {
        if dispatchVisitQuestion(question, requestID: requestID) || dispatchPersonPlansIfSupported(question, requestID: requestID) {
            retireCombinedSavedDisplay()
            return true
        }
        guard SavedPlacesDevelopmentControl.enabled ||
                (SavedPlacesQualification.localReaderEnabled &&
                 PinSavedPlaceQuestionRouting.owns(question, hasDisplayedPlaces: savedPlaceDisplay != nil)) else {
            if placeQuestionVisible {
                clearPlaceDisplay()
                placeQuestionVisible = false
            }
            return false
        }
        retireCombinedSavedDisplay()
        submitPlaceQuestion(question, requestID: requestID)
        return true
    }
    private func submitPlaceQuestion(_ question: String, requestID: UUID = UUID()) {
        let previous = savedPlaceDisplay
        placeQuestionVisible = true
        pendingNativeSubmission = nil
        semanticPendingQuestion = nil
        semanticWork?.cancel()
        cancelOriginalViews(close: true, clearNotice: true)
        searchEpoch += 1
        let epoch = searchEpoch
        semanticRequestID = requestID
        semanticWorking = true
        semanticNotice = nil
        searched = true
        submittedQuery = question
        interruptedQuestionDraft = question
        semanticWork = Task {
            var completed = false
            defer { finishSemanticWork(requestID, completed: completed) }
            do {
                let explicit = PinSavedPlaceQuestionRouting.usesScreenshotScope(question) ? nil :
                    PinSavedPlaceIntent.explicit(question, hasDisplayedPlaces: previous != nil)
                if explicit == .needsDisplayedPlaces {
                    semanticNotice = "Ask for your saved places first."
                    return
                }
                var request = explicit.map(PinResolvedSavedPlaceRequest.existing)
                #if canImport(FoundationModels)
                if request == nil, #available(iOS 26.0, *), SavedPlacesQualification.localReaderEnabled {
                    request = try await PinResolvedSavedPlaceRequest.read(question, previousCity: previous?.city,
                                                                         hasPrevious: previous != nil)
                }
                #endif
                guard let request else {
                    semanticNotice = SavedPlacesDevelopmentControl.enabled
                        ? "That question is outside this authored test."
                        : "I couldn’t apply every part of that place question." +
                          (previous == nil ? "" : " Your previous answer is still below.")
                    return
                }
                let evidenceScope = request.evidenceScope(previous: previous?.evidenceScope)
                let catalog = try await currentPlaceCatalog(scope: evidenceScope)
                let answer = try request.answer(in: catalog, previous: previous?.context, requestID: requestID)
                let sources = (answer.cards + answer.unresolved).flatMap(\.sources)
                if !sources.isEmpty { _ = try await library.currentSavedPlaceOriginals(sources) }
                let context = try catalog.displayedContext(for: answer, orderedCardIDs: answer.cards.map(\.id))
                guard !Task.isCancelled, semanticRequestID == requestID, searchEpoch == epoch,
                      phase == .active, library.accessReady else { return }
                savedPlaceDisplay = SavedPlaceDisplay(answer: answer, context: context, evidenceScope: evidenceScope,
                                                       city: request.city(previous: previous?.city))
                completed = true
            } catch {
                guard !Task.isCancelled, semanticRequestID == requestID, searchEpoch == epoch else { return }
                if (error as? SavedPlaceError) == .unresolvedExclusion {
                    semanticNotice = "Which place should I leave out? Try the full name or branch." +
                        (previous == nil ? "" : " Your previous answer is still below.")
                    return
                }
                clearPlaceDisplay()
                #if canImport(FoundationModels)
                if case .modelUnavailable? = error as? PinLocalSavedPlaceReader.ReaderError {
                    semanticNotice = "The on-device reader is unavailable. Your saved photos are still here."
                    return
                }
                #endif
                semanticNotice = "Pin couldn’t check the current place photos. Ask again to retry."
            }
        }
    }
    private func openPlaceOriginals(_ cardID: String, _ field: SavedPlaceField?) {
        guard !semanticWorking, let display = savedPlaceDisplay else { return }
        cancelOriginalViews(close: true, clearNotice: true)
        let request = originalViewRequestID
        originalViewWork = Task {
            do {
                let catalog = try await currentPlaceCatalog(scope: display.evidenceScope)
                let sources = try PinSavedPlaceSourceBinding.originalReferences(
                    cardID: cardID, field: field, answer: display.answer, displayed: display.context, catalog: catalog)
                guard !Task.isCancelled, request == originalViewRequestID, phase == .active else { return }
                placeOriginals = sources
                presentNextPlaceOriginal()
            } catch {
                guard !Task.isCancelled, request == originalViewRequestID else { return }
                originalViewNotice = "That source changed. Ask again to see the current photo."
            }
        }
    }
    private func presentNextPlaceOriginal() {
        guard !placeOriginals.isEmpty else { return }
        let source = placeOriginals.removeFirst()
        let request = originalViewRequestID
        originalViewWork = Task {
            do {
                let photos = try await library.currentSavedPlaceOriginals([source])
                guard !Task.isCancelled, request == originalViewRequestID, phase == .active,
                      let photo = photos.first else { return }
                appointmentOriginal = PinOriginalPhotoPresentation(memory: photo, hasNext: !placeOriginals.isEmpty)
            } catch {
                guard !Task.isCancelled, request == originalViewRequestID else { return }
                placeOriginals = []
                originalViewNotice = "That source changed. Ask again to see the current photo."
            }
        }
    }
    private func requestPlaceCorrection(_ cardID: String) {
        guard !semanticWorking, let display = savedPlaceDisplay,
              let card = display.answer.cards.first(where: { $0.id == cardID }) else { return }
        let epoch = searchEpoch
        Task {
            do {
                let catalog = try await currentPlaceCatalog(scope: display.evidenceScope)
                let sources = try catalog.originals(for: cardID, in: display.context, parentRequestID: display.answer.requestID)
                _ = try await library.currentSavedPlaceOriginals(sources)
                let ledger = await library.store.savedPhotoInterpretations()
                let details = card.members.flatMap { member in
                    member.facts.compactMap { fact -> SavedPlaceCorrectionTarget.Detail? in
                        guard fact.origin != .inferred,
                              let field = SavedPlaceDetailCorrection.Field(rawValue: fact.field.rawValue) else { return nil }
                        return .init(mentionID: member.recordID, source: member.source, field: field,
                                     value: fact.value, quote: fact.anchors.first?.quote ?? fact.value,
                                     expected: ledger.first(where: { $0.source.id == member.source.id }))
                    }
                }.sorted { ($0.field.rawValue, $0.mentionID) < ($1.field.rawValue, $1.mentionID) }
                guard searchEpoch == epoch, phase == .active, library.accessReady, !details.isEmpty else { return }
                placeCorrection = .init(id: cardID, name: card.establishedValue(for: .name) ?? "Saved place", details: details)
            } catch {
                guard searchEpoch == epoch else { return }
                semanticNotice = "The supporting photos changed. Ask again before correcting a detail."
            }
        }
    }
    private func savePlaceCorrection(_ detail: SavedPlaceCorrectionTarget.Detail, _ value: String) async throws {
        let epoch = searchEpoch
        let photos = try await library.currentSavedPlaceOriginals([detail.source])
        guard searchEpoch == epoch, let photo = photos.first else { throw PinEvidenceError.staleRecord }
        _ = try await library.store.savePlaceDetail(source: EvidenceSource(photo), mentionID: detail.mentionID,
                                                     field: detail.field, value: value, expected: detail.expected)
        guard searchEpoch == epoch else { return }
        clearPlaceDisplay()
        semanticNotice = "Correction saved. Ask again to see the updated detail."
    }
    private var savedContentResult:some View {
        VStack(alignment:.leading,spacing:18) {
            if semanticWorking {
                switch appointments.savedContentStage {
                case .checkingEvidence(let visited,let total):
                    ProgressView("Checking saved photos · \(visited) of \(total)")
                default:ProgressView(library.indexing ? "Reading your photos…":"Understanding your question…")
                }
            }
            if let notice=semanticNotice {Text(notice).foregroundStyle(Color.pinMuted).accessibilityIdentifier("savedContentNotice")}
            if let result=savedAnswer {
                SavedScreenshotResult(cards:savedCards,coverage:savedCoverage(result),thumbnail:{id in
                    Group {
                        if let memory=savedSources[id] {LibraryPhoto(id:memory.id)}
                        else {Image(systemName:"photo").foregroundStyle(Color.pinMuted)}
                    }
                },open:{id in openSavedOriginal(result,recordID:id)},correct:{id in requestSavedCorrection(result,recordID:id)})
            }
        }
    }
    private func savedCoverage(_ value:PinSavedContentAnswer)->String {
        let c=value.answer.coverage
        let checked="Checked \(c.visitedRecords) of \(c.declaredRecords) saved entries."
        if c.hasEvidenceLimitationsBeyondUnassessedText {
            return checked + " Some photo evidence was unread or unclear. This answer may be incomplete."
        }
        if !c.textObservedWithoutAssessment.isEmpty {
            return checked + " Based on readable text from the photos available to Pin."
        }
        return checked + " Based on the photos available to Pin."
    }
    private func clearSavedDisplay() {
        savedAnswer=nil;savedContext=nil;savedCards=[];savedSources=[:];savedCorrection=nil
    }
    private func reconcileSavedDisplay() {
        guard AppointmentCoordinator.usesSavedContent || savedQuestionVisible, !savedSources.isEmpty else{return}
        if !savedSources.values.allSatisfy({library.memories.contains($0) && PhotoLibrary.currentFingerprint(for:$0.id)==$0.fingerprint}) {
            searchEpoch += 1;cancelSemanticWork();semanticWorking=false;clearSavedDisplay()
            semanticNotice="The saved photos changed. Ask again to use the current evidence."
        }
    }
    private func retireCombinedSavedDisplay() {
        guard savedQuestionVisible else { return }
        appointments.cancelSavedQuestion()
        savedQuestionVisible = false
        clearSavedDisplay()
    }

    private func dispatchCombinedSavedQuestion(_ question: String) -> Bool {
        guard AppointmentCoordinator.usesCombinedSavedContent,
              PinSavedContentQuestionRouting.owns(question, hasDisplayedAnswer: savedQuestionVisible && savedContext != nil)
        else { return false }
        if !savedQuestionVisible {
            resetSemantic(preservingContinuation: true)
            savedQuestionVisible = true
        }
        submitSavedQuestion(question)
        return true
    }

    private func submitSavedQuestion(_ question:String,requestID:UUID=UUID()) {
        let previous=savedContext
        // A successor keeps its displayed parent; SDK prepare supersedes the
        // old request. Home/source/access cancellation instead retires it.
        semanticWork?.cancel();cancelOriginalViews(close:true)
        searchEpoch += 1;let epoch=searchEpoch
        semanticRequestID=requestID;semanticWorking=true;semanticNotice=nil
        searched=true;submittedQuery=question;interruptedQuestionDraft=question
        PinQuestionTiming.markSaved(requestID,.submitted)
        semanticWork=Task {
            var completed=false
            defer{finishSemanticWork(requestID,completed:completed)}
            do {
                let value=try await appointments.savedQuestion(question,requestID:requestID,previous:previous,library:library)
                PinQuestionTiming.markSaved(requestID,.answerReady)
                guard !Task.isCancelled,semanticRequestID==requestID,searchEpoch==epoch,phase == .active,library.accessReady else{return}
                switch value.answer.meaning.operation {
                case .search,.filter:
                    let cards=value.answer.cards.map {card in
                        SavedScreenshotCard(id:card.recordID,title:card.title?.text ?? "Saved photo",facts:card.facts.map {fact in
                            SavedScreenshotCard.Fact(id:fact.id,text:fact.text,origin:fact.origin == .domainCorrection ? "Your interpretation":"From this photo")
                        } + (value.ownerInterpretations[card.recordID].flatMap {text in
                            card.facts.contains(where:{$0.origin == .domainCorrection && $0.text==text}) ? nil : SavedScreenshotCard.Fact(id:"native-owner-interpretation",text:text,origin:"Your interpretation")
                        }.map{[$0]} ?? []),uncertain:card.relevance == .unclear)
                    }
                    let bound=try value.answer.cards.reduce(into:[String:PhotoMemory]()) {result,card in
                        guard let source=card.sources.first,let memory=library.memories.first(where:{$0.id==source.id && $0.fingerprint==source.fingerprint && $0.revision==source.revision})else{throw PinEvidenceError.staleRecord}
                        result[card.recordID]=memory
                    }
                    let context=try await appointments.publishSavedAnswer(value,orderedRecordIDs:cards.map(\.id),library:library)
                    guard !Task.isCancelled,semanticRequestID==requestID,searchEpoch==epoch,phase == .active,library.accessReady else{return}
                    savedAnswer=value;savedContext=context;savedCards=cards;savedSources=bound
                    completed=true
                    PinQuestionTiming.markSaved(requestID,.displayed)
                case .originals:
                    guard savedAnswer != nil,previous != nil,!value.answer.originals.isEmpty else{throw PinEvidenceError.staleRecord}
                    savedOriginalSequence=value.answer.originals.map{(answer:value,recordID:$0.recordID,position:0)}
                    presentNextSavedOriginal()
                    // The next queued question must not supersede the original
                    // before its source check and presentation have completed.
                    if let opening=originalViewWork{await opening.value}
                    guard !Task.isCancelled,semanticRequestID==requestID,searchEpoch==epoch,
                          appointmentOriginal != nil else{throw PinEvidenceError.staleRecord}
                    completed=true
                    PinQuestionTiming.markSaved(requestID,.displayed)
                case .clarify:
                    semanticNotice="Which saved idea or photo do you mean?" + (savedAnswer == nil ? "":" The results below are from your previous question.")
                    query=question
                case .unsupported:
                    semanticNotice="I couldn’t apply every part of that request to the saved photo evidence." + (savedAnswer == nil ? "":" Your previous results are kept below.")
                    query=question
                }
                semanticWorking=false
            }catch PinDevelopmentError.testEnded {
                guard !Task.isCancelled,semanticRequestID==requestID,searchEpoch==epoch else{return}
                PinQuestionTiming.markSaved(requestID,.expired)
                semanticWorking=false
                semanticNotice="The test connection has ended. Your saved photos, readings and corrections are still available." +
                    (savedAnswer == nil ? "":" The results below are from your previous question.")
                query=question
            }catch {
                guard !Task.isCancelled,semanticRequestID==requestID,searchEpoch==epoch else{return}
                PinQuestionTiming.markSaved(requestID,.failed,error:error)
                semanticWorking=false
                let message: String
                switch error as? PinSavedContentModelUnavailable {
                case .deviceNotEligible:
                    message = "Apple Intelligence is unavailable on this iPhone. You can still browse and search your photos."
                case .appleIntelligenceDisabled:
                    message = "Turn on Apple Intelligence in Settings, then try your question again."
                case .modelNotReady:
                    message = "The on-device reader isn’t ready yet. Try again once Apple Intelligence is ready."
                case .unknown:
                    message = "The on-device reader is temporarily unavailable. Try your question again later."
                case nil:
                    message = "I couldn’t finish that question. Your photos, saved readings and corrections are kept."
                }
                semanticNotice = message + (savedAnswer == nil ? "" : " The results below are from your previous question.")
                query=question
            }
        }
    }
    private func openSavedOriginal(_ value:PinSavedContentAnswer,recordID:String) {
        guard !semanticWorking,phase == .active else{return}
        cancelOriginalViews(close:true)
        savedOriginalSequence=[(answer:value,recordID:recordID,position:0)]
        presentNextSavedOriginal()
    }
    private func presentNextSavedOriginal() {
        guard !savedOriginalSequence.isEmpty else{return}
        let next=savedOriginalSequence.removeFirst(),epoch=searchEpoch,request=UUID()
        originalViewRequestID=request
        originalViewWork=Task {
            do {
                let originals=try await appointments.savedOriginals(next.answer,recordID:next.recordID,library:library)
                guard !Task.isCancelled,request==originalViewRequestID,epoch==searchEpoch,phase == .active,library.accessReady,originals.indices.contains(next.position)else{return}
                if next.position+1<originals.count {savedOriginalSequence.insert((next.answer,next.recordID,next.position+1),at:0)}
                appointmentOriginal=PinOriginalPhotoPresentation(memory:originals[next.position],hasNext:!savedOriginalSequence.isEmpty)
            }catch {
                guard !Task.isCancelled,request==originalViewRequestID else{return}
                savedOriginalSequence=[];originalViewNotice="The photo or its saved interpretation changed. Ask again to check the current source."
            }
        }
    }
    private func requestSavedCorrection(_ value:PinSavedContentAnswer,recordID:String) {
        guard !semanticWorking,phase == .active else{return}
        let epoch=searchEpoch
        Task {
            do {
                let originals=try await appointments.savedOriginals(value,recordID:recordID,library:library)
                guard originals.count==1,let memory=originals.first else{throw PinEvidenceError.staleRecord}
                let source=EvidenceSource(memory),ledger=await library.store.savedPhotoInterpretations()
                guard epoch==searchEpoch,phase == .active,library.accessReady else{return}
                savedCorrection=SavedScreenshotCorrectionTarget(source:source,title:savedCards.first{$0.id==recordID}?.title ?? "Saved photo",expected:ledger.first{$0.source==source})
            }catch{message="This photo changed. Ask again before correcting its interpretation."}
        }
    }
    private func search(selecting id: String? = nil,submittedQuestion:String?=nil) {
        let question = (submittedQuestion ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if PinFreshProductConfiguration.enabled,submittedQuestion==nil {
            PinFreshProductAudit.record(question:question,stage:"input-received")
        }
        if usesNativeQuestionContinuation,
           PinFreshProductSubmission.keepsPendingQuestion(question,activeQuestion:submittedQuery,working:semanticWorking) {
            if submittedQuestion==nil {query="";inputFocused=false}
            PinFreshProductAudit.record(question:question,stage:"duplicate-kept-pending")
            return
        }
        if usesNativeQuestionContinuation,
           freshContinuation.waitingForAccess != nil || !library.accessReady || library.indexing {
            voice.cancel()
            let admission=freshContinuation.waitForAccess(question,context:{$0})
            switch admission {
            case .waiting,.queued,.duplicate:
                if let first=freshContinuation.waitingForAccess{submittedQuery=first.question}
                searched=true
                interruptedQuestionDraft=freshContinuation.pending?.question ?? question
                if submittedQuestion==nil{query="";inputFocused=false}
                let stage=admission == .waiting ? (library.indexing ? "waiting-for-reading":"waiting-for-access"):admission == .queued ? "queued-before-access":"duplicate-kept-waiting"
                PinFreshProductAudit.record(question:question,stage:stage)
            case .full:
                semanticNotice="Your next question is queued. This draft is kept while it finishes."
                PinFreshProductAudit.record(question:question,stage:"queue-full-draft-kept")
            }
            resumeFreshQuestionAfterAccess()
            return
        }
        if usesNativeQuestionContinuation,semanticWorking {
            voice.cancel()
            switch freshContinuation.enqueue(question,after:semanticRequestID,context:semanticRequestID) {
            case .queued,.duplicate:
                interruptedQuestionDraft=question
                if submittedQuestion==nil{query="";inputFocused=false}
                PinFreshProductAudit.record(question:question,stage:"queued-after-active")
            case .full:
                // Keep this unaccepted input editable; never silently replace
                // the already queued question or start concurrent model work.
                semanticNotice="Your next question is queued. This draft is kept while it finishes."
                PinFreshProductAudit.record(question:question,stage:"queue-full-draft-kept")
            }
            return
        }
        if submittedQuestion==nil {
            pendingSubmissionTimingID=PinSealedQualification.usesReviewedSession ? UUID():nil
            PinQuestionTiming.mark(pendingSubmissionTimingID,"input.accepted",flags:["accessReady":library.accessReady,"sourceReaderRunning":appointments.running])
        }
        voice.cancel()
        // Keep an explicit submission through a transient PhotoKit access
        // check. The accessReady observer runs it once sources are confirmed;
        // no retrieval or original opening is allowed before that point.
        submittedQuery = question
        if submittedQuestion==nil {query="";inputFocused=false}
        let nativeContext=(submittedQuestion != nil ? pendingNativeSubmission.flatMap{$0.question==question ? $0:nil}:nil) ?? (question:question,now:Date(),calendar:Calendar.current)
        guard library.accessReady else {
            PinQuestionTiming.mark(pendingSubmissionTimingID,"input.waitingForAccess")
            pendingNativeSubmission=nativeContext;semanticPendingQuestion=question
            return
        }
        PinQuestionTiming.mark(pendingSubmissionTimingID,"input.accessReady")
        if dispatchItinerary(question) { return }
        if dispatchClockSearch(question) { return }
        if savedQuestionVisible, dispatchCombinedSavedQuestion(question) { return }
        if dispatchPlaceQuestionIfSupported(question, requestID: UUID()) {return}
        if AppointmentCoordinator.usesSavedContent {submitSavedQuestion(question);return}
        if PinFreshProductConfiguration.enabled {submitFreshProductQuestion(question,submittedAt:nativeContext.now);return}
        // Explicit native photo predicates stay usable while the paired
        // appointment interpreter is unavailable or still reading meaning.
        if let photoRequest = PhotoQuestion.explicitRequest(question) {
            searchEpoch += 1; resetSemantic(); hits = []; selection = nil; searched = true
            switch photoRequest {
            case .photos(let request):
                guard let plan = PhotoQueryCompiler.compile(request, now: nativeContext.now, calendar: nativeContext.calendar) else {
                    semanticNotice = "I couldn’t resolve that photo date or text. Try a day or week and a quoted phrase."; return
                }
                photoQueryPlan = plan
                refreshResults(for: question, selecting: id)
            case .unsupported:
                semanticNotice = "I couldn’t apply every part of that photo request. Try a photo date and a quoted phrase."
            }
            return
        }
        if PhotoQuestion.isExplicitObjectRecall(question) {
            searchEpoch += 1;resetSemantic();hits=[];selection=nil;searched=true
            refreshResults(for:question,selecting:id)
            return
        }
        if (AppointmentCoordinator.usesDevelopmentSourceReader || AppointmentCoordinator.usesDevelopmentQuestions),appointments.running,
           AppointmentCoordinator.usesDevelopmentQuestions || AppointmentQuestion.explicitRequest(question) != nil || AppointmentQuestion.locationFollowUp(question) != nil {
            PinQuestionTiming.mark(pendingSubmissionTimingID,"input.waitingForSource")
            pendingNativeSubmission=nativeContext;semanticPendingQuestion=question;semanticWorking=true;semanticUpdating=true;searched=true;return
        }
        semanticPendingQuestion=nil;pendingNativeSubmission=nil
        if appointments.hasPendingMeaning,
           AppointmentCoordinator.usesDevelopmentQuestions || AppointmentQuestion.explicitRequest(question) != nil || AppointmentQuestion.locationFollowUp(question) != nil {
            searchEpoch += 1;resetSemantic();hits=[];selection=nil;searched=true
            semanticNotice="Some appointment details are still unresolved. The original photos are available from home."
            return
        }
        if AppointmentCoordinator.usesDevelopmentQuestions {submitRecordQuestion(question);return}
        if case .appointments(let period, let selection) = AppointmentQuestion.explicitRequest(question) {
            showNativeAppointments(question, period: period, selection: selection,now:nativeContext.now,calendar:nativeContext.calendar,preserveDraft:submittedQuestion != nil); return
        }
        if let ordinal = AppointmentQuestion.locationFollowUp(question) {
            retireCombinedSavedDisplay()
            showNativeLocation(question, ordinal: ordinal,preserveDraft:submittedQuestion != nil); return
        }
        if dispatchCombinedSavedQuestion(question) { return }
        if SemanticQueryLab.endpoint != nil && !semanticChoiceMade {
            showSemanticConsent=true;return
        }
        if SemanticQueryLab.endpoint != nil && semanticEnabled { submitSemantic(question);return }
        resetSemantic()
        refreshResults(for: question, selecting: id)
    }
    // Indexing refreshes the submitted question, never the draft or keyboard focus.
    private func refreshResults(for question: String, selecting id: String? = nil) {
        if usesNativeQuestionContinuation,freshContinuation.waitingForAccess != nil {
            resumeFreshQuestionAfterAccess();return
        }
        if let pending=semanticPendingQuestion {
            guard library.accessReady,phase == .active else { return }
            search(submittedQuestion:pending);return
        }
        if itinerary != nil || placeQuestionVisible || personPlansVisible || visitsVisible {return}
        if AppointmentCoordinator.usesSavedContent || savedQuestionVisible {return}
        // Reconciliation revalidates the displayed source projection. It never
        // dispatches another semantic request or broadens an appointment plan.
        if semanticWorking || semanticScope != nil || semanticNotice != nil || semanticSnapshot != nil { return }
        searchEpoch += 1
        let requestEpoch = searchEpoch
        let priorSelection = id ?? selection
        let photoPlan = photoQueryPlan
        Task {
            let candidates:[RecallHit]
            if let photoPlan {
                candidates = await library.store.photos(matching: photoPlan).hits
            } else if semanticPlan == nil && AppointmentQuestion.explicitRequest(question) != nil {
                candidates=[]
            } else if semanticPlan == .museums || (semanticPlan == nil && MuseumQuestion.matches(question)) {
                candidates=await library.store.all().filter(MuseumPhotoReader.isCandidate).map { RecallHit(memory:$0,score:1) }
            } else { candidates=await library.store.find(question) }
            let native=await Task.detached(priority:.utility) {
                PhotoLibrary.currentFingerprints(for:candidates.map(\.id))
            }.value
            // Re-execute the fixed photo predicates against current actor-owned
            // observations after the PhotoKit check; never publish old metadata
            // or add a source whose native version was not checked.
            let latestPhotoResult = if let photoPlan { await library.store.photos(matching: photoPlan) } else { nil as PhotoQueryResult? }
            let validated=await library.store.validatedHits(latestPhotoResult?.hits ?? candidates)
            let currentHits=validated.filter { native[$0.id] == $0.memory.fingerprint }
            guard requestEpoch == searchEpoch, library.authorized, library.accessReady else { return }
            photoQueryResult = latestPhotoResult
            hits = currentHits
            selection = currentHits.contains(where: { $0.id == priorSelection }) ? priorSelection : currentHits.first?.id
            searched = true
        }
    }
    private func preserveQueuedQuestionDraft() {
        interruptedQuestionDraft=freshContinuation.pending?.question ?? freshContinuation.waitingForAccess?.question ?? submittedQuery
        freshContinuation.cancel()
    }
    private func resumeFreshQuestionAfterAccess() {
        guard usesNativeQuestionContinuation,library.authorized,!semanticWorking,
              let first=freshContinuation.takeWaitingForAccess(accessReady:library.accessReady,foreground:phase == .active,sourceReaderRunning:library.indexing)else{return}
        PinFreshProductAudit.record(question:first.question,stage:"access-ready-dispatch")
        if AppointmentCoordinator.usesCombinedSavedContent {
            search(submittedQuestion: first.question)
            return
        }
        if dispatchPlaceQuestionIfSupported(first.question, requestID: first.requestID) {return}
        if AppointmentCoordinator.usesSavedContent {submitSavedQuestion(first.question,requestID:first.requestID)}
        else if PinFreshProductConfiguration.enabled {submitFreshProductQuestion(first.question,submittedAt:first.submittedAt,requestID:first.requestID)}
        else {search(submittedQuestion:first.question)}
    }
    private func restoreInterruptedQuestionDraft() {
        guard usesNativeQuestionContinuation,query.isEmpty,!interruptedQuestionDraft.isEmpty else{return}
        query=interruptedQuestionDraft;interruptedQuestionDraft=""
    }
    private func cancelSemanticWork(preservingContinuation:Bool=false) {
        appointments.cancelSavedQuestion(ifActiveRequestID:semanticRequestID)
        if (AppointmentCoordinator.usesSavedContent || savedQuestionVisible) && semanticWorking {
            PinQuestionTiming.markSaved(semanticRequestID,.cancelled)
        }
        if !preservingContinuation{freshContinuation.cancel();interruptedQuestionDraft=""}
        updateForegroundRequestLease(active:false)
        PinQuestionTiming.mark(semanticRequestID,"ui.cancel")
        semanticRequestID=UUID();semanticWork?.cancel()
    }
    private func updateForegroundRequestLease(active:Bool) {
        if let value=foregroundRequestLease.update(working:semanticWorking,active:active,currentValue:UIApplication.shared.isIdleTimerDisabled) {
            UIApplication.shared.isIdleTimerDisabled=value
        }
    }
    private func finishSemanticWork(_ requestID:UUID,completed:Bool=false) {
        // Authority invalidation may change searchEpoch without creating a
        // replacement task. The completed task must still end its own spinner.
        guard semanticRequestID==requestID else{return}
        if semanticWorking {
            PinQuestionTiming.mark(requestID,completed ? "ui.receivedWithQueuedInput":"ui.finishedWithoutPublication")
            semanticWorking=false;semanticUpdating=false
            if !completed,semanticNotice==nil {semanticNotice="That question was interrupted. Your saved details are kept."}
        }
        guard let next=freshContinuation.take(after:requestID)else{
            if completed{interruptedQuestionDraft=""}else{restoreInterruptedQuestionDraft()}
            return
        }
        if completed,phase == .active,library.authorized,library.accessReady,next.context==requestID {
            interruptedQuestionDraft=""
            if AppointmentCoordinator.usesCombinedSavedContent {
                search(submittedQuestion: next.question)
                return
            }
            if dispatchPlaceQuestionIfSupported(next.question, requestID: UUID()) {return}
            if AppointmentCoordinator.usesSavedContent {submitSavedQuestion(next.question)}
            else if PinFreshProductConfiguration.enabled {submitFreshProductQuestion(next.question,submittedAt:next.submittedAt)}
            else {search(submittedQuestion:next.question)}
        }else{
            interruptedQuestionDraft=next.question
            restoreInterruptedQuestionDraft()
            semanticNotice="The earlier question did not finish with a usable answer. Your question text is kept."
        }
    }
    private func clearUnitDisplay() {
        if let context=unitContext{appointments.clearDisplayedUnits(context)}
        unitContext=nil;unitAnswer=nil;unitEvidenceAnswer=nil;linkedUnitAnswer=nil
    }
    private func dispatchItinerary(_ question: String) -> Bool {
        guard let answer = RailItinerary.answer(question, photos: library.memories) else {
            itinerary = nil
            return false
        }
        searchEpoch += 1
        resetSemantic()
        hits = []; selection = nil; searched = true
        submittedQuery = question
        interruptedQuestionDraft = ""
        itinerary = answer
        if answer.needsModel {
            itineraryWork = Task {
                do {
                    let decision = try await NativItinerary.interpret(question)
                    guard !Task.isCancelled, itinerary?.id == answer.id, library.accessReady else { return }
                    itineraryDecision = decision
                    itinerary = RailItinerary.answer(question, photos: library.memories, decision: decision)
                } catch {
                    guard !Task.isCancelled, itinerary?.id == answer.id else { return }
                    var unavailable = answer
                    unavailable.summary = "The local Nativ model is unavailable."
                    itinerary = unavailable
                }
            }
        }
        return true
    }
    private func resetSemantic(keepingUnits:Bool=false,preservingContinuation:Bool=false) {
        itineraryWork?.cancel(); itineraryWork = nil; itineraryDecision = nil; itinerary = nil
        clearClockSearch()
        retireCombinedSavedDisplay()
        clearSavedDisplay()
        clearPlaceDisplay()
        placeQuestionVisible = false
        personPlans = nil
        personPlanCorrection = nil
        personPlansVisible = false
        visits = nil
        visitsVisible = false
        // A new submission retires the prior linked answer's ephemeral handle.
        // Its unchanged displayed inventory remains the continuation owner.
        linkedUnitAnswer=nil
        correctedPresentation=nil
        if !keepingUnits{clearUnitDisplay()}
        productPublishedParent=nil
        exhaustivePresentationContext=nil
        exhaustiveAnswer=nil
        if PinFreshProductConfiguration.enabled{appointments.cancelFreshProductQuestion()}
        cancelOriginalViews(close:true,clearNotice:true)
        photoQueryPlan = nil; photoQueryResult = nil
        cancelSemanticWork(preservingContinuation:preservingContinuation); semanticWork=nil; semanticWorking=false;semanticPendingQuestion=nil;pendingNativeSubmission=nil
        semanticNotice=nil; semanticPlan=nil; semanticSnapshot=nil;semanticScope=nil;semanticScopeMeaning=nil
        semanticUpdating=false; semanticAnswerUpdate=nil; showAppointmentUpdate=false
        semanticContext=nil; semanticContextPeriod=nil;semanticContextQuestion=nil;recordQuestionContext=nil;recordChangeFields=nil
    }
    private func submitFreshProductQuestion(_ question:String,submittedAt:Date=Date(),requestID:UUID=UUID()) {
        let previous=recordQuestionContext,previousSnapshot=semanticSnapshot,previousExhaustive=exhaustiveAnswer,previousPublication=productPublishedParent,previousUnits=unitContext,previousLinkedPresentation=linkedUnitAnswer?.displayedAnswer
        resetSemantic(keepingUnits:previousUnits != nil,preservingContinuation:true);searchEpoch += 1;let epoch=searchEpoch
        submittedQuery=question
        recordQuestionContext=previous;productPublishedParent=previousPublication
        interruptedQuestionDraft=question
        searched=true;hits=[];selection=nil;semanticRequestID=requestID;semanticWorking=true
        PinFreshProductAudit.record(question:question,stage:"submitted")
        semanticWork=Task {
            var completed=false
            defer{finishSemanticWork(requestID,completed:completed)}
            do {
                let result=try await appointments.freshProductQuestion(question,previous:previous,parentPublication:previousPublication?.selecting(previous?.selectedOrdinal),library:library,requestID:requestID,previousUnits:previousUnits,submissionTime:submittedAt)
                guard !Task.isCancelled,searchEpoch==epoch,phase == .active,library.authorized,library.accessReady else{
                    PinFreshProductAudit.recordLifecycle(stage:"lateQuestionDiscarded",requestID:requestID,epoch:searchEpoch,busy:semanticWorking)
                    return
                }
                semanticWorking=false
                switch result {
                case .units(let answer,let reconciliation):
                    semanticWorking=true;unitContext=nil;productPublishedParent=nil
                    unitAnswer=answer;unitEvidenceAnswer=nil;linkedUnitAnswer=nil
                    let context=try await appointments.contextForDisplayedUnits(answer,library:library)
                    guard !Task.isCancelled,searchEpoch==epoch,phase == .active,unitAnswer?.requestID==answer.requestID,library.accessReady else{if let context{appointments.clearDisplayedUnits(context)};return}
                    unitContext=context
                    productPublishedParent=context.map{PinProductPublishedParent(unitContext:$0,reconciliation:reconciliation)}
                    semanticWorking=false
                    PinFreshProductAudit.recordUnits(question:question,answer:answer,parent:productPublishedParent)
                case .unitContextual(let answer):
                    guard let previousUnits,unitContext?.id==previousUnits.id else{throw PinEvidenceError.staleRecord}
                    unitEvidenceAnswer=answer;linkedUnitAnswer=nil;productPublishedParent=previousPublication
                    if let parent=productPublishedParent{PinFreshProductAudit.recordUnitContextual(question:question,answer:answer,parent:parent)}
                    if freshContinuation.pending==nil,(answer.operation=="currentOriginals" || answer.operation=="sourceEvidenceAndCurrentOriginals") {presentUnitOriginal(answer.selection,position:0)}
                case .unitLinkedContextual(let answer):
                    guard let previousUnits,unitContext?.id==previousUnits.id,answer.contextID==previousUnits.id else{throw PinEvidenceError.staleRecord}
                    try await appointments.readmitLinkedUnitAnswer(answer,library:library)
                    guard !Task.isCancelled,searchEpoch==epoch,phase == .active,unitContext?.id==previousUnits.id,library.accessReady else{return}
                    semanticWorking=true
                    let presentation=try await appointments.presentationForLinkedUnitOriginal(answer,previous:previousLinkedPresentation,library:library)
                    guard !Task.isCancelled,searchEpoch==epoch,phase == .active,unitContext?.id==previousUnits.id,library.accessReady else{return}
                    linkedUnitAnswer=PinLinkedUnitViewState(answer,displayedAnswer:presentation);unitEvidenceAnswer=nil
                    let published=try await appointments.contextForDisplayedLinkedUnits(answer,library:library)
                    guard !Task.isCancelled,searchEpoch==epoch,phase == .active,unitContext?.id==previousUnits.id,library.accessReady else{return}
                    unitContext=published
                    productPublishedParent=PinProductPublishedParent(unitContext:published,reconciliation:previousPublication?.reconciliation)
                    semanticWorking=false
                    if let parent=productPublishedParent{PinFreshProductAudit.recordLinkedUnitContextual(question:question,answer:answer,parent:parent)}
                    if freshContinuation.pending==nil,let first=answer.originalSelections.first {
                        remainingUnitOriginals=Array(answer.originalSelections.dropFirst());presentUnitOriginal(first,position:0)
                    }
                case .inventory(let answer,let reconciliation):
                    exhaustiveAnswer=answer
                    productPublishedParent=PinProductPublishedParent(requestSHA256:answer.receipt.requestSHA256,displayedRecordIDs:(answer.displayRows+answer.uncertain).compactMap(\.canonicalRecordID),reconciliation:reconciliation)
                    PinFreshProductAudit.record(question:question,stage:"presented",rows:answer.displayRows+answer.uncertain,answer:answer,reconciliation:reconciliation)
                    if let context=try? await appointments.contextForDisplayedProductAnswer(answer,library:library) {
                        guard !Task.isCancelled,searchEpoch==epoch,phase == .active,exhaustiveAnswer?.requestID==answer.requestID,library.accessReady else{return}
                        recordQuestionContext=context
                    }
                case .contextual(let answer):
                    try presentRecordAnswer(answer,previous:previous,previousSnapshot:previousSnapshot)
                    if answer.route=="originals" {
                        exhaustiveAnswer=previousExhaustive;exhaustivePresentationContext=answer.context
                        productPublishedParent=previousPublication?.selecting(answer.context?.selectedOrdinal)
                    }else if let context=answer.context {
                        productPublishedParent=PinProductPublishedParent(requestSHA256:answer.receipt.requestSHA256,displayedRecordIDs:(answer.matched+answer.unresolved).compactMap(\.canonicalRecordID),selectedOrdinal:context.selectedOrdinal)
                    }else{productPublishedParent=previousPublication}
                    PinFreshProductAudit.recordContextual(question:question,stage:"presented",answer:answer)
                case .unsupported:
                    semanticNotice="I couldn’t apply every part of that question to the available appointment evidence."
                    recordQuestionContext=previous
                    productPublishedParent=previousPublication
                    PinFreshProductAudit.record(question:question,stage:"unsupported")
                }
                if case .unsupported=result {completed=false}else{completed=true}
            }catch is CancellationError {
                completed=false
                guard searchEpoch==epoch else{return};semanticWorking=false
            }catch {
                completed=false
                guard searchEpoch==epoch else{return};semanticWorking=false
                if unitContext==nil{unitAnswer=nil;unitEvidenceAnswer=nil;linkedUnitAnswer=nil}
                PinFreshProductAudit.record(question:question,stage:"failed",error:String(describing:error))
                semanticNotice=PinFreshProductFailure.notice(for:error)
                if unitContext != nil {
                    semanticNotice=(semanticNotice ?? "")+" The results below are from your previous question."
                }
            }
        }
    }
    private func presentRecordAnswer(_ answer:PinRecordQuestionAnswer,previous:PinRecordQuestionContext?,previousSnapshot:SemanticAppointmentSnapshot?)throws {
    switch answer.route {
    case "list":
        guard let context=answer.context else{throw PinEvidenceError.staleRecord}
        let native=AppointmentAnswer(window:context.window,selection:.any,matches:answer.matched,uncertain:answer.unresolved,coverage:library.indexing ? .incomplete:.unknown)
        semanticSnapshot = .list(native);semanticContext=AppointmentConversationContext(answerID:context.answerID,answer:native,includingUncertain:true);recordQuestionContext=context
    case "changes":
        guard let context=answer.context,let fields=answer.requestedChangeFields else{throw PinEvidenceError.staleRecord}
        recordQuestionContext=context
        if answer.matched.isEmpty {semanticNotice="I haven’t found retained changes in the current appointment photos."}
        else {
            let native=AppointmentAnswer(window:context.window,selection:.any,matches:answer.matched,uncertain:answer.unresolved,coverage:library.indexing ? .incomplete:.unknown)
            semanticSnapshot = .list(native);semanticContext=AppointmentConversationContext(answerID:context.answerID,answer:native,includingUncertain:true)
            recordChangeFields=Dictionary(uniqueKeysWithValues:answer.matched.map{($0.id,fields)})
        }
    case "location":
        guard let context=answer.context,answer.matched.count==1 else{throw PinEvidenceError.staleRecord}
        let native=AppointmentAnswer(window:context.window,selection:.any,matches:answer.ordered,uncertain:[],coverage:.unknown)
        var references=AppointmentConversationContext(answerID:context.answerID,answer:native)
        guard references.select(answer.matched[0],items:appointments.items,originals:library.memories)else{throw PinEvidenceError.staleRecord}
        semanticContext=references;recordQuestionContext=context;semanticSnapshot = .location(answer.matched[0])
    case "originals":
        guard let context=answer.context,answer.matched.count==1 else{throw PinEvidenceError.staleRecord}
        recordQuestionContext=context
        semanticSnapshot=previousSnapshot?.refreshed(items:appointments.items,originals:library.memories)
        if semanticSnapshot==nil {semanticNotice="Original photos for \(answer.matched[0].observation.title)."}
    case "clarify":
        semanticNotice=answer.clarification ?? "Which photographed appointment do you mean?"
        recordQuestionContext=answer.context
    case "unsupported","partial":
        semanticNotice=answer.clarification ?? "I couldn’t apply every part of that question to the available appointment evidence."
        // No new list was shown. Preserve only the last context
        // actually presented, not an unshown partial-result list.
        recordQuestionContext=previous
    default:
        semanticNotice="Pin can’t present that comparison here yet. The original appointment photos remain available from home."
    }
    if let issue=answer.originalViewIssue {originalViewNotice=originalViewMessage(issue)}
    if let request=answer.originalViewRequest,AppointmentCoordinator.usesOriginalViewDevelopmentQuestions {
        presentOriginalView(request)
    }
    }
    private func submitRecordQuestion(_ question:String) {
        let submissionTimingID=pendingSubmissionTimingID
        pendingSubmissionTimingID=nil
        let previous=recordQuestionContext,previousSnapshot=semanticSnapshot
        cancelOriginalViews(close:true,clearNotice:true)
        searchEpoch += 1;let epoch=searchEpoch;cancelSemanticWork()
        semanticWorking=true;semanticUpdating=false;semanticNotice=nil;semanticSnapshot=nil;semanticPlan=nil;semanticScope=nil;semanticScopeMeaning=nil;recordChangeFields=nil
        photoQueryPlan=nil;photoQueryResult=nil;hits=[];selection=nil;searched=true;showAppointmentUpdate=false;semanticAnswerUpdate=nil
        let requestID=semanticRequestID
        PinQuestionTiming.mark(requestID,"ui.begin",submissionID:submissionTimingID)
        semanticWork=Task {
            defer{finishSemanticWork(requestID)}
            do {
                let answer=try await appointments.recordQuestion(question,previous:previous,timingID:requestID)
                PinQuestionTiming.mark(requestID,"ui.answerReturned",flags:["epochMatches":epoch==searchEpoch,"accessReady":library.accessReady,"active":phase == .active,"authorized":library.authorized])
                guard !Task.isCancelled,epoch==searchEpoch,phase == .active,library.authorized,library.accessReady else{return}
                PinQuestionTiming.mark(requestID,"ui.publish")
                semanticWorking=false
                try presentRecordAnswer(answer,previous:previous,previousSnapshot:previousSnapshot)
                semanticContextQuestion=question
            }catch is CancellationError {PinQuestionTiming.mark(requestID,"ui.cancelled")}
            catch {
                PinQuestionTiming.mark(requestID,"ui.error",flags:["epochMatches":epoch==searchEpoch])
                guard epoch==searchEpoch else{return};semanticWorking=false
                switch PinRecordQuestionIssue.classify(error) {
                case .staleContext:semanticNotice="That appointment answer changed or is no longer available. Return home for a fresh answer."
                case .unapproved:semanticNotice="This question or its context isn’t approved for the isolated fictional test."
                case .testEnded:semanticNotice="This sample test has ended. Your saved photo details are still available from home."
                case .unavailable:semanticNotice="The paired question interpreter is unavailable. Your saved photos and appointment details are kept."
                }
            }
        }
    }
    private func submitSemantic(_ question:String) {
        semanticUpdating=false; showAppointmentUpdate=false
        let previous=semanticContext, previousPeriod=semanticContextPeriod, previousQuestion=semanticContextQuestion
        let now=Date(), calendar=Calendar.current, requestID=UUID()
        let receipt=AppointmentAnswerReceipt(requestID:requestID,period:.all,now:now,calendar:calendar,items:appointments.items,originals:library.memories)
        searchEpoch += 1;let epoch=searchEpoch
        cancelSemanticWork();semanticWorking=true;semanticNotice=nil;semanticPlan=nil;semanticSnapshot=nil;semanticScope=nil;semanticScopeMeaning=nil
        hits=[];selection=nil;searched=true
        semanticWork=Task {
            do {
                let context=SemanticQueryLab.Context(previousIntent:previous == nil ? nil : "appointments",previousPeriod:previousPeriod,previousQuestion:previousQuestion,resultCount:previous?.resultCount ?? 0,selectedOrdinal:previous?.selectedOrdinal,previousSelection:previous?.selection.rawValue)
                let interpretation=try await SemanticQueryLab.interpret(question,id:requestID,context:context,now:now,calendar:calendar)
                guard epoch==searchEpoch,semanticEnabled,phase == .active else { return }
                let records=AppointmentAnswerEngine.currentRecords(appointments.items,originals:library.memories)
                let native=await Task.detached(priority:.utility) { PhotoLibrary.currentFingerprints(for:records.map(\.id)) }.value
                guard epoch==searchEpoch,semanticEnabled else { return }
                guard library.authorized,library.accessReady,
                      receipt.isCurrent(requestID:requestID,now:Date(),calendar:Calendar.current,items:appointments.items,originals:library.memories),
                      calendar.isDate(now,inSameDayAs:Date()),records.allSatisfy({native[$0.id]==$0.source.fingerprint}) else {
                    semanticWorking=false;semanticNotice="The available appointment details changed while I was reading your question. Ask again for the current answer.";return
                }
                let meaning=interpretation.meaning
                let admission=interpretation.proposal?.admission(question:question,requestID:requestID,now:now,calendar:calendar,
                    previous:previous,items:appointments.items,originals:library.memories)
                    ?? AppointmentScopeAdmission.resolve(meaning,evidence:interpretation.scope,question:question,
                        requestID:requestID,now:now,calendar:calendar,previous:previous,items:appointments.items,originals:library.memories)
                switch admission {
                case .clarify(let pending):
                    semanticWorking=false;semanticScope=pending;semanticScopeMeaning=meaning
                case .plan(let plan):
                    presentSemanticPlan(plan,meaning:meaning,question:question,previous:previous,previousPeriod:previousPeriod,
                        requestID:requestID,now:now,calendar:calendar)
                }
            } catch {
                guard epoch==searchEpoch else { return }
                semanticWorking=false
                if let failure=error as? SemanticQueryLab.Failure {
                    switch failure {
                    case .unlistedQuestion: semanticNotice="This isolated test accepts only its fictional test questions. Your question was not sent to the model."
                    case .uncertain: semanticNotice="I couldn’t confidently understand that request. Try asking another way."
                    default: semanticNotice="Question interpretation is unavailable. Your photos and saved readings are kept."
                    }
                } else { semanticNotice="Question interpretation couldn’t finish. Your photos and saved readings are kept." }
            }
        }
    }

    private func presentSemanticPlan(_ plan:MemoryQueryPlan, meaning:MemoryQueryMeaning, question:String,
                                     previous:AppointmentConversationContext?, previousPeriod:String?,
                                     requestID:UUID, now:Date, calendar:Calendar) {
        if let explicit = AppointmentQuestion.explicitRequest(question),
           !AppointmentQuestion.mayPresent(plan, for: explicit, now: now, calendar: calendar) {
            semanticPlan = .unclear; semanticWorking = false
            semanticNotice = "I couldn’t safely match that appointment request. Please ask again or open Appointments from your photos."
            return
        }
        semanticPlan=plan;semanticWorking=false
        switch plan {
        case .appointments, .appointmentSubset:
            guard case .answer(let answer) = MemoryQueryExecutor.appointments(plan,previous:previous,items:appointments.items,originals:library.memories,coverage:library.indexing ? .incomplete : .unknown) else {
                semanticNotice="Those appointment results changed or are no longer available. Ask about your appointments again.";return
            }
            semanticSnapshot = .list(answer)
            semanticAnswerUpdate=AppointmentAnswerUpdate(plan:plan,answer:answer,now:now,calendar:calendar)
            semanticContext=AppointmentConversationContext(answerID:requestID,answer:answer)
            semanticContextPeriod=meaning.period == .inherit ? previousPeriod : meaning.period.rawValue
            semanticContextQuestion=question
        case .appointmentLocation(let ordinal):
            guard let previous else { semanticNotice="Ask about your appointments first so I know which one you mean.";return }
            let location=previous.location(of:ordinal,answerID:previous.answerID,items:appointments.items,originals:library.memories)
            if case .location=location,let item=previous.item(of:ordinal,answerID:previous.answerID,
                items:appointments.items,originals:library.memories) {
                semanticContext?.select(item, items: appointments.items, originals: library.memories)
                semanticSnapshot = .location(item)
            }
            else if location == .unknownLocation { semanticNotice="I couldn’t find a location in that appointment’s photo." }
            else { semanticNotice="That appointment changed or is no longer available. Ask about your appointments again." }
        case .photos,.museums:
            semanticAnswerUpdate=nil
            semanticContext=nil;semanticContextPeriod=nil;semanticContextQuestion=nil
            refreshResults(for:question)
        case .needsContext:
            semanticNotice = meaning.reference == .selected && (previous?.resultCount ?? 0) > 1
                ? "Which appointment do you mean?"
                : "Ask about your appointments first so I know which one you mean."
        case .needsDate: semanticNotice="I couldn’t resolve the requested date. Which day or week do you mean?"
        case .unsupported: semanticNotice="I can’t yet answer all parts of that request from your photos."
        case .unclear: semanticNotice="I couldn’t tell which information you want. Try asking about your appointments or a photo."
        }
    }

    private func resolveAppointmentScope(_ selection:AppointmentSelection) {
        guard let pending=semanticScope,let meaning=semanticScopeMeaning,
              library.authorized,library.accessReady,phase == .active else { return }
        let question=submittedQuery,previous=semanticContext,previousPeriod=semanticContextPeriod
        let now=Date(),calendar=Calendar.current,epoch=searchEpoch
        let records=AppointmentAnswerEngine.currentRecords(appointments.items,originals:library.memories)
        semanticWorking=true;inputFocused=false
        semanticWork=Task {
            let native=await Task.detached(priority:.utility) { PhotoLibrary.currentFingerprints(for:records.map(\.id)) }.value
            guard epoch==searchEpoch,semanticEnabled,phase == .active else { return }
            semanticWorking=false
            guard library.authorized,library.accessReady,
                  records.allSatisfy({native[$0.id]==$0.source.fingerprint}),
                  let plan=pending.resolve(selection,requestID:pending.requestID,previous:semanticContext,
                      now:Date(),calendar:Calendar.current,items:appointments.items,originals:library.memories) else {
                semanticScope=nil;semanticScopeMeaning=nil
                semanticNotice="Those appointment details or dates changed. Ask again for the current answer.";return
            }
            semanticScope=nil;semanticScopeMeaning=nil
            presentSemanticPlan(plan,meaning:meaning,question:question,previous:previous,previousPeriod:previousPeriod,
                requestID:pending.requestID,now:now,calendar:calendar)
        }
    }

    private func updateAppointmentAnswer() {
        guard let update=semanticAnswerUpdate, showAppointmentUpdate,
              library.authorized, library.accessReady, phase == .active else { return }
        let now=Date(), calendar=Calendar.current, requestID=UUID()
        let receipt=AppointmentAnswerReceipt(requestID:requestID,period:.all,now:now,calendar:calendar,items:appointments.items,originals:library.memories)
        let records=AppointmentAnswerEngine.currentRecords(appointments.items,originals:library.memories)
        searchEpoch += 1; let epoch=searchEpoch
        cancelSemanticWork(); semanticUpdating=true; semanticWorking=true; inputFocused=false
        semanticWork=Task {
            let native=await Task.detached(priority:.utility) { PhotoLibrary.currentFingerprints(for:records.map(\.id)) }.value
            guard epoch==searchEpoch, phase == .active else { return }
            semanticWorking=false; semanticUpdating=false
            guard library.authorized, library.accessReady,
                  receipt.isCurrent(requestID:requestID,now:Date(),calendar:Calendar.current,items:appointments.items,originals:library.memories),
                  records.allSatisfy({native[$0.id]==$0.source.fingerprint}) else {
                semanticNotice="Photo details are changing. Update the list once they finish."; return
            }
            guard let answer=update.answer(now:Date(),calendar:Calendar.current,items:appointments.items,originals:library.memories,coverage:library.indexing ? .incomplete : .unknown) else {
                showAppointmentUpdate=false
                semanticNotice="The date context changed. Ask about your appointments again for the dates you want."; return
            }
            semanticSnapshot = .list(answer); semanticNotice=nil; showAppointmentUpdate=false
            semanticPlan=update.plan
            semanticAnswerUpdate=AppointmentAnswerUpdate(plan:update.plan,answer:answer,now:Date(),calendar:Calendar.current)
            semanticContext=AppointmentConversationContext(answerID:requestID,answer:answer)
            query=semanticContextQuestion ?? "Appointments"; submittedQuery=query
            homeRevision += 1
        }
    }

    private func openOriginal(_ hit: RecallHit) {
        Task {
            do {
                _ = try await library.store.current(hit)
                guard PhotoLibrary.currentFingerprint(for:hit.id) == hit.memory.fingerprint else { throw PinStoreError.staleResult }
                showOriginal = true
            }
            catch { hits = []; searched = false; message = "This photo changed or is no longer available to Pin. Please search again." }
        }
    }
    private func requestOwnerCorrection(_ item:AppointmentItem) {
        guard phase == .active,library.authorized,library.accessReady,appointments.items.contains(item),item.canonicalRecordID != nil else{return}
        searchEpoch += 1;cancelSemanticWork();semanticWorking=false;appointments.cancelFreshProductQuestion()
        cancelOriginalViews(close:true);ownerCorrectionTarget=PinOwnerCorrectionTarget(item)
    }
    private func openCorrectedOriginal(_ target:PinOwnerCorrectionTarget,source:AppointmentSource) {
        let epoch=searchEpoch
        Task {do {
            let memory=try await appointments.originalForCorrectedRecord(target.item,source:source,library:library)
            guard epoch==searchEpoch,phase == .active,library.accessReady,correctedPresentation?.id==target.id,appointments.items.contains(target.item)else{return}
            appointmentOriginal=PinOriginalPhotoPresentation(memory:memory,hasNext:false)
        }catch{message="These event details or their photo changed. Reopen the current event."}}
    }
    private func requestForget(_ memory: PhotoMemory) {
        clearPlaceDisplay()
        personPlans = nil
        personPlanCorrection = nil
        visits = nil
        clearSavedDisplay()
        cancelSemanticWork();semanticWorking=false
        clearUnitDisplay();appointments.cancelFreshProductQuestion()
        cancelOriginalViews(close:true)
        forgetTarget = memory
        showForget = true
    }
    private func forgetConfirmedSource() {
        guard let target = forgetTarget else { return }
        cancelOriginalViews(close:true)
        forgetTarget = nil
        let epoch = searchEpoch
        let wasSemanticAppointment = semanticSnapshot != nil
        Task {
            guard await library.forget(target) else { return }
            #if canImport(FoundationModels)
            localPlaceReader = nil
            #endif
            appointments.synchronize(library.memories, photoStore: library.store)
            guard epoch == searchEpoch else { return }
            searchEpoch += 1
            if AppointmentCoordinator.usesSavedContent || savedQuestionVisible || SavedPlacesDevelopmentControl.enabled || placeQuestionVisible || personPlansVisible || visitsVisible {
                clearSavedDisplay();semanticNotice="Forgotten by Pin. The original is still in Photos.";searched=true;return
            }
            hits.removeAll { $0.id == target.id }
            selection = hits.first?.id
            if wasSemanticAppointment {
                semanticSnapshot = nil
                semanticNotice = "Forgotten by Pin. The original is still in Photos."
                showAppointmentUpdate = semanticAnswerUpdate != nil
                searched = true
                // Keep old ordered references stale; never renumber them after withdrawal.
            } else {
                searched = photoQueryPlan != nil || !hits.isEmpty || MuseumQuestion.matches(submittedQuery)
            }
        }
    }
    private func toggleVoice() {
        if voice.active { voice.stop(); return }
        Task {
            do { try await voice.start(onPartial: { query = $0 }, onComplete: { query = $0; search() }, onFailure: { message = $0.localizedDescription }) }
            catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
}
