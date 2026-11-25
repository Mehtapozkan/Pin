import PinCore
import PinMemory
import IBrainSemantics
import IBrainVision
import SwiftUI
import UserNotifications
import CryptoKit
import Photos

private struct FreshUnitReplacementJournal:Codable {
    let transactionID:UUID
    let sourceAfter:EvidenceSource
    let acquisitionID:UUID
    var proof:PinUnitSourceEvidence?
}

private actor FreshInitialEnvelopeGate {
    var expected:String?
    init(_ expected:String){self.expected=expected}
    func take()->String?{defer{expected=nil};return expected}
}

enum SavedInterpretationSaveResult { case ready, preparationPending }

struct AppointmentNotificationContext: Equatable { let sourceID: String; let fingerprint: String }
@MainActor final class AppointmentCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var items: [AppointmentItem] = []
    @Published var message: String?
    @Published var notificationContext: AppointmentNotificationContext?
    @Published var notificationsAvailable = false
    private var repository: AppointmentStore?
    private var projectionCache: PinAppointmentProjectionCache?
    private var savedContentCache: PinAppointmentProjectionCache?
    private var savedContentRequestID: UUID?
    private var savedContentProvider: (any DecisionProvider)?
    private var savedContentPair: PinSavedContentReplayPair?
    private var savedContentPairBytes: Data?
    @Published private(set) var savedContentStage: PinSavedContentStage?
    private struct SavedBinding: Equatable {
        let memories: [PhotoMemory]
        let interpretations: [SavedPhotoInterpretation]
    }
    private var combinedSavedBinding: SavedBinding?
    private var combinedSavedPreparation = UUID()

    static var usesCombinedSavedContent: Bool {
        #if DEBUG && PIN_COMBINED_SAVED_CONTENT && canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            #if PIN_SAVED_PLACES_COMBINED_REVIEW
            if Bundle.main.bundleIdentifier == "app.pin.savedplacescandidate" { return true }
            #endif
            return Bundle.main.bundleIdentifier == "app.pin.journeyscandidate"
        }
        #endif
        return false
    }
    static var usesSavedContent: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier == "app.pin.savedcandidate" && ProcessInfo.processInfo.arguments.contains("--test-saved-content")
        #elseif DEBUG
        return PinSavedContentPhoneProfile.enabled
        #else
        return false
        #endif
    }
    private var processingScope:PinNativePhotoProcessingScope?
    private func processingMemories(_ memories:[PhotoMemory])->[PhotoMemory] {processingScope?.memories(memories) ?? memories}
    private func processingRecords(_ rows:[AppointmentItem])->[AppointmentItem] {processingScope?.records(rows) ?? rows}
    private var questionPhotoStore:PinCore.MemoryStore?
    private var work: Task<Void, Never>?
    private var generation = 0
    private var freshRequestID:UUID?
    @Published private(set) var freshQuestionPhase:PinQuestionWorkPhase?
    private var freshRereadSources:Set<EvidenceSource>=[]
    private var freshTemporalGroups:[String:PinVisualGroupContext]=[:]
    private var freshTemporalContexts:[String:TemporalRoleExplanationContext]=[:]
    private var freshTemporalCache:[String:PinTemporalRoleReading]=[:]
    @Published private(set) var freshTemporalReadings:[String:PinTemporalRoleReading]=[:]
    private var freshTemporalAnswerID:UUID?
    private var freshTemporalArchive:URL {PinPublicProductScope.applicationDirectory(FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]).appendingPathComponent("derived-clock-explanations-v1")}
    private var freshTemporalPreparations:URL {freshTemporalArchive.deletingLastPathComponent().appendingPathComponent("derived-clock-preparations-v1")}
    @Published private(set) var running = false
    @Published private(set) var hasPendingMeaning = false
    private var activeSources: [String: AppointmentSource] = [:]
    private var queuedMemories: [PhotoMemory]?
    private let center = UNUserNotificationCenter.current()
    private let prefix = "pin.appointment."
    override convenience init() {
        self.init(connectionProbeOnly: false)
    }
    init(connectionProbeOnly: Bool) {
        super.init()
        guard !connectionProbeOnly else { return }
        center.delegate = self
        openRepositoryIfAvailable()
    }
    private func openRepositoryIfAvailable() {
        guard repository == nil, UIApplication.shared.isProtectedDataAvailable else { return }
        do {
            let base = PinPublicProductScope.applicationDirectory(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            if Self.usesSavedContent {
                _ = try openSavedContentCache()
                try loadSavedContentPairIfNeeded()
                return
            }
            let processingScope=try PinFreshProductConfiguration.localNativeProcessingScope()
            self.processingScope=processingScope
            repository = try AppointmentStore(file: base.appendingPathComponent("appointments-v1.json"),temporalAdmissionPolicy:PinSealedQualification.isEnabled ? .labelledOriginalCaptureV1:.screenshotOnly)
            projectionCache = try PinAppointmentProjectionCache(directory:base.appendingPathComponent("derived-appointments-v1"),sealedWorld:PinSealedQualification.isEnabled,sourceInventory:PinFreshProductConfiguration.enabled ? .permittedPhotoObservations:.appointmentEvidence,processingScope:processingScope)
        } catch { message = "Pin couldn't open appointment memory. Your photo index is unchanged." }
    }
    private func openSavedContentCache() throws -> PinAppointmentProjectionCache {
        if let savedContentCache { return savedContentCache }
        let base = PinPublicProductScope.applicationDirectory(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        let cache = try PinAppointmentProjectionCache(directory: base.appendingPathComponent("derived-saved-content-v1"),
            sealedWorld: true, sourceInventory: .permittedPhotoObservations, savedContent: true)
        savedContentCache = cache
        return cache
    }

    private func prepareCombinedSavedContent(_ library: PhotoLibrary) async throws {
        let attempt = UUID()
        combinedSavedPreparation = attempt
        let binding = SavedBinding(memories: library.memories, interpretations: await library.store.savedPhotoInterpretations())
        try await validateSavedAccess(library, binding: binding)
        guard combinedSavedPreparation == attempt else { throw PinEvidenceError.staleRecord }
        let cache = try openSavedContentCache()
        if combinedSavedBinding == binding { return }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), savedContentProvider is PinLocalSavedContentProvider {
            savedContentProvider = PinLocalSavedContentProvider()
        }
        #endif
        combinedSavedBinding = nil
        do {
            try await cache.synchronize(memories: binding.memories, records: [], savedInterpretations: binding.interpretations)
        } catch {
            if combinedSavedPreparation == attempt { await discardSavedContentCache(cache) }
            throw error
        }
        try await validateSavedAccess(library, binding: binding)
        guard combinedSavedPreparation == attempt, savedContentCache === cache else { throw PinEvidenceError.staleRecord }
        combinedSavedBinding = binding
    }

    private func loadSavedContentPairIfNeeded() throws {
        guard savedContentRequestID==nil else{return}
        #if DEBUG && PIN_COMBINED_SAVED_CONTENT && canImport(FoundationModels)
        if Self.usesCombinedSavedContent, #available(iOS 26.0, *) {
            if savedContentProvider == nil { savedContentProvider = PinLocalSavedContentProvider() }
            return
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if Self.usesSavedContent,ProcessInfo.processInfo.arguments.contains("--test-saved-warm-context-control") {
            if savedContentProvider == nil {savedContentProvider=SavedWarmContextRenderControl()}
            return
        }
        #endif
        // Keep injected Simulator controls and the active native witness intact.
        if savedContentProvider != nil && savedContentPairBytes == nil {return}
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let loaded=try PinSavedContentReplayPair.loadLocal(from:documents.appendingPathComponent("pin-saved-content-pair.json"))
        if loaded.bytes==savedContentPairBytes {return}
        (savedContentProvider as? any PinSavedContentReplayProviding)?.invalidate(requestID:nil)
        savedContentPair=loaded.pair;savedContentPairBytes=loaded.bytes;savedContentProvider=nil
    }
    static var usesRecordedAppointments:Bool {
        #if DEBUG && targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier=="app.pin.ibraincandidate" && ProcessInfo.processInfo.arguments.contains("--test-ibrain-recorded")
        #else
        return false
        #endif
    }
    private static let recordedAppointments:[PinRecordedAppointment]? = {
        guard usesRecordedAppointments else{return nil}
        struct Manifest:Decodable{let schema:Int;let entries:[PinRecordedAppointment]}
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("pin-ibrain-recorded.json")
        guard let data=try? Data(contentsOf:file),data.count<=131072,
              let manifest=try? JSONDecoder().decode(Manifest.self,from:data),manifest.schema==1,
              manifest.entries.count<=16,Set(manifest.entries.map{ $0.source.id }).count==manifest.entries.count else{return nil}
        return manifest.entries
    }()
    /// Separate phone test identity, enabled only by its explicit build setting.
    /// It uses the qualified appointment policies and private fictional pairing;
    /// ordinary apps and Release builds cannot enter this route.
    private static var usesPairedPhoneTest:Bool {
        #if DEBUG
        if Bundle.main.bundleIdentifier==PinPublicProductScope.isolatedPhoneBundleID {return PinPublicProductScope.isPhoneEnabled}
        return Bundle.main.bundleIdentifier=="app.pin.phonetest" && Bundle.main.object(forInfoDictionaryKey:"PinPairedPhoneTest") as? Bool == true
        #else
        return false
        #endif
    }
    static var usesDevelopmentSourceReader:Bool {
        if usesPairedPhoneTest{return true}
        #if DEBUG && targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier=="app.pin.livecandidate" && ProcessInfo.processInfo.arguments.contains("--test-ibrain-live")
        #else
        return false
        #endif
    }
    /// App-owned opt-in for new fictional Simulator source proposals only.
    /// Existing canonical coverage is preserved; this never rereads/reformats
    /// an admitted record or changes ordinary/phone/Release behavior.
    static var usesExplicitDevelopmentValues:Bool {
        if usesPairedPhoneTest{return true}
        #if DEBUG && targetEnvironment(simulator)
        return usesDevelopmentSourceReader && ProcessInfo.processInfo.arguments.contains("--test-ibrain-explicit-values")
        #else
        return false
        #endif
    }
    /// A separate app-owned task contract. The literal value policy must also
    /// be explicitly active; existing canonical coverage remains unchanged.
    static var usesSeparatedDevelopmentRoles:Bool {
        if usesPairedPhoneTest{return true}
        #if DEBUG && targetEnvironment(simulator)
        return usesExplicitDevelopmentValues && ProcessInfo.processInfo.arguments.contains("--test-ibrain-separated-roles")
        #else
        return false
        #endif
    }
    private static var developmentRolePolicy:BundleComponentRolePolicy {
        usesSeparatedDevelopmentRoles ? .separatedRolesV3:.legacyV2
    }
    private static var developmentValuePolicy:LabelledFieldValuePolicy {
        usesExplicitDevelopmentValues ? .explicitColonLabelsV1:.legacyWholeLines
    }
    private static func loadDevelopmentPair()->PinDevelopmentPair? {
        guard usesDevelopmentSourceReader else{return nil}
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("pin-development-pair.json")
        guard let data=try? Data(contentsOf:file),data.count<8192,
              let pair=try? JSONDecoder().decode(PinDevelopmentPair.self,from:data),(try? pair.validate()) != nil else{return nil}
        return pair
    }
    private static let cachedDevelopmentPair=loadDevelopmentPair()
    private static var developmentPair:PinDevelopmentPair? {PinSealedQualification.isEnabled ? loadDevelopmentPair():cachedDevelopmentPair}
    static var usesDevelopmentQuestions:Bool {
        if PinFreshProductConfiguration.enabled{return true}
        if usesPairedPhoneTest{return true}
        #if DEBUG && targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier=="app.pin.livecandidate" && ProcessInfo.processInfo.arguments.contains("--test-ibrain-questions")
        #else
        return false
        #endif
    }
    static var usesOriginalViewDevelopmentQuestions:Bool {
        if PinFreshProductConfiguration.enabled{return true}
        if usesPairedPhoneTest{return true}
        #if DEBUG && targetEnvironment(simulator)
        return usesDevelopmentQuestions && ProcessInfo.processInfo.arguments.contains("--test-ibrain-original-views")
        #else
        return false
        #endif
    }
    private static var developmentQuestionPolicy:EvidenceQuestionPolicy {
        PinSealedQualification.isEnabled ? .completeV9:usesOriginalViewDevelopmentQuestions ? .completeV4:.completeV3
    }
    private static func loadQuestionPair()->PinDevelopmentQuestionPair? {
        guard usesDevelopmentQuestions else{return nil}
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("pin-development-questions.json")
        guard let data=try? Data(contentsOf:file),data.count<16384 else{return nil}
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        guard let pair=try? decoder.decode(PinDevelopmentQuestionPair.self,from:data),(try? pair.validate()) != nil else{return nil};return pair
    }
    private static let cachedQuestionPair=loadQuestionPair()
    private static var questionPair:PinDevelopmentQuestionPair? {PinSealedQualification.isEnabled ? loadQuestionPair():cachedQuestionPair}
    func recordQuestion(_ question:String,previous:PinRecordQuestionContext?,timingID:UUID?=nil)async throws->PinRecordQuestionAnswer {
        guard Self.usesDevelopmentQuestions,let pair=Self.questionPair,let repository,let projectionCache,!running,!hasPendingMeaning else{throw PinDevelopmentError.configuration}
        if pair.testEnded==true {throw PinDevelopmentError.testEnded}
        PinQuestionTiming.mark(timingID,"coordinator.begin")
        let before=await repository.all().filter{$0.canonicalRecordID != nil && !$0.dismissed}
        func check(_ rows:[AppointmentItem])throws {
            for source in Set(rows.flatMap{$0.allSources+($0.previousEvidence?.sources ?? [])}){guard PhotoLibrary.currentFingerprint(for:source.id)==source.fingerprint else{throw PinEvidenceError.staleRecord}}
        }
        try check(before)
        let authority:PinPhoneQuestionAuthority?
        if pair.userSession?.authorityPolicy != nil {
            guard Self.usesPairedPhoneTest,let questionPhotoStore,let manifestSHA=Bundle.main.object(forInfoDictionaryKey:"PinPhoneTestFixtureManifestSHA256")as?String else{throw PinDevelopmentError.configuration}
            let memories=await questionPhotoStore.all(),witnesses:[PinFixtureSourceWitness]
            PinQuestionTiming.mark(timingID,"witness.begin")
            if let session=pair.userSession?.sealedSession{witnesses=try await PhotoLibrary.fixtureWitnesses(memories,session:session);try check(before)}else{witnesses=[]}
            PinQuestionTiming.mark(timingID,"witness.done")
            authority=try await projectionCache.phoneTestAuthority(memories:memories,records:before,manifestSHA256:manifestSHA,sealedSession:pair.userSession?.sealedSession,witnesses:witnesses)
        }else{authority=nil}
        PinQuestionTiming.mark(timingID,"authority.done")
        let temporalScopePolicy=pair.userSession?.sealedSession?.temporalScopePolicy ?? .legacy
        let answer=try await projectionCache.question(question,now:pair.questionNow,calendar:try pair.calendar(),previous:previous,policy:Self.developmentQuestionPolicy,inferredDatePolicy:PinSealedQualification.isEnabled ? .labelledTemporalContext:.explicitOnly,temporalScopePolicy:temporalScopePolicy,provider:try PinDevelopmentQuestionProvider(pair:pair,policy:Self.developmentQuestionPolicy,temporalScopePolicy:temporalScopePolicy,authority:authority,timingID:timingID))
        PinQuestionTiming.mark(timingID,"native.answerCompiled")
        let after=await repository.all().filter{$0.canonicalRecordID != nil && !$0.dismissed}
        guard !Task.isCancelled,before.count==after.count,before.allSatisfy({old in after.contains{$0.hasSameEvidence(as:old) && $0.canonicalRevision==old.canonicalRevision && $0.previousEvidence==old.previousEvidence}})else{throw PinEvidenceError.staleRecord}
        try check(after);return answer
    }
    func freshProductQuestion(_ question:String,previous:PinRecordQuestionContext?,parentPublication:PinProductPublishedParent?,library:PhotoLibrary,requestID:UUID,previousUnits:PinDisplayedUnitContext?=nil,submissionTime:Date?=nil)async throws->PinProductQuestionAnswer {
        let config=try PinFreshProductConfiguration.load()
        guard try config.nativeProcessingScope?.sourceIDs==processingScope?.sourceIDs else{throw PinDevelopmentError.sourceNotAllowed}
        guard config.permitsQuestion(question)else{throw PinFreshProductFailure.unapprovedQuestion}
        guard let repository,let projectionCache,!running,
              library.accessReady,!library.indexing else{throw PinDevelopmentError.configuration}
        freshTemporalReadings=[:];freshTemporalAnswerID=nil
        freshRequestID=requestID;freshQuestionPhase = .preparingPhotos;generation += 1;let current=generation
        let submittedAt=submissionTime ?? Date()
        var submittedCalendar=Calendar(identifier:.gregorian)
        submittedCalendar.timeZone=TimeZone(identifier:"America/Los_Angeles")!;submittedCalendar.firstWeekday=1
        var capturedMeaning:PinCapturedExhaustiveInterpretation?
        var initialAuthority:PinProductAuthoritySnapshot?
        var committedQuestionReread=false
        defer{if freshRequestID==requestID{freshRequestID=nil;freshQuestionPhase=nil;queuedMemories=nil}}
        let check:@MainActor @Sendable()async throws->Void={ [weak self,weak library] in
            guard let self,let library,!Task.isCancelled,self.freshRequestID==requestID,self.generation==current,
                  library.authorized,library.accessReady,!library.indexing,
                  UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable else{throw CancellationError()}
            try config.validate()
        }
        // Confirm the owning native writer before any derived refresh or cloud
        // dispatch. Decoded correction markers alone never authorize this route.
        func currentCorrectionHistory()async throws->[AppointmentReplayedCorrectionHistory] {
            try await check()
            let rows=await repository.all(),memories=library.memories
            let corrected=processingRecords(rows).filter{!$0.observation.ownerCorrectionFields.isEmpty}
            guard !corrected.isEmpty else{return []}
            guard config.nativeCorrectionPolicy==PinNativeCorrectionWitness.policy,
                  let allowed=config.allowedNativeCorrectionSHA256 else{throw PinFreshProductFailure.unapprovedCorrection}
            let permit=try await repository.synchronize(memories)
            var histories:[AppointmentReplayedCorrectionHistory]=[]
            for row in corrected {
                let history=try await repository.replayedOwnerCorrectionHistory(for:row,permit:permit)
                guard try history.transitions.allSatisfy({allowed.contains(try PinNativeCorrectionWitness.correctionDigest($0.correction))})else{throw PinFreshProductFailure.unapprovedCorrection}
                histories.append(history)
            }
            try await check()
            guard await repository.all()==rows,library.memories==memories else{throw PinEvidenceError.staleRecord}
            return histories
        }
        let initialCorrections=try await currentCorrectionHistory()
        let correctedSources=Set(initialCorrections.flatMap{$0.sources.map(\.id)})
        func currentAuthority(_ hashes:[String:String])async throws->PinProductAuthoritySnapshot {
            let histories=try await currentCorrectionHistory()
            let snapshot=try await projectionCache.captureProductAuthoritySnapshot(memories:library.memories,records:items,originalSHA256BySourceID:hashes)
            guard !histories.isEmpty else{return snapshot}
            try await check()
            return try snapshot.withNativeCorrections(histories,configuration:config,requestID:requestID)
        }
        func publicImage(_ memory:PhotoMemory)async throws->String {
            try await check()
            let bytes=try await library.immutableCurrentImageData(for:EvidenceSource(memory))
            let digest=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
            guard config.photos.contains(where:{$0.sha256==digest && ($0.sourceID==nil || $0.sourceID==memory.id)}),try await library.store.current(RecallHit(memory:memory,score:0))==memory else{throw PinStoreError.staleImport}
            try await check();return digest
        }
        #if DEBUG
        // An explicitly signed recovery build verifies current native state
        // before ANY source preparation or new provider dispatch. Reading a
        // trusted checkpoint is not permission to adopt it or restart work.
        if let expected=Bundle.main.object(forInfoDictionaryKey:"PinFirstGroupCheckpointSHA256")as?String {
            guard Self.usesPairedPhoneTest,expected.count==64,expected.allSatisfy(\.isHexDigit),
                  let name=Bundle.main.object(forInfoDictionaryKey:"PinFirstGroupCheckpointFile")as?String,
                  name==URL(fileURLWithPath:name).lastPathComponent else{throw PinDevelopmentError.configuration}
            let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            let root=documents.appendingPathComponent("fresh-source-attempts"),file=root.appendingPathComponent(name)
            let raw=try Data(contentsOf:file)
            guard raw.count<=2_097_152,SHA256.hash(data:raw).map({String(format:"%02x",$0)}).joined()==expected else{throw PinDevelopmentError.invalidReceipt}
            let checkpoint=try JSONDecoder().decode(PinFirstGroupAssessmentCheckpoint.self,from:raw)
            struct SavedAssessment:Decodable {let memory:PhotoMemory}
            let old=try JSONDecoder().decode(SavedAssessment.self,from:checkpoint.originalEnvelope)
            guard let memory=library.memories.first(where:{$0.id==old.memory.id}),memory==old.memory else{throw PinStoreError.staleImport}
            let digest=try await publicImage(memory),key=try PinSourceAttemptLocation.key(for:EvidenceSource(memory))
            guard name==key+".ocr-first-assessment-recovery.json" else{throw PinDevelopmentError.configuration}
            let rows=await repository.all(),grouped=documents.appendingPathComponent("fresh-source-groups/"+key+".json")
            if FileManager.default.fileExists(atPath:grouped.path) {
                _=try PinGroupedSourceResult.load(file:grouped,memory:memory,records:rows)
                PinFreshProductAudit.record(question:question,stage:"firstGroupRecoveryAlreadyCompleted")
            }else {
                let marker=try Data(contentsOf:root.appendingPathComponent(key+".ocr-children-started.json"))
                guard marker.count<=131072,try JSONDecoder().decode(EvidenceSource.self,from:marker)==EvidenceSource(memory),
                      !FileManager.default.fileExists(atPath:root.appendingPathComponent(key+".ocr-first-assessment-resumed.json").path),
                      !rows.contains(where:{$0.canonicalRecordID != nil && ($0.allSources+($0.previousEvidence?.sources ?? [])).contains(where:{$0.id==memory.id})}) else{throw PinFreshProductFailure.unfinishedSourceRead}
                let initial=try PinSourcePreparationArchive.load(file:documents.appendingPathComponent("fresh-source-assessments/"+key+".json"),memory:memory,accessGranted:library.authorized && library.accessReady,temporalPolicy:config.temporalPolicy,initialPolicy:config.initialSourcePolicy)
                let groupingBytes=try Data(contentsOf:root.appendingPathComponent(key+".ocr-grouping-receipt.json"))
                guard groupingBytes.count<=131072 else{throw PinDevelopmentError.oversized}
                let grouping=try JSONDecoder().decode(DecisionReceipt.self,from:groupingBytes)
                let group=try PinVisualGroupContext(memory:memory,initialReceipt:initial.receipt,groupingReceipt:grouping,ordinal:1)
                let provider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,groupContext:group,questionRequestID:requestID,retainedFirstAssessment:file,check:{try await check()})
                _=try await PinSealedSourcePipeline.assessGroup(memory,group:group,provider:provider)
                try await check()
                guard await repository.all()==rows,try await library.store.current(RecallHit(memory:memory,score:0))==memory else{throw PinEvidenceError.staleRecord}
                PinFreshProductAudit.record(question:question,stage:"firstGroupRecoveryPreflightPassed")
            }
        }
        #endif
        let unitReplacementDirectory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("fresh-unit-replacements-v1")
        func replacementFile(_ sourceID:String)->URL {
            unitReplacementDirectory.appendingPathComponent(SHA256.hash(data:Data(sourceID.utf8)).map{String(format:"%02x",$0)}.joined()+".json")
        }
        func restoredUnitSource(_ memory:PhotoMemory)async throws->PinUnitSourceEvidence? {
            guard config.unitSourceRecovery==true else{return nil}
            let file=replacementFile(memory.id)
            guard FileManager.default.fileExists(atPath:file.path)else{return nil}
            let bytes=try Data(contentsOf:file);guard bytes.count<=1_048_576 else{throw PinDevelopmentError.oversized}
            var journal=try JSONDecoder().decode(FreshUnitReplacementJournal.self,from:bytes)
            guard journal.sourceAfter==EvidenceSource(memory)else{throw PinFreshProductFailure.unfinishedSourceRead}
            try await check();let original=try await publicImage(memory)
            let permit=try await repository.synchronize(library.memories)
            guard let status=await repository.groupReplacementStatus(journal.transactionID),status.sourceAfter==AppointmentSource(memory)else{throw PinEvidenceError.staleRecord}
            let stageDirectory=PinSourceStageJournal.directory(in:unitReplacementDirectory,transaction:journal.transactionID)
            if status.phase == .sourceAdvanced,FileManager.default.fileExists(atPath:stageDirectory.path) {
                let stages=try PinSourceStageJournal(directory:stageDirectory,transaction:journal.transactionID,memory:memory,originalSHA256:original,replayOnly:true)
                let allMemories=library.memories,otherRows=await repository.all().filter{$0.sourceID != memory.id}
                let sourceCheck:@MainActor @Sendable()async throws->Void={
                    try await check()
                    guard library.memories==allMemories,try await library.store.current(RecallHit(memory:memory,score:0))==memory,
                          PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint,
                          await repository.all().filter({$0.sourceID != memory.id})==otherRows else{throw PinEvidenceError.staleRecord}
                }
                let transaction=try await repository.resumeGroupReplacement(journal.transactionID,permit:permit),base=journal
                let proof=try await PinWholeSourceReplacement.resumeRecordedStages(memory:memory,originalSHA256:original,transaction:transaction,stages:stages,store:repository,permit:permit,directVisualGrouping:config.unitSourceRecovery==true,selectedSourceValues:config.selectedSourceValues==true,initialPolicy:config.initialSourcePolicy,provider:{input in
                    try PinFreshProductProvider(config:config,memory:memory,originalSHA256:original,recordID:input.ticket?.id,recordRevision:input.ticket?.nextRevision,groupContext:input.group,questionRequestID:requestID,retainedGroupingInitialReceipt:input.retainedGroupingInitialReceipt,sourceStages:stages,check:{try await sourceCheck()})
                },check:{try await sourceCheck()},checkpoint:{proof in
                    try await sourceCheck();var ready=base;ready.proof=proof
                    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
                    try PinPrivatePayloadWithdrawal.write(encoder.encode(ready),to:file,options:.atomic)
                })
                journal.proof=proof
                PinFreshProductAudit.record(question:question,stage:"recordedSourceStagesResumedWithoutDispatch")
            }
            #if DEBUG
            if status.phase == .sourceAdvanced,journal.proof==nil,status.allocatedRecordIDs.count==1,
               let expected=Bundle.main.object(forInfoDictionaryKey:"PinCompletedSourceCheckpointSHA256")as?String {
                guard Self.usesPairedPhoneTest,expected.count==64,expected.allSatisfy(\.isHexDigit),
                      let name=Bundle.main.object(forInfoDictionaryKey:"PinCompletedSourceCheckpointFile")as?String,
                      name==URL(fileURLWithPath:name).lastPathComponent else{throw PinDevelopmentError.configuration}
                let checkpointFile=file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fresh-completed-source-checkpoints/"+name)
                let raw=try Data(contentsOf:checkpointFile)
                guard raw.count<=2_097_152,SHA256.hash(data:raw).map({String(format:"%02x",$0)}).joined()==expected else{throw PinDevelopmentError.invalidReceipt}
                let receiptCheckpoint=try JSONDecoder().decode(PinCompletedSourceCheckpoint.self,from:raw)
                let allMemories=library.memories,otherRows=await repository.all().filter{$0.sourceID != memory.id}
                let sourceCheck:@MainActor @Sendable()async throws->Void={
                    try await check()
                    guard library.memories==allMemories,try await library.store.current(RecallHit(memory:memory,score:0))==memory,
                          PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint,
                          await repository.all().filter({$0.sourceID != memory.id})==otherRows else{throw PinEvidenceError.staleRecord}
                }
                let transaction=try await repository.resumeGroupReplacement(journal.transactionID,permit:permit),base=journal
                let proof=try await PinWholeSourceReplacement.resumeCompletedSingle(memory:memory,originalSHA256:original,transaction:transaction,receiptCheckpoint:receiptCheckpoint,store:repository,permit:permit,selectedSourceValues:config.selectedSourceValues==true,initialPolicy:config.initialSourcePolicy,provider:{input in
                    try PinFreshProductProvider(config:config,memory:memory,originalSHA256:original,recordID:input.ticket?.id,recordRevision:input.ticket?.nextRevision,questionRequestID:requestID,completedSourceCheckpoint:receiptCheckpoint,check:{try await sourceCheck()})
                },check:{try await sourceCheck()},checkpoint:{proof in
                    try await sourceCheck();var ready=base;ready.proof=proof
                    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
                    try PinPrivatePayloadWithdrawal.write(encoder.encode(ready),to:file,options:.atomic)
                })
                journal.proof=proof
                PinFreshProductAudit.record(question:question,stage:"completedSourceResumedWithoutDispatch")
            }
            #endif
            if status.phase == .sourceAdvanced,journal.proof==nil,status.allocatedRecordIDs.isEmpty {
                let authorization=file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fresh-unit-recovery-authorizations-v1/"+file.lastPathComponent)
                guard FileManager.default.fileExists(atPath:authorization.path)else{throw PinFreshProductFailure.unfinishedSourceRead}
                let raw=try Data(contentsOf:authorization);guard raw.count<=65536 else{throw PinDevelopmentError.oversized}
                let recovery=try JSONDecoder().decode(PinSourceUndispatchedRecoveryAuthorization.self,from:raw)
                try recovery.validate(session:config.session,transaction:journal.transactionID,source:EvidenceSource(memory))
                let allMemories=library.memories,otherRows=await repository.all().filter{$0.sourceID != memory.id}
                let sourceCheck:@MainActor @Sendable()async throws->Void={
                    try await check()
                    guard library.memories==allMemories,try await library.store.current(RecallHit(memory:memory,score:0))==memory,PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint,
                          await repository.all().filter({$0.sourceID != memory.id})==otherRows else{throw PinEvidenceError.staleRecord}
                }
                try await sourceCheck()
                try config.requireSourceReading()
                try await verifyConnectionBeforeAttempt()
                try await sourceCheck()
                // Once started, an unknown interruption cannot automatically repeat.
                try PinPrivatePayloadWithdrawal.write(Data(recovery.initialEnvelopeSHA256.utf8),to:authorization.appendingPathExtension("started"),options:.withoutOverwriting)
                let transaction=try await repository.resumeGroupReplacement(journal.transactionID,permit:permit),base=journal,gate=FreshInitialEnvelopeGate(recovery.initialEnvelopeSHA256)
                let proof=try await PinWholeSourceReplacement.compile(memory:memory,transaction:transaction,store:repository,permit:permit,directVisualGrouping:config.unitSourceRecovery==true,selectedSourceValues:config.selectedSourceValues==true,initialPolicy:config.initialSourcePolicy,provider:{input in
                    let expected=await gate.take()
                    return try PinFreshProductProvider(config:config,memory:memory,originalSHA256:original,recordID:input.ticket?.id,recordRevision:input.ticket?.nextRevision,groupContext:input.group,questionRequestID:recovery.questionRequestID,retainedGroupingInitialReceipt:input.retainedGroupingInitialReceipt,requiredEnvelopeSHA256:expected,check:{try await sourceCheck()})
                },check:{try await sourceCheck()},checkpoint:{proof in
                    try await sourceCheck();var ready=base;ready.proof=proof
                    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
                    try PinPrivatePayloadWithdrawal.write(encoder.encode(ready),to:file,options:.atomic)
                })
                journal.proof=proof
            }
            guard let proof=journal.proof,proof.sourceID==memory.id else{throw PinFreshProductFailure.unfinishedSourceRead}
            guard let current=await repository.groupReplacementStatus(journal.transactionID)else{throw PinEvidenceError.staleRecord}
            if current.phase == .readyToCommit {
                let transaction=try await repository.resumeGroupReplacement(journal.transactionID,permit:permit)
                _=try await PinWholeSourceReplacement.resumeReady(memory:memory,transaction:transaction,proof:proof,store:repository,permit:permit,initialPolicy:config.initialSourcePolicy,check:{try await check()})
            }else{guard current.phase == .completed else{throw PinFreshProductFailure.unfinishedSourceRead}}
            let rows=await repository.all().filter{$0.sourceID==memory.id}
            _=try PinProductUnitEvidence(sources:[proof]).prepare(memories:[memory],records:rows,unit:.documents,initialPolicy:config.initialSourcePolicy)
            try await check();return proof
        }
        var pairedConnectionVerified=false
        @MainActor @Sendable func verifyConnectionBeforeAttempt()async throws {
            try config.requireSourceReading()
            guard config.phoneTest?.bundleID==PinPublicProductScope.isolatedPhoneBundleID,
                  !pairedConnectionVerified else{return}
            try await PinFreshProductProvider.verifyPairedConnection(config,requiresSourceReading:true)
            try await check()
            pairedConnectionVerified=true
        }
        func compile(_ memory:PhotoMemory,replacing:String?=nil)async throws {
            try await check()
            let digest=try await publicImage(memory)
            // Recovery claims are durable attempt state too. Require permission
            // before creating one; ordinary completed archives remain readable.
            if config.sourceRegressions?.contains(where:{$0.source==EvidenceSource(memory)})==true {
                try await verifyConnectionBeforeAttempt()
                try await check()
            }
            let attemptRoot=try PinSourceAttemptLocation.root(documents:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0],source:EvidenceSource(memory),session:config.session,regressions:config.sourceRegressions ?? [])
            try FileManager.default.createDirectory(at:attemptRoot,withIntermediateDirectories:true)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let key=try PinSourceAttemptLocation.key(for:EvidenceSource(memory))
            let initialKey=try PinSourceAttemptLocation.initialKey(root:attemptRoot,source:EvidenceSource(memory),
                originalSHA256:digest,session:config.session,regressions:config.sourceRegressions ?? [])
            if initialKey != key {
                guard memory.visualReading==nil,replacing==nil else{throw PinDevelopmentError.sourceNotAllowed}
            }
            let marker=attemptRoot.appendingPathComponent(initialKey+".json")
            let preparationFile=attemptRoot.deletingLastPathComponent().appendingPathComponent("fresh-source-assessments").appendingPathComponent(key+".json")
            let sourceCheck:@MainActor @Sendable()async throws->Void={
                try await check()
                guard try await library.store.current(RecallHit(memory:memory,score:0))==memory,PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinStoreError.staleImport}
                let rows=await repository.all()
                guard !rows.contains(where:{$0.dismissed && $0.allSources.contains(AppointmentSource(memory))})else{throw PinStoreError.staleResult}
            }
            // First readings use the existing native writer and source-stage
            // journal. Never adopt an older consumed attempt into a new ledger.
            let initialRecoveryEnabled=config.unitSourceRecovery==true && config.sourcePreparationRecovery==true && config.productReconciliation==true && replacing==nil && initialKey==key
            let initialPermit=try await repository.synchronize(library.memories)
            let initialTransaction:AppointmentInitialReadTicket?
            let initialStages:PinSourceStageJournal?
            if initialRecoveryEnabled,!(await repository.hasCompletedInitialRead(AppointmentSource(memory))) {
                let pending=await repository.hasIncompleteInitialRead(AppointmentSource(memory))
                guard pending || !FileManager.default.fileExists(atPath:marker.path) else{throw PinFreshProductFailure.unfinishedSourceRead}
                try await sourceCheck()
                let transaction=try await repository.beginInitialRead(memory,originalSHA256:digest,contractSHA256:config.initialSourceRecoveryContractSHA256(contextZone:"America/Los_Angeles"),permit:initialPermit)
                initialTransaction=transaction
                initialStages=try PinSourceStageJournal(directory:PinSourceStageJournal.directory(in:unitReplacementDirectory,transaction:transaction.id),transaction:transaction.id,memory:memory,originalSHA256:digest,replayOnly:false,resuming:transaction.resumed)
            }else{initialTransaction=nil;initialStages=nil}
            let initialStageReadiness:(@Sendable ()async throws->Void)?
            if initialStages != nil {
                initialStageReadiness={try await verifyConnectionBeforeAttempt()}
            }else{initialStageReadiness=nil}
            let initialProviderCheck:@MainActor @Sendable()async throws->Void={
                try await sourceCheck()
                #if DEBUG && targetEnvironment(simulator)
                // Deterministic local lifecycle control: hold only after the
                // real provider journal durably saves a completed response.
                // No hold exists in phone/Release builds or ordinary launches.
                if Bundle.main.bundleIdentifier=="app.pin.intakecandidate",
                   ProcessInfo.processInfo.arguments.contains("--test-initial-stage-hold"),
                   let transaction=initialTransaction {
                    let directory=PinSourceStageJournal.directory(in:unitReplacementDirectory,transaction:transaction.id)
                    if try FileManager.default.contentsOfDirectory(atPath:directory.path).contains(where:{$0.hasSuffix(".receipt.json")}) {
                        let marker=unitReplacementDirectory.appendingPathComponent("initial-stage-saved.json")
                        try Data(transaction.id.uuidString.utf8).write(to:marker,options:.atomic)
                        while true {try await Task.sleep(nanoseconds:50_000_000);try await sourceCheck()}
                    }
                }
                #endif
            }
            func initialTicket(receipt:DecisionReceipt,ordinal:Int)async throws->CanonicalWriteTicket {
                if let transaction=initialTransaction {
                    try await sourceCheck()
                    return try await repository.reserveInitialRecord(transaction,assessmentSHA256:receipt.requestSHA256,ordinal:ordinal,permit:initialPermit)
                }
                return await repository.reserveCanonicalRecord()
            }
            func finishInitial(_ ids:[String],clearingSourcePending:Bool=false)async throws {
                guard let transaction=initialTransaction else{return}
                try await sourceCheck()
                let records=await repository.all().filter{ids.contains($0.id)}
                try await repository.finishInitialRead(transaction,records:records,permit:initialPermit,clearingSourcePending:clearingSourcePending)
            }
            func checkpointTemporalPreparation(_ completed:PinSealedSourceCompletion)async throws {
                guard config.retainedOCRGrouping==true,config.sourceValueRecovery=="nativeCompletionsV4",config.temporalRoleExplanations==true,
                      let context=try PinTemporalRoleContext.make(completed,memory:memory) else{return}
                try await sourceCheck()
                guard let record=await repository.all().first(where:{$0.canonicalRecordID==completed.projection.recordID})else{throw PinEvidenceError.staleRecord}
                try PinTemporalPreparationArchive.save(directory:freshTemporalPreparations,context:context,group:completed.groupContext,memory:memory,record:record,accessGranted:library.authorized && library.accessReady)
                try await sourceCheck()
            }
            let groupedFile=attemptRoot.deletingLastPathComponent().appendingPathComponent("fresh-source-groups").appendingPathComponent(key+".json")
            func continueRetainedGrouping(_ initialReceipt:DecisionReceipt)async throws {
                guard config.retainedOCRGrouping==true,config.temporalPolicy == .anchoredSpansV9,replacing==nil else{throw PinDevelopmentError.configuration}
                try await sourceCheck()
                if FileManager.default.fileExists(atPath:groupedFile.path) {
                    let restored=try PinGroupedSourceResult.load(file:groupedFile,memory:memory,records:await repository.all())
                    for outcome in restored.outcomes {if let id=outcome.recordID{freshTemporalGroups[id]=outcome.group}}
                    try await finishInitial(restored.outcomes.compactMap(\.recordID))
                    let permit=try await repository.synchronize(library.memories)
                    // Physical-document grouping does not establish distinct-event units.
                    try await repository.retainIncompleteSource(AppointmentSource(memory),permit:permit)
                    try await sourceCheck();return
                }
                let request=try PinRetainedOCRGrouping.request(memory:memory,initialReceipt:initialReceipt)
                let task=try RetainedOCRSourceGrouper.task(request)
                let receiptFile=attemptRoot.appendingPathComponent(key+".ocr-grouping-receipt.json")
                let groupingAttempt=attemptRoot.appendingPathComponent(key+".ocr-grouping-envelope.json")
                let groupingReceipt:DecisionReceipt
                if FileManager.default.fileExists(atPath:receiptFile.path) {
                    let bytes=try Data(contentsOf:receiptFile);guard bytes.count<=131072 else{throw PinDevelopmentError.oversized}
                    groupingReceipt=try JSONDecoder().decode(DecisionReceipt.self,from:bytes)
                }else{
                    if initialStages==nil {try await verifyConnectionBeforeAttempt()}
                    try await sourceCheck()
                    let provider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,questionRequestID:requestID,retainedGroupingInitialReceipt:initialReceipt,initialAttempt:initialStages==nil ? groupingAttempt:nil,recoverInitial:initialStages==nil && FileManager.default.fileExists(atPath:groupingAttempt.path),sourceStages:initialStages,beforeSourceStageSend:initialStageReadiness,check:{try await initialProviderCheck()})
                    groupingReceipt=try await provider.decide(task)
                    try await sourceCheck();try PinPrivatePayloadWithdrawal.write(encoder.encode(groupingReceipt),to:receiptFile,options:.atomic)
                }
                let grouping=try RetainedOCRSourceGrouper.compile(request,task:task,receipt:groupingReceipt)
                try await sourceCheck()
                let completion=attemptRoot.appendingPathComponent(key+".ocr-children-started.json")
                let recoveringFirst=initialStages==nil && FileManager.default.fileExists(atPath:completion.path)
                let firstCheckpoint=attemptRoot.appendingPathComponent(key+".ocr-first-assessment-recovery.json")
                let resumed=attemptRoot.appendingPathComponent(key+".ocr-first-assessment-resumed.json")
                if recoveringFirst {
                    let started=try Data(contentsOf:completion)
                    let rows=await repository.all()
                    guard grouping.scopes.first?.ordinal==1,started.count<=131072,try JSONDecoder().decode(EvidenceSource.self,from:started)==EvidenceSource(memory),
                          FileManager.default.fileExists(atPath:firstCheckpoint.path),
                          !FileManager.default.fileExists(atPath:resumed.path),
                          !rows.contains(where:{$0.canonicalRecordID != nil && ($0.allSources+($0.previousEvidence?.sources ?? [])).contains(where:{$0.id==memory.id})}) else{throw PinFreshProductFailure.unfinishedSourceRead}
                }
                if initialStages==nil {try await verifyConnectionBeforeAttempt()}
                try await sourceCheck()
                let permit=try await repository.synchronize(library.memories)
                try await repository.retainIncompleteSource(AppointmentSource(memory),permit:permit)
                // A partial child pipeline never reserves another ticket or repeats
                // a model stage on reopening. Completed whole outcomes replay below.
                if initialStages==nil && !recoveringFirst{try PinInitialSourceRecovery.beginCompletion(file:completion,source:encoder.encode(EvidenceSource(memory)))}
                var outcomes:[PinGroupedSourceResult.Outcome]=[]
                for scope in grouping.scopes {
                    let group=try PinVisualGroupContext(memory:memory,initialReceipt:initialReceipt,groupingReceipt:groupingReceipt,ordinal:scope.ordinal)
                    let recovered=recoveringFirst && scope.ordinal==1
                    let initialProvider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,groupContext:group,questionRequestID:requestID,retainedFirstAssessment:recovered ? firstCheckpoint:nil,sourceStages:initialStages,beforeSourceStageSend:initialStageReadiness,check:{try await initialProviderCheck()})
                    let assessment=try await PinSealedSourcePipeline.assessGroup(memory,group:group,provider:initialProvider)
                    try await sourceCheck()
                    if recovered {
                        let currentRows=await repository.all()
                        guard !currentRows.contains(where:{$0.canonicalRecordID != nil && ($0.allSources+($0.previousEvidence?.sources ?? [])).contains(where:{$0.id==memory.id})})else{throw PinFreshProductFailure.unfinishedSourceRead}
                        // Latch before any next stage or native ticket. Another
                        // interruption holds; it cannot replay partial fields.
                        try PinInitialSourceRecovery.beginCompletion(file:resumed,source:encoder.encode(assessment.receipt))
                    }
                    guard let candidate=assessment.candidate,candidate.disposition == .booking else{
                        outcomes.append(.init(group:group,initialReceipt:assessment.receipt,recordID:nil));continue
                    }
                    let ticket=try await initialTicket(receipt:assessment.receipt,ordinal:scope.ordinal)
                    let provider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,recordID:ticket.id,recordRevision:ticket.nextRevision,groupContext:group,questionRequestID:requestID,sourceStages:initialStages,beforeSourceStageSend:initialStageReadiness,check:{try await initialProviderCheck()})
                    let completed=try await PinSealedSourcePipeline.complete(candidate,memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,contextZone:"America/Los_Angeles",temporalPolicy:.anchoredSpansV9,groupContext:group,printedClockNotation:config.printedClockNotation==true,fieldPolicy:config.selectedFieldPolicy,completionCapacity:config.selectedCompletionCapacity,valueRecovery:config.selectedValueRecovery,combinedSourceFields:config.combinedSourceFields==true,selectedSourceValues:config.selectedSourceValues==true,provider:provider)
                    try await sourceCheck();try group.validate(memory:memory,projection:completed.projection)
                    _=try await repository.commitCanonical(PinSealedSourcePipeline.draft(completed,ticket:ticket,memory:memory),ticket:ticket,permit:permit,keepingSourcePending:AppointmentSource(memory))
                    outcomes.append(.init(group:group,initialReceipt:assessment.receipt,recordID:ticket.id));freshTemporalGroups[ticket.id]=group
                    if config.temporalRoleExplanations==true {freshTemporalContexts[ticket.id]=try PinTemporalRoleContext.make(completed,memory:memory)}
                    try await checkpointTemporalPreparation(completed)
                }
                try await sourceCheck();items=await repository.all()
                try PinGroupedSourceResult(outcomes:outcomes).save(file:groupedFile,memory:memory,records:items)
                try await finishInitial(outcomes.compactMap(\.recordID))
                try await repository.retainIncompleteSource(AppointmentSource(memory),permit:permit)
            }
            if let reading=memory.visualReading,try reading.validatedReceipt().visibleDocumentCount>1 {
                guard config.declaredImageProfileSHA256 != nil,config.temporalPolicy == .anchoredSpansV9,replacing==nil else{throw PinEvidenceError.invalidSupport}
                if FileManager.default.fileExists(atPath:marker.path) && (initialStages==nil || FileManager.default.fileExists(atPath:groupedFile.path)) {
                    try await sourceCheck()
                    try PinSourceAttemptLocation.requireSavedResult(at:groupedFile)
                    let restored=try PinGroupedSourceResult.load(file:groupedFile,memory:memory,records:await repository.all())
                    for outcome in restored.outcomes {if let id=outcome.recordID{freshTemporalGroups[id]=outcome.group}}
                    try await finishInitial(restored.outcomes.compactMap(\.recordID))
                    let permit=try await repository.synchronize(library.memories)
                    try await repository.retainVisualReadingGap(memory,permit:permit,unpreparedGroups:restored.hasUnpreparedGroups(memory:memory,records:await repository.all()))
                    try await sourceCheck();return
                }
                guard config.retainedEvidenceOnly != true else{throw PinDevelopmentError.sourceNotAllowed}
                if initialStages==nil {try await verifyConnectionBeforeAttempt()}
                try await sourceCheck()
                try PinPrivatePayloadWithdrawal.write(encoder.encode(EvidenceSource(memory)),to:marker,options:initialKey==key ? .atomic:.withoutOverwriting)
                let permit=try await repository.synchronize(library.memories)
                if initialStages==nil {try await repository.beginSemanticRead(AppointmentSource(memory),permit:permit)}
                let groupingRequest=try PinVisualReadingProjection.groupingRequest(memory),groupingTask=try BoundedVisualSourceGrouper.task(groupingRequest)
                let groupingProvider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,questionRequestID:config.productReconciliation==true ? requestID:nil,sourceStages:initialStages,beforeSourceStageSend:initialStageReadiness,check:{try await initialProviderCheck()})
                let groupingReceipt=try await groupingProvider.decide(groupingTask)
                let grouping=try BoundedVisualSourceGrouper.compile(groupingRequest,task:groupingTask,receipt:groupingReceipt)
                try await sourceCheck();var outcomes:[PinGroupedSourceResult.Outcome]=[]
                for scope in grouping.scopes {
                    let group=try PinVisualGroupContext(memory:memory,receipt:groupingReceipt,ordinal:scope.ordinal)
                    let initialProvider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,groupContext:group,questionRequestID:config.productReconciliation==true ? requestID:nil,sourceStages:initialStages,beforeSourceStageSend:initialStageReadiness,check:{try await initialProviderCheck()})
                    let assessment=try await PinSealedSourcePipeline.assessGroup(memory,group:group,provider:initialProvider)
                    try await sourceCheck()
                    guard let candidate=assessment.candidate,candidate.disposition == .booking else {
                        outcomes.append(.init(group:group,initialReceipt:assessment.receipt,recordID:nil));continue
                    }
                    let ticket=try await initialTicket(receipt:assessment.receipt,ordinal:scope.ordinal)
                    let completionProvider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,recordID:ticket.id,recordRevision:ticket.nextRevision,groupContext:group,questionRequestID:config.productReconciliation==true ? requestID:nil,sourceStages:initialStages,beforeSourceStageSend:initialStageReadiness,check:{try await initialProviderCheck()})
                    let completed=try await PinSealedSourcePipeline.complete(candidate,memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,contextZone:"America/Los_Angeles",temporalPolicy:config.temporalPolicy,groupContext:group,printedClockNotation:config.printedClockNotation==true,fieldPolicy:config.selectedFieldPolicy,completionCapacity:config.selectedCompletionCapacity,valueRecovery:config.selectedValueRecovery,combinedSourceFields:config.combinedSourceFields==true,selectedSourceValues:config.selectedSourceValues==true,provider:completionProvider)
                    try await sourceCheck();try group.validate(memory:memory,projection:completed.projection)
                    _=try await repository.commitCanonical(PinSealedSourcePipeline.draft(completed,ticket:ticket,memory:memory),ticket:ticket,permit:permit,keepingSourcePending:initialStages==nil ? nil:AppointmentSource(memory))
                    outcomes.append(.init(group:group,initialReceipt:assessment.receipt,recordID:ticket.id))
                    freshTemporalGroups[ticket.id]=group
                    if config.temporalRoleExplanations==true {freshTemporalContexts[ticket.id]=try PinTemporalRoleContext.make(completed,memory:memory)}
                    try await checkpointTemporalPreparation(completed)
                }
                try await sourceCheck();items=await repository.all()
                let completedGroups=PinGroupedSourceResult(outcomes:outcomes)
                try completedGroups.save(file:groupedFile,memory:memory,records:items)
                try await finishInitial(outcomes.compactMap(\.recordID))
                try await repository.retainVisualReadingGap(memory,permit:permit,unpreparedGroups:completedGroups.hasUnpreparedGroups(memory:memory,records:items))
                return
            }
            let canRecoverInitial=["initial-v1","initial-and-retained-grouping-v2"].contains(config.sourceReceiptRecovery ?? "") && memory.visualReading==nil && memory.revision==1
            let attempted=FileManager.default.fileExists(atPath:marker.path)
            let initialAttempt=attemptRoot.appendingPathComponent(initialKey+".initial-envelope.json")
            let completionStarted=attemptRoot.appendingPathComponent(initialKey+".completion-started.json")
            if attempted {
                guard config.sourcePreparationRecovery==true else{throw PinDevelopmentError.sourceNotAllowed}
                try await sourceCheck()
                if FileManager.default.fileExists(atPath:preparationFile.path) {
                    let assessment=try PinSourcePreparationArchive.load(file:preparationFile,memory:memory,accessGranted:library.authorized && library.accessReady,temporalPolicy:config.temporalPolicy,initialPolicy:config.initialSourcePolicy)
                    try await sourceCheck()
                    if assessment.state == .groupingRequired,config.retainedOCRGrouping==true {try await continueRetainedGrouping(assessment.receipt)}else{try await finishInitial([])}
                    return
                }
                if initialStages==nil {
                    guard canRecoverInitial else{throw PinFreshProductFailure.unfinishedSourceRead}
                    try PinInitialSourceRecovery.requireUnstartedCompletion(attempt:initialAttempt,completion:completionStarted)
                }
            }
            guard config.retainedEvidenceOnly != true else{throw PinDevelopmentError.sourceNotAllowed}
            // Journaled recovery checks readiness only for a missing stage.
            // Unjournaled attempts retain their pre-claim connection gate.
            if initialStages==nil {try await verifyConnectionBeforeAttempt()}
            try await sourceCheck()
            if !attempted {
                try PinPrivatePayloadWithdrawal.write(encoder.encode(EvidenceSource(memory)),to:marker,options:.atomic)
            }
            let permit=try await repository.synchronize(library.memories)
            if initialStages==nil {try await repository.beginSemanticRead(AppointmentSource(memory),permit:permit)}
            let provider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,questionRequestID:config.productReconciliation==true ? requestID:nil,initialAttempt:initialStages==nil && canRecoverInitial ? initialAttempt:nil,recoverInitial:initialStages==nil && attempted,sourceStages:initialStages,beforeSourceStageSend:initialStageReadiness,check:{try await initialProviderCheck()})
            let trace=PinSourceTraceRecorder(url:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("fresh-source-trace.jsonl")).sink
            let initial:AppointmentCandidate
            if config.sourcePreparationRecovery==true {
                let assessment=try await PinSealedSourcePipeline.assessInitial(memory,temporalPolicy:config.temporalPolicy,initialPolicy:config.initialSourcePolicy,provider:provider,trace:trace)
                try await sourceCheck()
                if assessment.state != .candidate {
                    try PinSourcePreparationArchive.save(file:preparationFile,memory:memory,receipt:assessment.receipt,accessGranted:library.authorized && library.accessReady,temporalPolicy:config.temporalPolicy,initialPolicy:config.initialSourcePolicy)
                    try await sourceCheck()
                    if assessment.state == .groupingRequired,config.retainedOCRGrouping==true {try await continueRetainedGrouping(assessment.receipt)}else{try await finishInitial([])}
                    return // Uncovered source stays in partial query coverage.
                }
                guard let candidate=assessment.candidate else{throw PinEvidenceError.invalidSupport}
                initial=candidate
            }else{initial=try await PinSealedSourcePipeline.initial(memory,temporalPolicy:config.temporalPolicy,provider:provider,trace:trace)}
            try await sourceCheck()
            if initial.disposition == .notBooking{try await finishInitial([]);try await repository.rejectSource(PinSealedSourcePipeline.rejection(initial,memory:memory,temporalPolicy:config.temporalPolicy,initialPolicy:config.initialSourcePolicy),permit:permit);return}
            guard initial.disposition == .booking else{throw PinEvidenceError.invalidSupport}
            // A recovered initial receipt never replays an already attempted
            // completion pipeline or creates a second native record ticket.
            if canRecoverInitial && initialStages==nil {
                try PinInitialSourceRecovery.beginCompletion(file:completionStarted,source:encoder.encode(EvidenceSource(memory)))
            }
            let ticket:CanonicalWriteTicket
            if let replacing{ticket=try await repository.prepareCanonicalReplacement(id:replacing)}else{ticket=try await initialTicket(receipt:initial.receipt,ordinal:1)}
            let completionProvider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,recordID:ticket.id,recordRevision:ticket.nextRevision,questionRequestID:config.productReconciliation==true ? requestID:nil,sourceStages:initialStages,beforeSourceStageSend:initialStageReadiness,check:{try await initialProviderCheck()})
            let completed=try await PinSealedSourcePipeline.complete(initial,memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,contextZone:"America/Los_Angeles",temporalPolicy:config.temporalPolicy,printedClockNotation:config.printedClockNotation==true,initialPolicy:config.initialSourcePolicy,fieldPolicy:config.selectedFieldPolicy,completionCapacity:config.selectedCompletionCapacity,valueRecovery:config.selectedValueRecovery,combinedSourceFields:config.combinedSourceFields==true,selectedSourceValues:config.selectedSourceValues==true,provider:completionProvider,trace:trace)
            let draft=try PinSealedSourcePipeline.draft(completed,ticket:ticket,memory:memory)
            if config.resultUnits==true {try PinPrivatePayloadWithdrawal.write(encoder.encode(initial.receipt),to:attemptRoot.appendingPathComponent(key+".unit-initial-receipt.json"),options:.atomic)}
            try await sourceCheck();_=try await repository.commitCanonical(draft,ticket:ticket,permit:permit,keepingSourcePending:initialStages==nil ? nil:AppointmentSource(memory))
            if memory.visualReading != nil{try await repository.retainVisualReadingGap(memory,permit:permit)}
            items=await repository.all()
            freshTemporalContexts.removeValue(forKey:ticket.id);freshTemporalCache.removeValue(forKey:ticket.id)
            if config.temporalRoleExplanations==true {
                freshTemporalContexts[ticket.id]=try PinTemporalRoleContext.make(completed,memory:memory)
            }
            try await checkpointTemporalPreparation(completed)
            try await finishInitial([ticket.id],clearingSourcePending:true)
        }
        // Explicit development continuation over retained, current evidence.
        // No image reader or original source-role request is permitted here.
        func completeRetainedClock()async throws {
            typealias Attempt=PinPrintedClockJournal.Attempt
            typealias Terminal=PinPrintedClockJournal.Terminal
            let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("fresh-clock-repairs-v1")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            try PinPrintedClockJournal.validate(directory:root)
            for row in await repository.all() where !row.dismissed {
                try await check()
                guard let id=row.canonicalRecordID,let parts=row.observation.components,
                      parts.hour==nil || parts.minute==nil,
                      let memory=library.memories.first(where:{AppointmentSource($0)==row.source}) else{continue}
                guard let reading=try? PinTemporalRoleArchive.load(directory:freshTemporalArchive,memory:memory,record:row,accessGranted:library.authorized && library.accessReady,temporalPolicy:config.temporalPolicy) else{continue}
                let retained=try reading.printedClockContext(memory:memory,record:row,accessGranted:library.authorized && library.accessReady)
                let date=retained.context.current.appointment.date
                guard date.certainty == .explicit,date.captureYearDerivation==nil,date.temporalDerivation==nil,
                      retained.context.current.support.first(where:{$0.field == .date}).map({$0.origin == .observed}) ?? true else{continue}
                let input=PinPrintedClockRepairInput(context:retained.context,memory:memory,record:row,group:retained.group)
                guard let task=try input.task() else{continue}
                let requestSHA=try task.digest(),marker=root.appendingPathComponent(try task.digest()+".attempt.json")
                if FileManager.default.fileExists(atPath:marker.path){continue} // A validated terminal above; never resample.
                try await verifyConnectionBeforeAttempt()
                try await check()
                let sourceCheck:@MainActor @Sendable()async throws->Void={
                    try await check()
                    guard await repository.all().contains(row),try await library.store.current(RecallHit(memory:memory,score:0))==memory,
                          PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinEvidenceError.staleRecord}
                }
                let originalSHA=try await publicImage(memory)
                try await sourceCheck()
                let permit=try await repository.synchronize(library.memories)
                let pending=await repository.pendingSemanticSources().contains(AppointmentSource(memory))
                let ticket=try await repository.prepareCanonicalReplacement(id:id)
                let provider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:originalSHA,recordID:id,recordRevision:row.canonicalRevision,groupContext:retained.group,clockRepair:input,questionRequestID:config.productReconciliation==true ? requestID:nil,check:{try await sourceCheck()})
                let attempt=Attempt(requestSHA256:requestSHA,input:input),attemptBytes=try encoder.encode(attempt)
                guard attemptBytes.count<=1048576 else{throw PinEvidenceError.invalidSupport}
                try await sourceCheck();try PinPrivatePayloadWithdrawal.write(attemptBytes,to:marker,options:.atomic)
                let receipt=try await provider.decide(task)
                try receipt.validate(for:task)
                // Persist the returned receipt before any native mutation. An
                // interrupted admission stays unresolved, never automatically retried.
                try PinPrivatePayloadWithdrawal.write(encoder.encode(receipt),to:root.appendingPathComponent(requestSHA+".receipt.json"),options:.atomic)
                try await sourceCheck()
                let draft=try PinPrintedClockRevision.draft(context:retained.context,receipt:receipt,memory:memory,record:row,ticket:ticket,accessGranted:library.authorized && library.accessReady,group:retained.group)
                if let draft {
                    try await sourceCheck()
                    let committed=try await repository.commitCanonical(draft,ticket:ticket,permit:permit)
                    if memory.visualReading != nil {try await repository.retainVisualReadingGap(memory,permit:permit,unpreparedGroups:pending)}
                    freshTemporalContexts.removeValue(forKey:id);freshTemporalCache.removeValue(forKey:id);freshTemporalReadings.removeValue(forKey:id)
                    await projectionCache.invalidateQuestionEvidence()
                    try PinPrivatePayloadWithdrawal.write(encoder.encode(Terminal(requestSHA256:requestSHA,receipt:receipt,disposition:"committed",committedRevision:committed.canonicalRevision)),to:root.appendingPathComponent(requestSHA+".terminal.json"),options:.atomic)
                }else{
                    try PinPrivatePayloadWithdrawal.write(encoder.encode(Terminal(requestSHA256:requestSHA,receipt:receipt,disposition:"held",committedRevision:nil)),to:root.appendingPathComponent(requestSHA+".terminal.json"),options:.atomic)
                }
                items=await repository.all()
                try await check()
            }
        }
        // One durable image ledger owns both initial acquisition and later
        // missing-evidence reads. Never create independent actors for one file.
        let initialImageFirst=config.initialSourcePolicy == .initialImageFirstV1
        let imageLedger:PinImageRereadLedger?
        if config.unitSourceRecovery==true {
            imageLedger=try config.authorizedImageRereadLedger(documents:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0])
        }else{imageLedger=nil}
        func acquireInitialImage(_ memory:PhotoMemory)async throws->PhotoMemory {
            guard let ledger=imageLedger else{throw PinDevelopmentError.configuration}
            try await check()
            let nativePermit=try await repository.synchronize(library.memories)
            guard try await repository.canBeginInitialVisualRead(memory,permit:nativePermit)else{return memory}
            // A prior provider attempt is never relabelled as untouched work.
            let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            let root=try PinSourceAttemptLocation.root(documents:documents,source:EvidenceSource(memory),session:config.session,regressions:config.sourceRegressions ?? [])
            let key=try PinSourceAttemptLocation.key(for:EvidenceSource(memory))
            guard !FileManager.default.fileExists(atPath:root.appendingPathComponent(key+".json").path)else{throw PinFreshProductFailure.unfinishedSourceRead}
            let oldRows=await repository.all()
            _=try await projectionCache.synchronize(memories:library.memories,records:oldRows)
            let authority=try await projectionCache.prepareInitialImageRead(memory,activeRequestID:requestID)
            let ticket=try await library.prepareTextReread(EvidenceSource(memory))
            let sourceCheck:@MainActor @Sendable()async throws->Void={
                try await check()
                guard try await library.store.current(RecallHit(memory:memory,score:0))==memory,
                      PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint,
                      await repository.all()==oldRows else{throw PinStoreError.staleImport}
                let permit=try await repository.synchronize(library.memories)
                guard try await repository.canBeginInitialVisualRead(memory,permit:permit)else{throw PinStoreError.staleImport}
                try await check()
            }
            _=try await publicImage(memory)
            try await verifyConnectionBeforeAttempt()
            freshQuestionPhase = .checkingEvidence
            let reader=try PinDeclaredAgentImageReader(authorizedPublicOriginals:Set(config.photos.map(\.sha256)),profileSHA256:config.selectedImageProfileSHA256,transport:{input in try await PinFreshImageTransport.send(input,config:config,check:{try await sourceCheck()})})
            let read=try await projectionCache.readInitialImage(authority,activeRequestID:requestID,ledger:ledger,acquire:{source in try await library.immutableCurrentImageData(for:source)},validateHost:{try await sourceCheck()},reader:reader,prepareFrame:{bytes in try PinFreshNativeFramePreparation.restore(originalImageData:bytes)})
            try await sourceCheck()
            guard let visual=read.visualReading else{throw PinEvidenceError.invalidSupport}
            try await projectionCache.admitImageReread(read,activeRequestID:requestID)
            let prepared=try await library.store.stageVisualReread(visual,ticket:ticket)
            try await sourceCheck()
            await projectionCache.invalidateQuestionEvidence()
            try await library.commitPreparedSourceReread(prepared)
            try await ledger.reconcileCommittedInitialVisualRead(prepared.after)
            try await check()
            return prepared.after
        }
        if config.retainedClockRepair==true {try await completeRetainedClock()}else{
        for originalMemory in processingMemories(library.memories) {
            try await check()
            var memory=originalMemory
            if initialImageFirst {
                if memory.revision==1,memory.visualReading==nil,!correctedSources.contains(memory.id){memory=try await acquireInitialImage(memory)}
                else if let ledger=imageLedger{try await ledger.reconcileCommittedInitialVisualRead(memory)}
            }
            if correctedSources.contains(memory.id){continue}
            if try await restoredUnitSource(memory) != nil{continue}
            let covered=await repository.canonicalCoveredSources(),rejected=await repository.rejectedSources()
            let grouped=try memory.visualReading?.validatedReceipt().visibleDocumentCount ?? 0
            let recoveringInitial=await repository.hasIncompleteInitialRead(AppointmentSource(memory))
            if recoveringInitial || grouped>1 || (!covered.contains(AppointmentSource(memory)) && !rejected.contains(AppointmentSource(memory))){try await compile(memory)}
        }
        }
        try await check();items=await repository.all()
        _=try await projectionCache.synchronize(memories:library.memories,records:items,pendingSourcePreparations:Set(await repository.pendingSemanticSources().map{EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)}))
        freshQuestionPhase = .interpretingQuestion
        if config.resultUnits==true {
            let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            let directory=documents.appendingPathComponent("fresh-unit-relations/"+config.session.uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            func sources()async throws->([PinUnitSourceEvidence],[String:String]) {
                var evidence:[PinUnitSourceEvidence]=[],hashes:[String:String]=[:]
                let rejected=await repository.rejectedSources()
                try await check()
                let memories=processingMemories(library.memories)
                // The result-unit contract requires a proof for every scoped source.
                // A completed rejection deliberately leaves no unit receipt.
                guard !memories.contains(where:{rejected.contains(AppointmentSource($0))})else {
                    throw PinFreshProductFailure.sourceReadNotAdmitted
                }
                for memory in memories.sorted(by:{$0.id<$1.id}) {
                    hashes[memory.id]=try await publicImage(memory)
                    if let restored=try await restoredUnitSource(memory){evidence.append(restored);continue}
                    if let bytes=try PinSourceAttemptLocation.completedInitialReceipt(documents:documents,source:EvidenceSource(memory),session:config.session,archives:config.completedSourceArchives ?? []) {
                        let proof=PinUnitSourceEvidence(sourceID:memory.id,initialReceipt:try JSONDecoder().decode(DecisionReceipt.self,from:bytes))
                        _=try PinProductUnitEvidence(sources:[proof]).prepare(memories:[memory],records:items.filter{$0.sourceID==memory.id},unit:.documents,initialPolicy:config.initialSourcePolicy)
                        evidence.append(proof);continue
                    }
                    let root=try PinSourceAttemptLocation.root(documents:documents,source:EvidenceSource(memory),session:config.session,regressions:config.sourceRegressions ?? [])
                    let key=try PinSourceAttemptLocation.key(for:EvidenceSource(memory))
                    let groups=root.deletingLastPathComponent().appendingPathComponent("fresh-source-groups/"+key+".json")
                    if FileManager.default.fileExists(atPath:groups.path) {
                        let result=try PinGroupedSourceResult.load(file:groups,memory:memory,records:items)
                        let proof=PinUnitSourceEvidence(sourceID:memory.id,grouped:result)
                        _=try proof.occurrenceRequest(memory:memory,records:items)
                        let permit=try await repository.synchronize(library.memories)
                        if correctedSources.contains(memory.id) {
                            guard !(await repository.pendingSemanticSources()).contains(AppointmentSource(memory))else{throw PinFreshProductFailure.unfinishedSourceRead}
                        }else{try await repository.completeGroupedSemanticRead(AppointmentSource(memory),records:items.filter{$0.allSources.contains(AppointmentSource(memory))},permit:permit)}
                        evidence.append(proof)
                    }else {
                        let bytes=try Data(contentsOf:root.appendingPathComponent(key+".unit-initial-receipt.json"))
                        guard bytes.count<=131072 else{throw PinDevelopmentError.oversized}
                        evidence.append(PinUnitSourceEvidence(sourceID:memory.id,initialReceipt:try JSONDecoder().decode(DecisionReceipt.self,from:bytes)))
                    }
                }
                let selected=try evidence.map{proof in proof.grouped != nil ? try proof.selectingOccurrencePolicy(config.sourceOccurrencePolicy):proof}
                try await check();return(selected,hashes)
            }
            var (evidence,hashes)=try await sources()
            _=try await projectionCache.synchronize(memories:library.memories,records:items,pendingSourcePreparations:Set(await repository.pendingSemanticSources().map{EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)}))
            var snapshot=try await currentAuthority(hashes)
            var proof=PinProductUnitEvidence(sources:evidence)
            func nativeUncertainty(_ task:ChoiceTask)throws->DecisionReceipt? {
                guard !correctedSources.isEmpty else{return nil}
                guard config.nativeCorrectionPolicy==PinNativeCorrectionWitness.policy,snapshot.authority.nativeCorrectionWitness != nil else{throw PinFreshProductFailure.unapprovedCorrection}
                return try PinCorrectionUncertaintyPolicy.receipt(for:task)
            }
            func retained(_ task:ChoiceTask,nativeCorrection:Bool=false)throws->DecisionReceipt {
                if nativeCorrection,let receipt=try nativeUncertainty(task){return receipt}
                let bytes=try Data(contentsOf:directory.appendingPathComponent(try task.digest()+".receipt.json"))
                guard bytes.count<=131072 else{throw PinDevelopmentError.oversized}
                let receipt=try JSONDecoder().decode(DecisionReceipt.self,from:bytes);try receipt.validate(for:task);return receipt
            }
            if previousUnits?.resultUnit=="occurrences" {
                evidence=try evidence.map{source in
                    guard source.grouped != nil else{return source}
                    let memory=library.memories.first{$0.id==source.sourceID}!,request=try source.occurrenceRequest(memory:memory,records:processingRecords(items)),task=try SourceOccurrenceInterpreter.task(request)
                    return PinUnitSourceEvidence(sourceID:source.sourceID,grouped:source.grouped,localRelationTask:task,localRelationReceipt:try retained(task,nativeCorrection:correctedSources.contains(source.sourceID)),sourceOccurrencePolicy:source.sourceOccurrencePolicy)
                }
                proof=PinProductUnitEvidence(sources:evidence)
                let prepared=try proof.prepare(memories:processingMemories(library.memories),records:processingRecords(items),unit:.occurrences,initialPolicy:config.initialSourcePolicy)
                if let task=try PinProductUnitEvidence.crossSourceRelationTask(prepared:prepared,documentIdentityV1:config.inventoryDocumentIdentityV1==true){proof=PinProductUnitEvidence(sources:evidence,crossSourceTask:task,crossSourceReceipt:try retained(task,nativeCorrection:!correctedSources.isEmpty))}
            }else if previousUnits?.resultUnit=="documents",config.inventoryDocumentIdentityV1==true {
                let prepared=try proof.prepare(memories:processingMemories(library.memories),records:processingRecords(items),unit:.documents,initialPolicy:config.initialSourcePolicy)
                if let task=try PinProductUnitEvidence.crossSourceRelationTask(prepared:prepared,documentIdentityV1:true){proof=PinProductUnitEvidence(sources:evidence,crossSourceTask:task,crossSourceReceipt:try retained(task))}
            }
            func provider(_ proof:PinProductUnitEvidence,parent:PinProductPublishedParent?=nil)throws->PinFreshProductProvider {
                let authority=snapshot.authority.withUnitEvidence(proof),memories=library.memories,rows=items
                return try PinFreshProductProvider(config:config,authority:authority,parentPublication:parent,questionRequestID:requestID,check:{
                    try await check()
                    guard await repository.all()==rows,await MainActor.run(body:{library.memories==memories})else{throw PinEvidenceError.staleRecord}
                    for memory in memories{guard try await library.store.current(RecallHit(memory:memory,score:0))==memory,PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinEvidenceError.staleRecord}}
                    try await check()
                })
            }
            let originalSnapshot=snapshot.withUnitEvidence(proof)
            let initial:PinPreparedUnitProductAnswer
            if [IBrainSemantics.CompactProductQueryPlanner.calendarDefaultsVersion,IBrainSemantics.CompactProductQueryPlanner.photoCalendarDefaultsVersion,IBrainSemantics.CompactProductQueryPlanner.locationExtentVersion,IBrainSemantics.CompactProductQueryPlanner.selectedUnitContinuationVersion].contains(config.effectiveCompactQueryVersion(hasPrevious:previousUnits != nil,hasVerifiedNativeCorrections:snapshot.authority.nativeCorrectionWitness != nil)) {
                let linked=try await projectionCache.prepareCalendarDefaultsCompactUnitProductQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,previous:previousUnits,provider:provider(proof,parent:parentPublication),usePhotoScopeComposition:config.photoCalendarDefaultsV1==true,useLocationExtent:config.savedLocationExtentV1==true,useSelectedUnitContinuation:config.selectedUnitContinuationV1==true)
                try await check()
                switch linked {
                case .inventory(let pending):initial = .inventory(pending)
                case .contextual(let answer):
                    _=try await projectionCache.readmitLinkedUnitContextualAnswer(answer);try await check();return .unitLinkedContextual(answer)
                case .unsupported:return .unsupported
                }
            }else if config.effectiveCompactQueryVersion(hasPrevious:previousUnits != nil,hasVerifiedNativeCorrections:snapshot.authority.nativeCorrectionWitness != nil)==PinPublicProductScope.currentSourceScopeQueryVersion {
                guard previousUnits==nil else{throw PinEvidenceError.staleRecord}
                let linked=try await projectionCache.prepareCurrentSourceScopeCompactUnitProductQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,provider:provider(proof))
                switch linked {
                case .inventory(let pending):initial = .inventory(pending)
                case .contextual:throw PinEvidenceError.staleRecord
                case .unsupported:return .unsupported
                }
            }else if config.effectiveCompactQueryVersion(hasPrevious:previousUnits != nil,hasVerifiedNativeCorrections:snapshot.authority.nativeCorrectionWitness != nil)==IBrainSemantics.CompactProductQueryPlanner.photoScopeInventoryVersion {
                let linked=try await projectionCache.preparePhotoScopeCompactUnitProductQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,previous:previousUnits,provider:provider(proof,parent:parentPublication))
                switch linked {
                case .inventory(let pending):initial = .inventory(pending)
                case .contextual(let answer):
                    _=try await projectionCache.readmitLinkedUnitContextualAnswer(answer);try await check();return .unitLinkedContextual(answer)
                case .unsupported:return .unsupported
                }
            }else if config.compactQueryPolicy==IBrainSemantics.CompactProductQueryPlanner.memberAwareVersion {
                let linked=try await projectionCache.prepareMemberCompactUnitProductQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,previous:previousUnits,provider:provider(proof,parent:parentPublication),useCurrentSavedInventory:config.currentSavedInventoryV21==true && snapshot.authority.nativeCorrectionWitness != nil)
                try await check()
                switch linked {
                case .contextual(let answer):
                    _=try await projectionCache.readmitLinkedUnitContextualAnswer(answer);try await check();return .unitLinkedContextual(answer)
                case .inventory(let pending):initial = .inventory(pending)
                case .unsupported:return .unsupported
                }
            }else if config.compactQueryPolicy==IBrainSemantics.CompactProductQueryPlanner.linkedUnitVersion {
                let linked=try await projectionCache.prepareLinkedCompactUnitProductQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,previous:previousUnits,provider:provider(proof,parent:parentPublication))
                try await check()
                switch linked {
                case .contextual(let answer):
                    _=try await projectionCache.readmitLinkedUnitContextualAnswer(answer);try await check();return .unitLinkedContextual(answer)
                case .inventory(let pending):initial = .inventory(pending)
                case .unsupported:return .unsupported
                }
            }else if config.compactQueryPolicy != nil {
                initial=try await projectionCache.prepareCompactUnitProductQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,previous:previousUnits,provider:provider(proof,parent:parentPublication))
            }else{
                initial=try await projectionCache.prepareUnitProductQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,previous:previousUnits,provider:provider(proof,parent:parentPublication))
            }
            try await check()
            let initialPending:PinPreparedExhaustiveAnswer
            switch initial {
            case .unsupported:return .unsupported
            case .contextual(let answer):_=try await projectionCache.readmitUnitContextualAnswer(answer);try await check();return .unitContextual(answer)
            case .inventory(let pending):initialPending=pending
            }
            func evaluate(_ pending:PinPreparedExhaustiveAnswer)async throws->PinUnitQuestionAnswer {
                let scanned=try await projectionCache.advanceExhaustiveQuestion(pending.question,activeRequestID:requestID)
                let flat=try await projectionCache.admitExhaustiveQuestion(scanned,activeRequestID:requestID)
                guard let unit=flat.pendingResultUnit else{throw PinFreshProductFailure.unresolvedEventUnits}
                func relation(_ task:ChoiceTask,proof:PinProductUnitEvidence,nativeCorrection:Bool=false)async throws->DecisionReceipt {
                    try await check();_=try await projectionCache.readmitExhaustiveAnswer(flat)
                    if nativeCorrection,let receipt=try nativeUncertainty(task) {
                        // Local invalidation, no model ledger/attempt file.
                        PinFreshProductAudit.record(question:question,stage:"correctedRelationUnestablishedLocally")
                        return receipt
                    }
                    let digest=try task.digest(),receiptFile=directory.appendingPathComponent(digest+".receipt.json"),marker=directory.appendingPathComponent(digest+".attempt.json")
                    let receipt:DecisionReceipt
                    if FileManager.default.fileExists(atPath:receiptFile.path) {
                        let bytes=try Data(contentsOf:receiptFile);guard bytes.count<=131072 else{throw PinDevelopmentError.oversized}
                        receipt=try JSONDecoder().decode(DecisionReceipt.self,from:bytes)
                    }else{
                        guard !FileManager.default.fileExists(atPath:marker.path)else{throw PinFreshProductFailure.unfinishedSourceRead}
                        try PinPrivatePayloadWithdrawal.write(encoder.encode(task),to:marker,options:.atomic)
                        receipt=try await provider(proof).decide(task)
                        try PinPrivatePayloadWithdrawal.write(encoder.encode(receipt),to:receiptFile,options:.atomic)
                    }
                    try receipt.validate(for:task);try await check();_=try await projectionCache.readmitExhaustiveAnswer(flat);return receipt
                }
                if unit == .occurrences {
                    var completed:[PinUnitSourceEvidence]=[]
                    for source in evidence {
                        if source.grouped != nil {
                            guard let memory=library.memories.first(where:{$0.id==source.sourceID})else{throw PinEvidenceError.staleRecord}
                            let request=try source.occurrenceRequest(memory:memory,records:processingRecords(items)),task=try SourceOccurrenceInterpreter.task(request)
                            let receipt=try await relation(task,proof:proof,nativeCorrection:correctedSources.contains(source.sourceID))
                            _=try SourceOccurrenceInterpreter.compile(request,task:task,receipt:receipt)
                            completed.append(PinUnitSourceEvidence(sourceID:source.sourceID,grouped:source.grouped,localRelationTask:task,localRelationReceipt:receipt,sourceOccurrencePolicy:source.sourceOccurrencePolicy))
                        }else{completed.append(source)}
                    }
                    evidence=completed;proof=PinProductUnitEvidence(sources:evidence)
                }
                let prepared=try proof.prepare(memories:processingMemories(library.memories),records:processingRecords(items),unit:unit,initialPolicy:config.initialSourcePolicy)
                var task:ChoiceTask?,receipt:DecisionReceipt?
                task=try PinProductUnitEvidence.crossSourceRelationTask(prepared:prepared,documentIdentityV1:config.inventoryDocumentIdentityV1==true)
                if let task{receipt=try await relation(task,proof:proof,nativeCorrection:unit == .occurrences && !correctedSources.isEmpty)}
                proof=PinProductUnitEvidence(sources:evidence,crossSourceTask:task,crossSourceReceipt:receipt)
                var answer=try await projectionCache.inventoryUnitQuestion(scanned,prepared:prepared,relationTask:task,relationReceipt:receipt,documentIdentityV1:config.inventoryDocumentIdentityV1==true,activeRequestID:requestID)
                if config.sourceDocumentListAssessmentV1==true{answer=try await projectionCache.sourceDocumentListQuestion(answer)}
                try await check();return answer
            }
            guard config.unitSourceRecovery==true else{return .units(try await evaluate(initialPending))}
            // An explicit correction invalidates identity, not photo content.
            // Preserve current uncertain members; never reread to undo the edit.
            if !correctedSources.isEmpty {return .units(try await evaluate(initialPending))}
            guard let ledger=imageLedger else {
                return .units(try await evaluate(initialPending))
            }
            var changed=false
            func replaceWholeSource(_ source:PinCore.EvidenceSource,recordIDs:Set<String>,authority:PinPreparedImageReread)async throws {
                guard let memory=library.memories.first(where:{EvidenceSource($0)==source})else{throw PinEvidenceError.staleRecord}
                freshQuestionPhase = .checkingEvidence
                let oldRows=await repository.all(),linked=oldRows.filter{!$0.dismissed && $0.allSources.contains(AppointmentSource(memory))}
                guard Set(linked.compactMap(\.canonicalRecordID))==recordIDs else{throw PinEvidenceError.staleRecord}
                _=try await publicImage(memory)
                let ticket=try await library.prepareTextReread(source)
                let reader=try PinDeclaredAgentImageReader(authorizedPublicOriginals:Set(config.photos.map(\.sha256)),profileSHA256:config.selectedImageProfileSHA256,transport:{input in try await PinFreshImageTransport.send(input,config:config,check:{try await check()})})
                let read=try await projectionCache.readImageReread(authority,activeRequestID:requestID,ledger:ledger,acquire:{source in try await library.immutableCurrentImageData(for:source)},validateHost:{try await check()},reader:reader,admission:.preserveVisualEvidence,framePolicy:config.pixelBoundImageFrameV2==true ? .pixelBound2400kV2:.legacy2048JPEG95,prepareFrame:{bytes in config.pixelBoundImageFrameV2==true ? try PinFreshNativeFramePreparation.restore(originalImageData:bytes):try PreparedVisualFrame.prepare(originalImageData:bytes)})
                try await check();guard await repository.all()==oldRows,let visual=read.visualReading else{throw PinEvidenceError.staleRecord}
                try await projectionCache.admitImageReread(read,activeRequestID:requestID)
                let prepared=try await library.store.stageVisualReread(visual,ticket:ticket)
                let beforePermit=try await repository.synchronize(library.memories)
                let transaction=try await repository.beginGroupReplacement(prepared,records:linked,permit:beforePermit)
                var journal=FreshUnitReplacementJournal(transactionID:transaction.id,sourceAfter:EvidenceSource(prepared.after),acquisitionID:read.acquisitionID,proof:nil)
                try FileManager.default.createDirectory(at:unitReplacementDirectory,withIntermediateDirectories:true)
                try PinPrivatePayloadWithdrawal.write(encoder.encode(journal),to:replacementFile(memory.id),options:.atomic)
                await projectionCache.invalidateQuestionEvidence()
                try await library.commitPreparedSourceReread(prepared)
                try await ledger.reconciled(acquisitionID:read.acquisitionID,sourceChanged:true)
                let revised=prepared.after,allMemories=library.memories,otherRows=oldRows.filter{!linked.contains($0)},oldIDs=Set(linked.map(\.id))
                let sourceCheck:@MainActor @Sendable()async throws->Void={
                    try await check()
                    guard library.memories==allMemories,try await library.store.current(RecallHit(memory:revised,score:0))==revised,PhotoLibrary.currentFingerprint(for:revised.id)==revised.fingerprint else{throw PinEvidenceError.staleRecord}
                    let rows=await repository.all()
                    guard rows.filter({$0.sourceID != revised.id})==otherRows,rows.filter({$0.sourceID==revised.id}).allSatisfy({!oldIDs.contains($0.id) && $0.source==AppointmentSource(revised)})else{throw PinEvidenceError.staleRecord}
                    try await check()
                }
                let permit=try await repository.synchronize(allMemories),resumed=try await repository.resumeGroupReplacement(transaction.id,permit:permit),original=try await publicImage(revised),journalBase=journal,readyFile=replacementFile(memory.id)
                let stages=try PinSourceStageJournal(directory:PinSourceStageJournal.directory(in:unitReplacementDirectory,transaction:transaction.id),transaction:transaction.id,memory:revised,originalSHA256:original,replayOnly:false)
                _=try await PinWholeSourceReplacement.compile(memory:revised,transaction:resumed,store:repository,permit:permit,directVisualGrouping:config.unitSourceRecovery==true,selectedSourceValues:config.selectedSourceValues==true,initialPolicy:config.initialSourcePolicy,provider:{input in
                    try await PinFreshProductProvider(config:config,memory:revised,originalSHA256:original,recordID:input.ticket?.id,recordRevision:input.ticket?.nextRevision,groupContext:input.group,questionRequestID:requestID,retainedGroupingInitialReceipt:input.retainedGroupingInitialReceipt,sourceStages:stages,check:{try await sourceCheck()})
                },check:{try await sourceCheck()},checkpoint:{value in
                    try await sourceCheck();var ready=journalBase;ready.proof=value
                    try PinPrivatePayloadWithdrawal.write(encoder.encode(ready),to:readyFile,options:.atomic)
                })
                changed=true;items=await repository.all()
                (evidence,hashes)=try await sources();proof=PinProductUnitEvidence(sources:evidence)
                _=try await projectionCache.synchronize(memories:library.memories,records:items,pendingSourcePreparations:Set(await repository.pendingSemanticSources().map{EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)}))
                snapshot=try await currentAuthority(hashes)
            }
            // Read the current flat evidence gaps before event-identity calls.
            // The flat answer only authorizes acquisition; it is never displayed
            // as a count/list of real-world occurrences.
            var currentPending=initialPending
            var prereadMeaning:PinCapturedExhaustiveInterpretation?
            for _ in 0..<2 {
                let scanned=try await projectionCache.advanceExhaustiveQuestion(currentPending.question,activeRequestID:requestID)
                let flat=try await projectionCache.admitExhaustiveQuestion(scanned,activeRequestID:requestID)
                try await check()
                var next:PinMissingQuestionEvidence?
                for candidate in flat.missingEvidence where candidate.reasons.contains("sourceReading") {
                    guard library.memories.contains(where:{EvidenceSource($0)==candidate.source && $0.visualReading==nil})else{continue}
                    if try await ledger.canRead(candidate.source){next=candidate;break}
                }
                guard let target=next else{break}
                if prereadMeaning==nil{prereadMeaning=try await projectionCache.captureExhaustiveInterpretation(flat,activeRequestID:requestID)}
                let rows=snapshot.authority.records.filter{!$0.dismissed && $0.allSources.contains(AppointmentSource(target.source))}
                let ids=Set(rows.compactMap(\.canonicalRecordID))
                guard ids.count==rows.count else{throw PinEvidenceError.invalidSupport}
                let authority=try await projectionCache.prepareImageReread(flat,source:target.source,activeRequestID:requestID)
                PinFreshProductAudit.record(question:question,stage:"sourceReadingBeforeRelations")
                try await replaceWholeSource(target.source,recordIDs:ids,authority:authority)
                currentPending=try await projectionCache.prepareExhaustiveQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,inferredDatePolicy:.labelledTemporalContext,interpretation:prereadMeaning!)
            }
            var answer=try await evaluate(currentPending)
            var plan=try await projectionCache.planUnitReread(answer,snapshot:snapshot,evidence:proof,initialPolicy:config.initialSourcePolicy,documentIdentityV1:config.inventoryDocumentIdentityV1==true,activeRequestID:requestID)
            let meaning:PinCapturedExhaustiveInterpretation
            if let prereadMeaning{meaning=prereadMeaning}else{meaning=try await projectionCache.captureExhaustiveInterpretation(plan,activeRequestID:requestID)}
            // A first whole-source read is not followed by an adaptive second
            // read in this request. Keep remaining uncertainty in the result.
            for _ in 0..<(prereadMeaning==nil ? 2:0) {
                var target:PinMissingQuestionEvidence?
                for candidate in plan.targets{if try await ledger.canRead(candidate.source){target=candidate;break}}
                guard let target else{break}
                let authority=try await projectionCache.prepareImageReread(plan,source:target.source,activeRequestID:requestID)
                try await replaceWholeSource(target.source,recordIDs:target.recordIDs,authority:authority)
                let pending=try await projectionCache.prepareExhaustiveQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,inferredDatePolicy:.labelledTemporalContext,interpretation:meaning)
                answer=try await evaluate(pending)
                plan=try await projectionCache.planUnitReread(answer,snapshot:snapshot,evidence:proof,initialPolicy:config.initialSourcePolicy,documentIdentityV1:config.inventoryDocumentIdentityV1==true,activeRequestID:requestID)
            }
            let reconciliation=changed ? try await projectionCache.mintProductReconciliation(initial:originalSnapshot,current:snapshot.withUnitEvidence(proof),interpretation:meaning,answer:answer):nil
            try await check();return .units(answer,reconciliation:reconciliation)
        }
        var firstPending:PinPreparedExhaustiveAnswer?
        if config.productPlanning==true {
            var originalSHA256BySourceID:[String:String]=[:]
            for memory in processingMemories(library.memories) {originalSHA256BySourceID[memory.id]=try await publicImage(memory)}
            let snapshot=try await currentAuthority(originalSHA256BySourceID)
            initialAuthority=snapshot
            let authority=snapshot.authority
            let provider=try PinFreshProductProvider(config:config,authority:authority,parentPublication:parentPublication,questionRequestID:config.productReconciliation==true ? requestID:nil,check:{try await check()})
            let initial=try await projectionCache.prepareProductQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,previous:previous,provider:provider)
            try await check()
            switch initial {
            case .contextual(let answer):return .contextual(answer)
            case .unsupported:return .unsupported
            case .inventory(let pending):firstPending=pending
            }
        }
        func query()async throws->PinExhaustiveQuestionAnswer {
            try await check();items=await repository.all()
            if firstPending==nil {_=try await projectionCache.synchronize(memories:library.memories,records:items,pendingSourcePreparations:Set(await repository.pendingSemanticSources().map{EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)}))}
            let pending:PinPreparedExhaustiveAnswer
            if let first=firstPending {
                firstPending=nil;pending=first
            }else if let capturedMeaning {
                pending=try await projectionCache.prepareExhaustiveQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,inferredDatePolicy:.labelledTemporalContext,interpretation:capturedMeaning)
            }else{
                let provider=try PinFreshProductProvider(config:config,questionRequestID:config.productReconciliation==true ? requestID:nil,check:{try await check()})
                pending=try await projectionCache.prepareExhaustiveQuestion(question,requestID:requestID,now:submittedAt,calendar:submittedCalendar,inferredDatePolicy:.labelledTemporalContext,provider:provider,planningPolicy:config.selectedPlanningPolicy)
            }
            let scanned=try await projectionCache.advanceExhaustiveQuestion(pending.question,activeRequestID:requestID)
            try await check()
            let admitted=try await projectionCache.admitExhaustiveQuestion(scanned,activeRequestID:requestID)
            if capturedMeaning==nil{capturedMeaning=try await projectionCache.captureExhaustiveInterpretation(admitted,activeRequestID:requestID)}
            try await check();return admitted
        }
        var answer=try await query()
        PinFreshProductAudit.record(question:question,stage:"beforeReread",rows:answer.displayRows,answer:answer)
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let ledger=(config.retainedEvidenceOnly==true || config.retainedClockRepair==true) ? nil:try PinImageRereadLedger(directory:docs.appendingPathComponent("fresh-reread/"+config.session.uuidString),session:config.session,maximumReads:2)
        // Full-frame local reading is attempted once per exact observation source,
        // only when the current question exposes a gap. No field strings patched.
        for _ in 0..<2 {
            guard let ledger else{break}
            var nextTarget:PinMissingQuestionEvidence?
            for candidate in answer.missingEvidence where !freshRereadSources.contains(candidate.source) {
                if try await ledger.canRead(candidate.source){nextTarget=candidate;break}
            }
            guard let target=nextTarget,let memory=library.memories.first(where:{EvidenceSource($0)==target.source})else{break}
            freshRereadSources.insert(target.source)
            _=try await publicImage(memory)
            let oldRows=await repository.all(),linked=oldRows.filter{!$0.dismissed && $0.allSources.contains(AppointmentSource(memory))}
            guard linked.count<=1 else{throw PinEvidenceError.invalidRecord}
            let ticket=try await library.prepareTextReread(target.source)
            let authority=try await projectionCache.prepareImageReread(answer,source:target.source,activeRequestID:requestID)
            let read:PinImageRereadResult
            if config.declaredImageProfileSHA256 != nil {
                let reader=try PinDeclaredAgentImageReader(authorizedPublicOriginals:Set(config.photos.map(\.sha256)),transport:{input in try await PinFreshImageTransport.send(input,config:config,check:{try await check()})})
                read=try await projectionCache.readImageReread(authority,activeRequestID:requestID,ledger:ledger,acquire:{source in try await library.immutableCurrentImageData(for:source)},validateHost:{try await check()},reader:reader,admission:.preserveVisualEvidence)
            }else{read=try await projectionCache.readImageReread(authority,activeRequestID:requestID,ledger:ledger,acquire:{source in try await library.immutableCurrentImageData(for:source)},validateHost:{try await check()},reader:PinLocalVisionReader(),readingPolicy:config.localDenseOCR==true ? .localOCRDenseV1:.verbatimFieldsV2)}
            try await check();guard await repository.all()==oldRows else{throw PinStoreError.staleResult}
            try await projectionCache.admitImageReread(read,activeRequestID:requestID)
            if read.visualReading==nil,read.lines.map(\.text).sorted()==(memory.textEvidence ?? []).map(\.text).sorted() {
                try await ledger.reconciled(acquisitionID:read.acquisitionID,sourceChanged:false)
                PinFreshProductAudit.record(question:question,stage:"rereadUnchanged",rows:items,answer:answer)
                continue // No new recognized text: preserve source bytes and unresolved answer.
            }
            await projectionCache.invalidateQuestionEvidence()
            if let visual=read.visualReading {try await library.commitVisualReread(visual,ticket:ticket)}else{try await library.commitTextReread(read.lines,ticket:ticket)}
            try await ledger.reconciled(acquisitionID:read.acquisitionID,sourceChanged:true)
            committedQuestionReread=true
            guard let revised=library.memories.first(where:{$0.id==memory.id})else{throw PinStoreError.staleImport}
            freshRereadSources.insert(EvidenceSource(revised))
            if revised != memory{
                let count=try revised.visualReading?.validatedReceipt().visibleDocumentCount ?? 0
                try await compile(revised,replacing:count>1 ? nil:linked.first?.canonicalRecordID)
            }
            answer=try await query()
            PinFreshProductAudit.record(question:question,stage:"afterReread",rows:answer.displayRows,answer:answer)
        }
        if config.temporalRoleExplanations==true {
            var readings:[String:PinTemporalRoleReading]=[:]
            for row in answer.displayRows+answer.uncertain {
                guard let id=row.canonicalRecordID,readings[id]==nil,
                      let memory=library.memories.first(where:{AppointmentSource($0)==row.source}) else{continue}
                try await check()
                guard await repository.all().contains(row),try await library.store.current(RecallHit(memory:memory,score:0))==memory,
                      PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinEvidenceError.staleRecord}
                if let restored=try? PinTemporalRoleArchive.load(directory:freshTemporalArchive,memory:memory,record:row,accessGranted:true,temporalPolicy:config.temporalPolicy) {
                    readings[id]=restored;continue
                }
                if config.retainedOCRGrouping==true,config.sourceValueRecovery=="nativeCompletionsV4",freshTemporalContexts[id]==nil,
                   let prepared=try? PinTemporalPreparationArchive.load(directory:freshTemporalPreparations,memory:memory,record:row,accessGranted:library.authorized && library.accessReady,temporalPolicy:config.temporalPolicy) {
                    freshTemporalContexts[id]=prepared.context
                    if let group=prepared.group{freshTemporalGroups[id]=group}
                }
                guard config.retainedEvidenceOnly != true,config.retainedClockRepair != true,let context=freshTemporalContexts[id]else{continue}
                guard await repository.all().contains(row),try await library.store.current(RecallHit(memory:memory,score:0))==memory,
                      PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint,
                      try PinCanonicalMapping.projection(row,scope:context.source.scope)==context.current,
                      try (freshTemporalGroups[id]?.evidence(memory:memory).source ?? PinSealedSourcePipeline.request(memory,temporalPolicy:context.effectiveTemporalPolicy).source)==context.source else{throw PinEvidenceError.staleRecord}
                if let cached=freshTemporalCache[id],(try? cached.notices(memory:memory,record:row,accessGranted:true)) != nil {readings[id]=cached;continue}
                let taskID=PinTemporalRoleContext.taskID(context)
                guard let task=try TemporalRoleExplanationInterpreter.task(id:taskID,context:context)else{continue}
                let root=docs.appendingPathComponent("fresh-explanations/"+config.session.uuidString)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let marker=root.appendingPathComponent(try task.digest()+".attempt")
                if FileManager.default.fileExists(atPath:marker.path){continue} // Terminal attempt; no resampling.
                try PinPrivatePayloadWithdrawal.write(Data(taskID.utf8),to:marker,options:.atomic)
                let digest=try await publicImage(memory)
                let provider=try PinFreshProductProvider(config:config,memory:memory,originalSHA256:digest,recordID:id,recordRevision:row.canonicalRevision,groupContext:freshTemporalGroups[id],questionRequestID:config.productReconciliation==true ? requestID:nil,check:{
                    try await check()
                    guard await repository.all().contains(row),try await library.store.current(RecallHit(memory:memory,score:0))==memory,
                          PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinEvidenceError.staleRecord}
                })
                let receipt=try await provider.decide(task)
                let reading=try PinTemporalRoleReading(context:context,receipt:receipt,groupContext:freshTemporalGroups[id])
                _=try reading.notices(memory:memory,record:row,accessGranted:true)
                try await check();guard await repository.all().contains(row)else{throw PinEvidenceError.staleRecord}
                try PinTemporalRoleArchive.save(directory:freshTemporalArchive,context:context,receipt:receipt,memory:memory,record:row,accessGranted:true,groupContext:freshTemporalGroups[id])
                freshTemporalCache[id]=reading;readings[id]=reading
            }
            try await check();freshTemporalAnswerID=answer.requestID;freshTemporalReadings=readings
        }
        try await check();hasPendingMeaning = !(await repository.pendingSemanticSources()).isEmpty
        PinFreshProductAudit.record(question:question,stage:"admitted",rows:answer.displayRows+answer.uncertain,answer:answer)
        var reconciliation:PinProductReconciliation?
        if config.productReconciliation==true,committedQuestionReread {
            guard let initialAuthority,let capturedMeaning else{throw PinEvidenceError.staleRecord}
            var originalSHA256BySourceID:[String:String]=[:]
            for memory in processingMemories(library.memories) {originalSHA256BySourceID[memory.id]=try await publicImage(memory)}
            let current=try await currentAuthority(originalSHA256BySourceID)
            reconciliation=try await projectionCache.mintProductReconciliation(initial:initialAuthority,current:current,interpretation:capturedMeaning,answer:answer)
            try await check()
        }
        return .inventory(answer,reconciliation:reconciliation)
    }
    func contextForDisplayedProductAnswer(_ answer:PinExhaustiveQuestionAnswer,library:PhotoLibrary)async throws->PinRecordQuestionContext {
        guard PinFreshProductConfiguration.enabled,let projectionCache,library.authorized,library.accessReady else{throw PinEvidenceError.staleRecord}
        func current()throws {
            for source in Set((answer.displayRows+answer.uncertain).flatMap{ $0.allSources+($0.previousEvidence?.sources ?? []) }) {
                guard PhotoLibrary.currentFingerprint(for:source.id)==source.fingerprint else{throw PinEvidenceError.staleRecord}
            }
        }
        try current()
        let context=try await projectionCache.contextForDisplayedProductAnswer(answer)
        try current();return context
    }
    func contextForDisplayedUnits(_ answer:PinUnitQuestionAnswer,library:PhotoLibrary)async throws->PinDisplayedUnitContext? {
        guard let projectionCache,library.authorized,library.accessReady,UIApplication.shared.applicationState == .active else{throw PinEvidenceError.staleRecord}
        let context=try await projectionCache.contextForUnitAnswerContinuation(answer,displayedUnitIDs:answer.rows.map(\.id))
        try await validateUnitRows(answer.rows,library:library)
        if let context{_=try await projectionCache.readmitDisplayedUnitContext(context)}
        else{_=try await projectionCache.readmitUnitQuestion(answer)}
        return context
    }
    func contextForDisplayedLinkedUnits(_ answer:PinLinkedUnitContextualAnswer,library:PhotoLibrary)async throws->PinDisplayedUnitContext {
        guard let projectionCache else{throw PinEvidenceError.staleRecord}
        try await readmitLinkedUnitAnswer(answer,library:library)
        try await validateUnitRows(answer.contextRowsForPublication,library:library)
        let context=try await projectionCache.contextForDisplayedLinkedUnitAnswer(answer)
        try await validateUnitRows(context.answerRows,library:library)
        _=try await projectionCache.readmitDisplayedUnitContext(context)
        return context
    }
    func presentationForLinkedUnitOriginal(_ answer:PinLinkedUnitContextualAnswer,previous:PinLinkedUnitContextualAnswer?,library:PhotoLibrary)async throws->PinLinkedUnitContextualAnswer {
        guard let projectionCache else{throw PinEvidenceError.staleRecord}
        try await readmitLinkedUnitAnswer(answer,library:library)
        let presentation=try await projectionCache.presentationForLinkedUnitOriginal(answer,previous:previous)
        try await validateUnitRows(presentation.rows.map{$0.selection.row},library:library)
        try await readmitLinkedUnitAnswer(answer,library:library)
        return presentation
    }
    func clearDisplayedUnits(_ context:PinDisplayedUnitContext) {
        Task{try? await projectionCache?.clearDisplayedUnitContext(context)}
    }
    func selectUnit(_ unitID:String,context:PinDisplayedUnitContext,library:PhotoLibrary)async throws->PinUnitQuestionSelection {
        guard let projectionCache else{throw PinEvidenceError.staleRecord}
        try await validateUnitRows(context.answerRows,library:library)
        let selection=try await projectionCache.selectDisplayedUnit(context,unitID:unitID)
        try await validateUnitRows(context.answerRows,library:library)
        _=try await projectionCache.readmitUnitSelection(selection);return selection
    }
    private func validateUnitRows(_ rows:[PinUnitQuestionRow],library:PhotoLibrary)async throws {
        guard let repository,!Task.isCancelled,library.authorized,library.accessReady,UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable else{throw PinEvidenceError.staleRecord}
        let current=await repository.all()
        for row in rows {for member in row.members {
            guard current.contains(member.item)else{throw PinEvidenceError.staleRecord}
            for source in member.sources {
                guard let memory=library.memories.first(where:{EvidenceSource($0)==source}),PhotoLibrary.currentFingerprint(for:source.id)==source.fingerprint,
                      try await library.store.current(RecallHit(memory:memory,score:0))==memory else{throw PinEvidenceError.staleRecord}
            }
        }}
        guard !Task.isCancelled,library.authorized,library.accessReady,UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable else{throw PinEvidenceError.staleRecord}
    }
    func readmitLinkedUnitAnswer(_ answer:PinLinkedUnitContextualAnswer,library:PhotoLibrary)async throws {
        guard let projectionCache else{throw PinEvidenceError.staleRecord}
        _=try await projectionCache.readmitLinkedUnitContextualAnswer(answer)
        try await validateUnitRows(answer.rows.map{ $0.selection.row },library:library)
        _=try await projectionCache.readmitLinkedUnitContextualAnswer(answer)
    }
    func inspectUnitOriginal(_ selection:PinUnitQuestionSelection,position:Int,library:PhotoLibrary,linked:PinLinkedUnitContextualAnswer?=nil)async throws->PhotoMemory {
        guard let projectionCache,selection.sources.indices.contains(position)else{throw PinEvidenceError.staleRecord}
        let source=selection.sources[position]
        if let linked {
            guard linked.contextID==selection.contextID,linked.rows.contains(where:{$0.selection.row.id==selection.row.id})else{throw PinEvidenceError.staleRecord}
            try await readmitLinkedUnitAnswer(linked,library:library)
        }
        _=try await projectionCache.readmitUnitSelection(selection,source:source)
        try await validateUnitRows(selection.contextRows,library:library)
        guard let memory=library.memories.first(where:{EvidenceSource($0)==source})else{throw PinEvidenceError.staleRecord}
        _=try await projectionCache.readmitUnitSelection(selection,source:source)
        try await validateUnitRows(selection.contextRows,library:library)
        _=try await projectionCache.readmitUnitSelection(selection,source:source)
        guard !Task.isCancelled,library.accessReady,PhotoLibrary.currentFingerprint(for:source.id)==source.fingerprint else{throw PinEvidenceError.staleRecord}
        if let linked{try await readmitLinkedUnitAnswer(linked,library:library)}
        return memory
    }
    func freshTemporalNotices(for row:AppointmentItem,answerID:UUID,originals:[PhotoMemory])->[String] {
        guard PinFreshProductConfiguration.enabled,freshTemporalAnswerID==answerID,
              UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable,
              items.contains(row),let id=row.canonicalRecordID,let reading=freshTemporalReadings[id],
              let memory=originals.first(where:{AppointmentSource($0)==row.source}),
              PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{return []}
        return (try? reading.notices(memory:memory,record:row,accessGranted:true)) ?? []
    }
    func inspectFreshProductOriginal(_ item:AppointmentItem,answer:PinExhaustiveQuestionAnswer,library:PhotoLibrary)async throws->PhotoMemory {
        guard PinFreshProductConfiguration.enabled,let projectionCache,let repository,
              library.authorized,library.accessReady,UIApplication.shared.applicationState == .active else{throw PinStoreError.staleResult}
        let admitted=try await projectionCache.readmitExhaustiveAnswer(answer)
        guard (admitted.displayRows+admitted.uncertain).contains(item),await repository.all().contains(item),
              let memory=library.memories.first(where:{AppointmentSource($0)==item.source}),
              try await library.store.current(RecallHit(memory:memory,score:0))==memory,
              PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinStoreError.staleResult}
        _=try await projectionCache.readmitExhaustiveAnswer(answer)
        guard await repository.all().contains(item),library.authorized,library.accessReady,
              UIApplication.shared.applicationState == .active,
              PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinStoreError.staleResult}
        return memory
    }
    func cancelFreshProductQuestion(){
        let cancelled=freshRequestID
        freshTemporalReadings=[:];freshTemporalAnswerID=nil;freshRequestID=nil;freshQuestionPhase=nil;generation += 1
        if let cancelled{Task{await projectionCache?.cancelRetrievedQuestion(ifActiveRequestID:cancelled)}}
    }
    func inspectRecordQuestion(_ item:AppointmentItem,context:PinRecordQuestionContext)async throws->PinRecordQuestionContext {
        guard Self.usesDevelopmentQuestions,let projectionCache,let repository,let id=item.canonicalRecordID else{throw PinEvidenceError.staleRecord}
        let rows=await repository.all()
        guard rows.contains(where:{$0.hasSameEvidence(as:item) && $0.canonicalRevision==item.canonicalRevision && $0.previousEvidence==item.previousEvidence})else{throw PinEvidenceError.staleRecord}
        let selected=try await projectionCache.inspectQuestionRecord(id,in:context,answerID:context.answerID)
        let current=await repository.all();guard current.contains(where:{$0.hasSameEvidence(as:item) && $0.canonicalRevision==item.canonicalRevision && $0.previousEvidence==item.previousEvidence})else{throw PinEvidenceError.staleRecord};return selected
    }
    /// The old domain row is checked on both sides of the genuine SDK capture.
    /// Failure leaves change explanation partial; canonical truth is not rolled back.
    private func captureBeforeReplacement(_ item:AppointmentItem,memories:[PhotoMemory],repository:AppointmentStore)async->PinCapturedAppointmentRevision? {
        guard let projectionCache else{return nil}
        func contains(_ rows:[AppointmentItem])->Bool {rows.contains{$0.hasSameEvidence(as:item) && $0.canonicalRevision==item.canonicalRevision && $0.previousEvidence==item.previousEvidence}}
        do {
            let before=await repository.all();guard contains(before)else{return nil}
            _=try await projectionCache.synchronize(memories:memories,records:before)
            guard !Task.isCancelled,contains(await repository.all())else{return nil}
            let captured=try await projectionCache.captureCurrentRevision(item)
            guard !Task.isCancelled,contains(await repository.all())else{return nil};return captured
        }catch{return nil}
    }
    private var developmentAttempts:Set<AppointmentSource>=[]
    /// Installed only by the isolated saved-content transport after its scoped
    /// reconstruction contract has been validated. No general task RPC fallback.
    func configureSavedContentProvider(_ provider:any DecisionProvider) throws {
        guard Self.usesSavedContent,savedContentRequestID==nil else{throw PinDevelopmentError.configuration}
        savedContentProvider=provider;savedContentPair=nil;savedContentPairBytes=nil
    }
    private enum SavedAccessPurpose {case inference,localSourceAction}
    private func validateSavedAccess(_ library:PhotoLibrary,purpose:SavedAccessPurpose = .inference, binding: SavedBinding? = nil)async throws {
        try Task.checkCancellation()
        guard Self.usesSavedContent || Self.usesCombinedSavedContent, library.authorized,library.accessReady,!library.indexing,
              UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable else{throw PinEvidenceError.staleRecord}
        let expected=library.memories
        guard await library.store.all()==expected else{throw PinEvidenceError.staleRecord}
        if Self.usesCombinedSavedContent {
            guard let bound = binding ?? combinedSavedBinding,
                  PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
                  expected == bound.memories,
                  await library.store.savedPhotoInterpretations() == bound.interpretations,
                  library.memories == bound.memories,
                  library.authorized, library.accessReady, !library.indexing,
                  UIApplication.shared.applicationState == .active,
                  UIApplication.shared.isProtectedDataAvailable else { throw PinEvidenceError.staleRecord }
        }
        let fingerprints = PhotoLibrary.currentFingerprints(for: expected.map(\.id))
        guard expected.allSatisfy({ fingerprints[$0.id] == $0.fingerprint }) else { throw PinEvidenceError.staleRecord }
        if PinSavedContentPhoneProfile.enabled {
            guard PHPhotoLibrary.authorizationStatus(for:.readWrite) == .limited,
                  let pair=savedContentPair,let pairBytes=savedContentPairBytes,pair.phoneTest != nil else{throw PinDevelopmentError.configuration}
            switch purpose {
            case .inference:try pair.validate()
            case .localSourceAction:try pair.validateLocalSourceBinding()
            }
            let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("pin-saved-content-pair.json")
            guard try Data(contentsOf:file)==pairBytes else{throw PinEvidenceError.staleRecord}
            for memory in expected {
                let source=EvidenceSource(memory)
                guard let original=pair.originals.first(where:{$0.source.id==source.id && $0.source.revision==source.revision && $0.source.fingerprint==source.fingerprint}) else{throw PinDevelopmentError.sourceNotAllowed}
                let data=try await library.immutableCurrentImageData(for:source)
                guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==original.originalSHA256 else{throw PinEvidenceError.staleRecord}
            }
            guard await library.store.all()==expected,library.memories==expected,
                  PHPhotoLibrary.authorizationStatus(for:.readWrite) == .limited,
                  try Data(contentsOf:file)==pairBytes else{throw PinEvidenceError.staleRecord}
            switch purpose {
            case .inference:try pair.validate()
            case .localSourceAction:try pair.validateLocalSourceBinding()
            }
            guard library.authorized,library.accessReady,!library.indexing,
                  UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable else{throw PinEvidenceError.staleRecord}
            for memory in expected {
                guard PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinEvidenceError.staleRecord}
            }
        }
        try Task.checkCancellation()
    }
    func savedQuestion(_ question:String,requestID:UUID,previous:PinSavedContentContext?,library:PhotoLibrary)async throws->PinSavedContentAnswer {
        try loadSavedContentPairIfNeeded()
        PinQuestionTiming.markSaved(requestID,.paired)
        if Self.usesCombinedSavedContent {
            try await prepareCombinedSavedContent(library)
        } else if let preparation=work {
            await preparation.value
        }
        PinQuestionTiming.markSaved(requestID,.prepared)
        try await validateSavedAccess(library)
        PinQuestionTiming.markSaved(requestID,.sourcesVerified)
        if savedContentCache == nil {
            openRepositoryIfAvailable()
            guard let rebuilt=savedContentCache else{throw PinDevelopmentError.configuration}
            do {
                try await rebuilt.synchronize(memories:await library.store.all(),records:[],savedInterpretations:await library.store.savedPhotoInterpretations())
                try await validateSavedAccess(library)
                guard savedContentCache === rebuilt else{throw PinEvidenceError.staleRecord}
            } catch {
                await discardSavedContentCache(rebuilt)
                throw error
            }
        }
        if savedContentProvider == nil {
            guard let pair=savedContentPair else{throw PinDevelopmentError.configuration}
            let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            savedContentProvider=try PinSavedContentReplayProvider(pair:pair,witnessURL:documents.appendingPathComponent("pin-saved-content-witness.json"))
        }
        guard let cache=savedContentCache,let provider=savedContentProvider else{throw PinDevelopmentError.configuration}
        let binding = combinedSavedBinding
        savedContentRequestID=requestID;savedContentStage = .understanding
        return try await cache.savedContentQuestion(question,requestID:requestID,previous:previous,provider:provider,
            validateAccess:{try await self.validateSavedAccess(library, binding: binding)},progress:{stage in
                await self.updateSavedStage(stage,requestID:requestID)
            })
    }
    private func updateSavedStage(_ stage:PinSavedContentStage,requestID:UUID) {
        guard savedContentRequestID==requestID else{return};savedContentStage=stage
    }
    func publishSavedAnswer(_ value:PinSavedContentAnswer,orderedRecordIDs:[String],library:PhotoLibrary)async throws->PinSavedContentContext {
        guard let cache=savedContentCache,savedContentRequestID==value.requestID else{throw PinEvidenceError.staleRecord}
        return try await cache.contextForDisplayingSavedContent(value,orderedRecordIDs:orderedRecordIDs,validateAccess:{try await self.validateSavedAccess(library)})
    }
    func savedOriginals(_ value:PinSavedContentAnswer,recordID:String,library:PhotoLibrary)async throws->[PhotoMemory] {
        guard let cache=savedContentCache else{throw PinEvidenceError.staleRecord}
        let sources=try await cache.savedContentOriginalSources(value,recordID:recordID,validateAccess:{try await self.validateSavedAccess(library,purpose:.localSourceAction)})
        let rows=await library.store.all()
        let memories=try sources.map{source->PhotoMemory in
            guard let memory=rows.first(where:{EvidenceSource($0)==source}),library.memories.contains(memory),
                  PhotoLibrary.currentFingerprint(for:source.id)==source.fingerprint else{throw PinEvidenceError.staleRecord};return memory
        }
        try await validateSavedAccess(library,purpose:.localSourceAction);return memories
    }
    private func discardSavedContentCache(_ cache:PinAppointmentProjectionCache)async {
        // A failed derived-store write closes its actor. Never reuse it or evict a newer owner.
        if savedContentCache === cache { savedContentCache=nil; combinedSavedBinding=nil }
        await cache.close()
    }
    func saveInterpretation(_ text:String?,source:EvidenceSource,expected:SavedPhotoInterpretation?,library:PhotoLibrary)async throws->SavedInterpretationSaveResult {
        try await validateSavedAccess(library,purpose:.localSourceAction)
        _ = try await library.store.savePhotoInterpretation(source:source,correction:text,expected:expected)
        // The native save is authoritative; derived preparation cannot undo that success.
        cancelSavedQuestion()
        if Self.usesCombinedSavedContent {
            combinedSavedBinding = nil
            return .preparationPending
        }
        guard let cache=savedContentCache else{return .preparationPending}
        do {
            try await cache.synchronize(memories:await library.store.all(),records:[],savedInterpretations:await library.store.savedPhotoInterpretations())
            guard savedContentCache === cache else{return .preparationPending}
            return .ready
        } catch {
            await discardSavedContentCache(cache)
            return .preparationPending
        }
    }
    func cancelSavedQuestion(ifActiveRequestID requestID:UUID?=nil) {
        guard let active=savedContentRequestID,requestID==nil || requestID==active else{return}
        (savedContentProvider as? any PinSavedContentReplayProviding)?.invalidate(requestID:active)
        savedContentRequestID=nil;savedContentStage=nil
        if let cache=savedContentCache{Task{await cache.cancelSavedContentQuestion(ifActiveRequestID:active)}}
    }
    func pauseForBackground() {
        if let active=savedContentRequestID {
            (savedContentProvider as? any PinSavedContentReplayProviding)?.invalidate(requestID:active)
            savedContentStage=nil
            if let cache=savedContentCache {
                Task {
                    let retained=await cache.pauseSavedContentQuestion(ifActiveRequestID:active)
                    if !retained,savedContentRequestID==active {savedContentRequestID=nil}
                }
            } else {savedContentRequestID=nil}
        }
        freshTemporalReadings=[:];freshTemporalAnswerID=nil
        freshRequestID=nil;generation += 1; work?.cancel(); running=false; queuedMemories=nil; activeSources=[:];developmentAttempts.removeAll()
    }
    func synchronize(_ memories: [PhotoMemory], photoStore: MemoryStore) {
        questionPhotoStore=photoStore
        if Self.usesSavedContent {
            // Reuse the native observations and their one correction ledger.
            // The appointment repository is not written by this opt-in route.
            if savedContentCache == nil {openRepositoryIfAvailable()}
            guard let cache=savedContentCache else{return}
            generation += 1;let current=generation;work?.cancel();running=true
            work=Task {
                defer{if current==generation{running=false}}
                do{try await cache.synchronize(memories:memories,records:[],savedInterpretations:await photoStore.savedPhotoInterpretations())}
                catch{
                    await discardSavedContentCache(cache)
                    if !Task.isCancelled,current==generation{message="Pin couldn't prepare the saved photo evidence. Your originals are kept."}
                }
            }
            return
        }
        if freshRequestID != nil {queuedMemories=memories;return}
        openRepositoryIfAvailable()
        let sources = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, AppointmentSource($0)) })
        // Appending unrelated photos must not starve a card read already underway.
        // Removal or revision changes still cancel immediately.
        if running && activeSources.allSatisfy({ sources[$0.key] == $0.value }) {
            queuedMemories = memories; return
        }
        queuedMemories = nil; activeSources = sources; running = true
        generation += 1; let current = generation; work?.cancel()
        work = Task {
            defer {
                if current == generation {
                    running = false
                    if let queued = queuedMemories { queuedMemories = nil; synchronize(queued, photoStore: photoStore) }
                }
            }
            guard let repository else { await removeObsoleteReminders([]); return }
            do {
                var capturedChanges:[String:PinCapturedAppointmentRevision]=[:]
                let currentMemories = memories.filter { !AppointmentCardReader.isPinInterface($0.text) }.filter { memory in
                    let needsSourceRead = AppointmentCardReader.isCandidate(memory.text) || SemanticSourceReplay.entry(for: memory) != nil
                    return !needsSourceRead || PhotoLibrary.currentFingerprint(for: memory.id) == memory.fingerprint
                }
                let permit = try await repository.synchronize(currentMemories)
                hasPendingMeaning = !(await repository.pendingSemanticSources()).isEmpty
                guard !Task.isCancelled, current == generation else { return }
                let initial = await repository.all()
                guard !Task.isCancelled, current == generation else { return }
                items = initial
                // A source newly recognized as quoted/example material may
                // already have a rule-derived row from an older admission
                // pass. Withdraw only that exact, still-current source row.
                let byID = Dictionary(uniqueKeysWithValues: currentMemories.map { ($0.id, $0) })
                for item in initial where AppointmentRuleReconciliation.shouldWithdraw(item, current: byID[item.sourceID]) {
                    try await repository.removeCurrent(item.source, permit: permit)
                }
                items = await repository.all()
                guard !Task.isCancelled, current == generation else { return }
                await reconcileReminders()
                if PinFreshProductConfiguration.enabled {
                    freshTemporalGroups=freshTemporalGroups.filter { id,group in
                        items.contains { row in
                            row.canonicalRecordID==id && !row.dismissed && currentMemories.contains { memory in
                                guard let request=try? group.request(memory:memory,temporalPolicy:.anchoredSpansV9),let projection=try? PinCanonicalMapping.projection(row,scope:request.source.scope)else{return false}
                                return (try? group.validate(memory:memory,projection:projection)) != nil
                            }
                        }
                    }
                    freshTemporalContexts=freshTemporalContexts.filter { id,context in
                        items.contains { row in row.canonicalRecordID==id && !row.dismissed && (try? PinCanonicalMapping.projection(row,scope:context.source.scope))==context.current }
                        && currentMemories.contains { memory in (try? (freshTemporalGroups[id]?.evidence(memory:memory).source ?? PinSealedSourcePipeline.request(memory,temporalPolicy:context.effectiveTemporalPolicy).source))==context.source }
                    }
                    freshTemporalCache=freshTemporalCache.filter{freshTemporalContexts[$0.key] != nil}
                    try PinTemporalRoleArchive.prune(directory:freshTemporalArchive,memories:currentMemories,records:items)
                    try PinTemporalPreparationArchive.prune(directory:freshTemporalPreparations,memories:currentMemories,records:items)
                    let preparationDirectory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("fresh-source-assessments")
                    let preparationSources=currentMemories.filter { memory in
                        !items.contains{$0.dismissed && $0.allSources.contains(AppointmentSource(memory))}
                    }
                    try PinSourcePreparationArchive.prune(directory:preparationDirectory,memories:preparationSources)
                    try PinGroupedSourceResult.prune(directory:preparationDirectory.deletingLastPathComponent().appendingPathComponent("fresh-source-groups"),memories:preparationSources,records:items)
                    let replacementDirectory=preparationDirectory.deletingLastPathComponent().appendingPathComponent("fresh-unit-replacements-v1")
                    if FileManager.default.fileExists(atPath:replacementDirectory.path){
                        for file in try FileManager.default.contentsOfDirectory(at:replacementDirectory,includingPropertiesForKeys:nil) where file.pathExtension=="json" {
                            let bytes=try Data(contentsOf:file)
                            guard bytes.count<=1_048_576 else{throw PinDevelopmentError.oversized}
                            let journal=try JSONDecoder().decode(FreshUnitReplacementJournal.self,from:bytes)
                            if !currentMemories.contains(where:{$0.id==journal.sourceAfter.id}){try FileManager.default.removeItem(at:file)}
                        }
                    }
                    try PinSourceStageJournal.prune(in:replacementDirectory,memories:preparationSources)
                    _=try await projectionCache?.synchronize(memories:currentMemories,records:items,pendingSourcePreparations:Set(await repository.pendingSemanticSources().map{EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)}))
                    return // This route prepares semantics only for an actual question.
                }
                let known = items.filter { $0.readerVersion == AppointmentCardReader.version }.reduce(into: [String:AppointmentSource]()) { $0[$1.sourceID] = $1.source }
                let knownSemantic = items.filter { $0.observation.semanticVersion == SemanticAppointmentCompiler.version }.reduce(into: [String:AppointmentSource]()) { $0[$1.sourceID] = $1.source }
                let quotedVersion = SemanticSourceReplay.sourceAnchorIdentities ? QuotedAppointmentCompiler.sourceAnchorVersion : QuotedAppointmentCompiler.version
                let knownQuoted = items.filter { $0.observation.semanticVersion == quotedVersion }.reduce(into: [String:AppointmentSource]()) { $0[$1.sourceID] = $1.source }
                // Recorded proposals exercise Pin's real writer with actual PhotoKit
                // identities. This development route is absent from phone/Release.
                if let recorded=Self.recordedAppointments {
                    for entry in recorded where currentMemories.contains(where:{AppointmentSource($0)==entry.source}) {
                        guard !Task.isCancelled,current==generation else{return}
                        let rows=await repository.all()
                        if await repository.canonicalCoveredSources().contains(entry.source){continue}
                        if rows.contains(where:{$0.canonicalRecordID != nil && $0.allSources.contains(entry.source)}){continue}
                        let ticket:CanonicalWriteTicket
                        var priorCapture:PinCapturedAppointmentRevision?
                        if let replacing=entry.replacesSource {
                            let matches=rows.filter{$0.canonicalRecordID != nil && $0.allSources.contains(replacing)}
                            guard matches.count==1,let id=matches[0].canonicalRecordID else{continue}
                            priorCapture=await captureBeforeReplacement(matches[0],memories:currentMemories,repository:repository)
                            ticket=try await repository.prepareCanonicalReplacement(id:id)
                        }else{ticket=await repository.reserveCanonicalRecord()}
                        let draft=try entry.draft(ticket:ticket,memories:currentMemories)
                        for source in draft.sources {
                            guard PhotoLibrary.currentFingerprint(for:source.id)==source.fingerprint else{throw PinStoreError.staleImport}
                        }
                        _=try await repository.commitCanonical(draft,ticket:ticket,permit:permit)
                        if let priorCapture{capturedChanges[priorCapture.recordID]=priorCapture}
                    }
                    items=await repository.all()
                }
                if Self.usesDevelopmentSourceReader,!PinSealedQualification.isEnabled,Self.developmentPair==nil{throw PinDevelopmentError.configuration}
                if Self.usesDevelopmentSourceReader,let pair=Self.developmentPair {
                    let reader=PinDevelopmentSourceReader(provider:try PinDevelopmentDecisionProvider(pair:pair))
                    for memory in currentMemories {
                        let source=AppointmentSource(memory)
                        guard pair.allowedTextSHA256.contains(try PinDevelopmentSourceReader.textDigest((memory.textEvidence ?? []).map(\.text))) else{
                            if PinSealedQualification.usesReviewedSession,let session=pair.sealedSession {
                                // A new known fixture whose actual OCR is outside
                                // the frozen list must remain visibly pending.
                                // Exact pixel proof here is LOCAL only; every
                                // intelligence provider still requires its strict
                                // per-slot text/session/profile checks.
                                if (try? await PhotoLibrary.fixtureWitnesses([memory],session:session,requiresListedText:false)) != nil {
                                    guard !Task.isCancelled,current==generation,
                                          try await photoStore.current(RecallHit(memory:memory,score:0))==memory,
                                          PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinStoreError.staleImport}
                                    try await repository.beginSemanticRead(source,permit:permit)
                                    items=await repository.all();hasPendingMeaning=true
                                    let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("pin-source-qualification-trace.jsonl")
                                    PinSourceTraceRecorder(url:file).sink(.init(stage:"native.fixtureText.unlisted",outcome:"held",memory:memory))
                                    message="The sample photo has a different text reading. Its latest appointment details remain unresolved; the original is kept."
                                }
                            }
                            continue
                        }
                        if await repository.canonicalCoveredSources().contains(source),!(await repository.pendingSemanticSources().contains(source)){continue}
                        if await repository.rejectedSources().contains(source){continue}
                        if developmentAttempts.contains(source){continue}
                        developmentAttempts.insert(source)
                        do {
                            try await repository.beginSemanticRead(source,permit:permit);items=await repository.all();hasPendingMeaning=true
                            let authoritative=try await photoStore.current(RecallHit(memory:memory,score:0))
                            guard PhotoLibrary.currentFingerprint(for:memory.id)==source.fingerprint else{throw PinStoreError.staleImport}
                            if PinSealedQualification.isEnabled {
                                if let captured=try await readSealedSource(authoritative,photoStore:photoStore,repository:repository,permit:permit,current:current,memories:currentMemories,pair:pair){capturedChanges[captured.recordID]=captured}
                                continue
                            }
                            let candidate=try await reader.read(authoritative)
                            guard !Task.isCancelled,current==generation else{return}
                            let refreshed=try await photoStore.current(RecallHit(memory:memory,score:0))
                            guard refreshed==authoritative,PhotoLibrary.currentFingerprint(for:memory.id)==source.fingerprint else{throw PinStoreError.staleImport}
                            if candidate.disposition == .booking {
                                let rows=await repository.all(),matches=try PinDevelopmentSourceReader.matchingRecords(candidate,records:rows,memories:currentMemories)
                                let ticket:CanonicalWriteTicket,draft:CanonicalAppointmentDraft
                                var priorCapture:PinCapturedAppointmentRevision?
                                if let existing=matches.first {
                                    guard matches.count==1,let id=existing.canonicalRecordID else{throw PinEvidenceError.invalidRecord}
                                    let prior=currentMemories.filter{existing.allSources.contains(AppointmentSource($0))}
                                    let documents=prior+[refreshed]
                                    let proposal=try await reader.bundle(documents,rolePolicy:Self.developmentRolePolicy)
                                    guard !Task.isCancelled,current==generation else{return}
                                    for original in documents {
                                        let latest=try await photoStore.current(RecallHit(memory:original,score:0))
                                        guard latest==original,PhotoLibrary.currentFingerprint(for:original.id)==original.fingerprint else{throw PinStoreError.staleImport}
                                    }
                                    priorCapture=await captureBeforeReplacement(existing,memories:currentMemories,repository:repository)
                                    guard !Task.isCancelled,current==generation else{return}
                                    for original in documents {guard PhotoLibrary.currentFingerprint(for:original.id)==original.fingerprint else{throw PinStoreError.staleImport}}
                                    ticket=try await repository.prepareCanonicalReplacement(id:id)
                                    draft=try PinDevelopmentSourceReader.bundleDraft(proposal,ticket:ticket,memories:documents,primarySourceID:refreshed.id,rolePolicy:Self.developmentRolePolicy,valuePolicy:Self.developmentValuePolicy)
                                }else{
                                    guard PinDevelopmentSourceReader.unlinkedAdmissionAllowed(provider:(candidate.appointment ?? candidate.partialAppointment)?.provider,records:rows) else{throw PinEvidenceError.invalidRecord}
                                    ticket=await repository.reserveCanonicalRecord()
                                    draft=try PinDevelopmentSourceReader.draft(candidate,ticket:ticket,memory:refreshed,valuePolicy:Self.developmentValuePolicy)
                                }
                                _=try await repository.commitCanonical(draft,ticket:ticket,permit:permit)
                                if let priorCapture{capturedChanges[priorCapture.recordID]=priorCapture}
                            }else if candidate.disposition == .notBooking {try await repository.rejectSource(PinDevelopmentSourceReader.rejection(candidate,memory:refreshed),permit:permit)}
                        }catch is CancellationError{return}
                        catch {message="The fictional source interpreter couldn't confirm these details. Your photo index is kept."}
                    }
                    items=await repository.all();hasPendingMeaning = !(await repository.pendingSemanticSources()).isEmpty
                }
                let canonicalSources=Set(await repository.canonicalCoveredSources().map(\.id)).union(await repository.rejectedSources().map(\.id)).union(await repository.pendingSemanticSources().map(\.id))
                for memory in currentMemories {
                    if canonicalSources.contains(memory.id){continue}
                    if PinSealedQualification.isEnabled{continue} // no rule-derived substitute for unapproved/unresolved sources
                    // An attempted semantic source must not silently become a
                    // rule-derived booking when its model fails or holds.
                    if Self.usesDevelopmentSourceReader,let pair=Self.developmentPair,
                       pair.allowedTextSHA256.contains((try? PinDevelopmentSourceReader.textDigest((memory.textEvidence ?? []).map(\.text))) ?? ""){continue}
                    guard !Task.isCancelled, current == generation else { return }
                    let source = AppointmentSource(memory)
                    if let replay = SemanticSourceReplay.entry(for: memory) {
                        if replay.quotedProposal != nil || replay.liveCaseID != nil,
                           knownQuoted[memory.id] == source { continue }
                        if replay.choices != nil, knownSemantic[memory.id] == source { continue }
                        let authoritative = try await photoStore.current(RecallHit(memory: memory, score: 0))
                        guard !Task.isCancelled, current == generation,
                              PhotoLibrary.currentFingerprint(for: memory.id) == memory.fingerprint,
                              let read = SemanticSourceReplay.read(authoritative) else { continue }
                        if let caseID = replay.liveCaseID {
                            let proposal: QuotedAppointmentDocument
                            do {
                                proposal = try await SemanticSourceReplay.liveProposal(
                                    caseID: caseID, digest: replay.textDigest, read: read)
                            } catch {
                                message = "The fictional source test couldn't reach its interpreter. Your photo index is unchanged."
                                continue
                            }
                            guard !Task.isCancelled, current == generation,
                                  PhotoLibrary.currentFingerprint(for: memory.id) == memory.fingerprint else { continue }
                            let refreshed = try await photoStore.current(RecallHit(memory: memory, score: 0))
                            guard let currentRead = SemanticSourceReplay.read(refreshed),
                                  AppointmentSourceDigest.text(currentRead.observations.map(\.line)) == replay.textDigest else { continue }
                            switch QuotedAppointmentCompiler.compile(proposal,
                                requestedTextDigest: replay.textDigest, read: currentRead,
                                current: refreshed, timePolicy: .deviceZoneAtRead(.current)) {
                            case .bookings(let events):
                                try await repository.putSemanticEvents(events, source: source, permit: permit)
                            case .notBooking: try await repository.removeCurrent(source, permit: permit)
                            case .unresolved: message = "The fictional source test couldn't confirm these booking details."
                            }
                        } else if let proposal = replay.quotedProposal {
                            switch QuotedAppointmentCompiler.compile(proposal,
                                requestedTextDigest: replay.textDigest, read: read,
                                current: authoritative, timePolicy: .deviceZoneAtRead(.current),
                                identityPolicy: SemanticSourceReplay.sourceAnchorIdentities ? .sourceAnchors : .printedReference) {
                            case .bookings(let events):
                                try await repository.putSemanticEvents(events, source: source, permit: permit)
                            case .notBooking: try await repository.removeCurrent(source, permit: permit)
                            case .unresolved: break
                            }
                        } else if let choices = replay.choices {
                            switch SemanticAppointmentCompiler.compile(choices, read: read,
                                                                      current: authoritative,
                                                                      timePolicy: .deviceZoneAtRead(.current)) {
                            case .booking(let candidate): try await repository.putSemantic(candidate, permit: permit)
                            case .notBooking: try await repository.removeCurrent(source, permit: permit)
                            case .unresolved: break
                            }
                        }
                        guard !Task.isCancelled, current == generation else { return }
                        items = await repository.all()
                        continue
                    }
                    guard AppointmentCardReader.isCandidate(memory.text), known[memory.id] != source else { continue }
                    guard let image = await PhotoLibrary.image(for: memory.id, size: CGSize(width: 1800, height: 1800)), let cg = image.cgImage else { continue }
                    let read = try await Task.detached(priority: .utility) { try CardOCR.read(cg) }.value
                    guard !Task.isCancelled, current == generation else { return }
                    _ = try await photoStore.current(RecallHit(memory: memory, score: 0))
                    guard PhotoLibrary.currentFingerprint(for: memory.id) == memory.fingerprint else { continue }
                    let card = AppointmentCardReader.extract(read.lines, sourceID: memory.id, deviceTimeZone: .current, photographedAt: memory.photographedAt, isScreenshot: memory.isScreenshot)
                    try await repository.put(AppointmentItem(source: AppointmentSource(memory), observation: card), permit: permit)
                    guard !Task.isCancelled, current == generation else { return }
                    let updated = await repository.all()
                    guard !Task.isCancelled, current == generation else { return }
                    items = updated
                }
                if let projectionCache {
                    _=try await projectionCache.synchronize(memories:currentMemories,records:items,recordingChangesFrom:capturedChanges.values.sorted{$0.recordID<$1.recordID})
                    guard !Task.isCancelled,current==generation else{return}
                }
                await reconcileReminders()
                await auditForSimulator("synchronized")
            } catch is CancellationError { }
            catch PinStoreError.staleImport { }
            catch PinStoreError.staleResult { }
            catch {
                guard current == generation else { return }
                message = "Pin couldn't finish reading appointment cards. Your photos are kept."
                await removeObsoleteReminders([])
            }
        }
    }

    private func readSealedSource(_ memory:PhotoMemory,photoStore:PinCore.MemoryStore,repository:AppointmentStore,permit:AppointmentPermit,current:Int,memories:[PhotoMemory],pair:PinDevelopmentPair)async throws->PinCapturedAppointmentRevision? {
        let traceFile=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("pin-source-qualification-trace.jsonl")
        let recorder=PinSourceTraceRecorder(url:traceFile),trace=recorder.sink
        trace(.init(stage:"native.read.begin",memory:memory))
        let checkSource:@MainActor @Sendable()async throws->Void={ [weak self] in
            guard let self,!Task.isCancelled,self.generation==current else{throw CancellationError()}
            let actual=try await photoStore.current(RecallHit(memory:memory,score:0))
            guard actual==memory,PhotoLibrary.currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinStoreError.staleImport}
        }
        let witnesses: [PinFixtureSourceWitness]
        if let session=pair.sealedSession{witnesses=try await PhotoLibrary.fixtureWitnesses([memory],session:session);try await checkSource()}else{witnesses=[]}
        let initialProvider=try PinSealedSourceDecisionProvider(pair:pair,memory:memory,contextZone:TimeZone.current.identifier,witnesses:witnesses,validateCurrent:{try await checkSource()})
        let initial=try await PinSealedSourcePipeline.initial(memory,provider:initialProvider,trace:trace);try await checkSource()
        if initial.disposition == .notBooking{try await repository.rejectSource(PinSealedSourcePipeline.rejection(initial,memory:memory),permit:permit);return nil}
        guard initial.disposition == .booking else{return nil}
        let rows=await repository.all(),matches=try PinDevelopmentSourceReader.matchingRecords(initial,records:rows,memories:memories)
        guard matches.count<=1 else{throw PinEvidenceError.invalidRecord}
        let existing=matches.first,ticket:CanonicalWriteTicket
        var captured:PinCapturedAppointmentRevision?
        if let existing,let id=existing.canonicalRecordID {
            captured=await captureBeforeReplacement(existing,memories:memories,repository:repository)
            ticket=try await repository.prepareCanonicalReplacement(id:id)
        }else {
            guard PinDevelopmentSourceReader.unlinkedAdmissionAllowed(provider:(initial.appointment ?? initial.partialAppointment)?.provider,records:rows)else{throw PinEvidenceError.invalidRecord}
            ticket=await repository.reserveCanonicalRecord()
        }
        trace(.init(stage:"native.ticket",memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision))
        let documents=(existing.map{row in memories.filter{row.allSources.contains(AppointmentSource($0))}} ?? [])+[memory]
        let checkAll:@MainActor @Sendable()async throws->Void={
            try await checkSource()
            for original in documents {
                guard try await photoStore.current(RecallHit(memory:original,score:0))==original,PhotoLibrary.currentFingerprint(for:original.id)==original.fingerprint else{throw PinStoreError.staleImport}
            }
            if let existing{guard await repository.all().contains(existing)else{throw PinStoreError.staleResult}}
        }
        let provider=try PinSealedSourceDecisionProvider(pair:pair,memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,contextZone:TimeZone.current.identifier,witnesses:witnesses,validateCurrent:{try await checkAll()})
        let completed=try await PinSealedSourcePipeline.complete(initial,memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,contextZone:TimeZone.current.identifier,provider:provider,trace:trace)
        try await checkAll()
        trace(.init(stage:"native.DTO.begin",memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,date:completed.projection.appointment.date))
        let draft:CanonicalAppointmentDraft
        if existing != nil {
            guard let session=pair.sealedSession else{throw PinDevelopmentError.configuration}
            let bundleWitnesses=try await PhotoLibrary.fixtureWitnesses(documents,session:session);try await checkAll()
            let linkedProvider=try PinSealedSourceDecisionProvider(pair:pair,memories:documents,recordID:ticket.id,recordRevision:ticket.nextRevision,contextZone:TimeZone.current.identifier,witnesses:bundleWitnesses,validateCurrent:{try await checkAll()})
            let bundleRequest=try PinDevelopmentSourceReader.bundleRequest(documents)
            let bundleTask=try ComponentEvidenceBundleInterpreter.task(for:bundleRequest,rolePolicy:session.bundleComponentRolePolicy)
            let bundleReceipt=try await linkedProvider.decide(bundleTask);try await checkAll()
            let linked=try ComponentEvidenceBundleInterpreter.compileRecoveringSelectedCivilDate(bundleReceipt,for:bundleRequest,recordID:ticket.id,recordRevision:ticket.nextRevision,rolePolicy:session.bundleComponentRolePolicy)
            try await checkAll()
            draft=try PinSealedSourcePipeline.replacementDraft(completed,linked:linked,ticket:ticket,memories:documents,primarySourceID:memory.id,rolePolicy:session.bundleComponentRolePolicy)
        }else{draft=try PinSealedSourcePipeline.draft(completed,ticket:ticket,memory:memory)}
        trace(.init(stage:"native.DTO.ready",memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,date:completed.projection.appointment.date))
        try await checkAll();_=try await repository.commitCanonical(draft,ticket:ticket,permit:permit,diagnostic:{stage in trace(.init(stage:"native.admission."+stage,outcome:"fail",memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision))})
        trace(.init(stage:"native.admitted",memory:memory,recordID:ticket.id,recordRevision:ticket.nextRevision,date:completed.projection.appointment.date))
        return captured
    }
    /// Saves only an explicit native edit. No semantic inference or source read.
    /// A failed derived refresh cannot undo or misreport a committed domain edit.
    func correct(_ item:AppointmentItem,with correction:AppointmentOwnerCorrection,library:PhotoLibrary)async throws->(item:AppointmentItem,current:Bool) {
        openRepositoryIfAvailable()
        guard let repository,!running else{throw PinStoreError.staleResult}
        cancelFreshProductQuestion();let owner=generation
        func checkSources()async throws {
            guard owner==generation,!Task.isCancelled,library.authorized,library.accessReady,
                  UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable else{throw PinStoreError.staleResult}
            for source in item.allSources {
                guard let memory=library.memories.first(where:{AppointmentSource($0)==source}),
                      PhotoLibrary.currentFingerprint(for:source.id)==source.fingerprint,
                      try await library.store.current(RecallHit(memory:memory,score:0))==memory else{throw PinStoreError.staleResult}
            }
            guard owner==generation,!Task.isCancelled,library.authorized,library.accessReady,
                  UIApplication.shared.applicationState == .active else{throw PinStoreError.staleResult}
        }
        try await checkSources();guard await repository.all().contains(item)else{throw PinStoreError.staleResult}
        let captured=await captureBeforeReplacement(item,memories:library.memories,repository:repository)
        let permit=try await repository.synchronize(library.memories)
        try await checkSources()
        let updated=try await repository.correct(item,with:correction,permit:permit)
        items=await repository.all()
        if let projectionCache {
            do{_=try await projectionCache.synchronize(memories:library.memories,records:items,recordingChangesFrom:captured.map{[$0]} ?? [])}
            catch{message="Your correction was saved. Reopen the details to refresh this reading."}
        }
        await reconcileReminders()
        let current=(try? await checkSources()) != nil && items.contains(updated)
        return (updated,current)
    }
    /// Explicit same-object opening after a native correction needs no LLM or
    /// stale ordinal. Recheck the whole current row and source on both sides.
    func originalForCorrectedRecord(_ item:AppointmentItem,source:AppointmentSource,library:PhotoLibrary)async throws->PhotoMemory {
        guard let repository,item.allSources.contains(source),await repository.all().contains(item),
              library.authorized,library.accessReady,UIApplication.shared.applicationState == .active,
              let memory=library.memories.first(where:{AppointmentSource($0)==source}),
              PhotoLibrary.currentFingerprint(for:source.id)==source.fingerprint,
              try await library.store.current(RecallHit(memory:memory,score:0))==memory,
              await repository.all().contains(item),library.authorized,library.accessReady,
              UIApplication.shared.applicationState == .active else{throw PinStoreError.staleResult}
        return memory
    }
    func dismiss(_ item: AppointmentItem) async {
        guard let repository else { return }
        do { try await repository.dismiss(item); items = await repository.all(); if PinSealedQualification.isEnabled,let projectionCache,let questionPhotoStore { _=try await projectionCache.synchronize(memories:await questionPhotoStore.all(),records:items) }; await reconcileReminders(); await auditForSimulator("dismissed") }
        catch { message = "This appointment changed. Please reopen its original photo." }
    }
    func approve(_ item: AppointmentItem) async {
        guard let repository else { return }
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            guard allowed else { message = "Notifications are off. You can allow them in iPhone Settings. The card stays here."; return }
            guard PhotoLibrary.currentFingerprint(for: item.sourceID) == item.source.fingerprint else { throw PinStoreError.staleResult }
            try await repository.approve(item)
            items = await repository.all()
            await reconcileReminders()
            if AppointmentReminderPlanner.plan(items.first(where: { $0.id == item.id }) ?? item, now: Date()).isEmpty {
                message = "It's too close to this appointment for an advance reminder. The details stay here."
            }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--test-appointment-notification") {
                let content = UNMutableNotificationContent(); content.title = "Pin test reminder"; content.body = "A fictional appointment card is ready to review."; content.sound = .default
                content.userInfo = ["sourceID": item.sourceID, "fingerprint": item.source.fingerprint]
                try await center.add(UNNotificationRequest(identifier: prefix + "test." + item.id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 12, repeats: false)))
            }
            #endif
            await auditForSimulator("approved")
        } catch { message = "The reminder couldn't be saved. Please try again." }
    }
    private func requests(_ items: [AppointmentItem]) -> [UNNotificationRequest] {
        items.filter { PhotoLibrary.currentFingerprint(for: $0.sourceID) == $0.source.fingerprint }.flatMap { item in
            AppointmentReminderPlanner.plan(item, now: Date()).map { plan in
                let binding = "\(item.id)|\(item.source.fingerprint)|\(item.source.revision)|\(plan.key)"
                let digest = SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
                let content = UNMutableNotificationContent()
                content.title = "Something to remember"
                content.body = "An appointment from your photos is coming up. Open Pin for the details."
                content.sound = .default
                content.userInfo = ["sourceID": item.sourceID, "fingerprint": item.source.fingerprint]
                var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: plan.timeZoneID)!
                var date = cal.dateComponents([.year, .month, .day, .hour, .minute], from: plan.date); date.timeZone = cal.timeZone
                return UNNotificationRequest(identifier: prefix + digest, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: false))
            }
        }
    }
    private func removeObsoleteReminders(_ desired: [UNNotificationRequest]) async {
        let ids = Set(desired.map(\.identifier))
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(prefix) && !ids.contains($0.identifier) }.map(\.identifier))
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { $0.request.identifier.hasPrefix(prefix) && !ids.contains($0.request.identifier) }.map { $0.request.identifier })
    }
    private func reconcileReminders() async {
        guard let repository else { await removeObsoleteReminders([]); return }
        let currentItems = await repository.all()
        let desired = requests(currentItems)
        await removeObsoleteReminders(desired)
        let settings = await center.notificationSettings()
        notificationsAvailable = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        guard notificationsAvailable else { return }
        let pending = await center.pendingNotificationRequests()
        let existing = Set(pending.map(\.identifier))
        for request in desired where !existing.contains(request.identifier) {
            guard !Task.isCancelled else { return }
            let validIDs = Set(requests(await repository.all()).map(\.identifier))
            guard validIDs.contains(request.identifier) else { continue }
            do {
                try await center.add(request)
                let after = Set(requests(await repository.all()).map(\.identifier))
                if !after.contains(request.identifier) { center.removePendingNotificationRequests(withIdentifiers: [request.identifier]) }
            } catch { message = "Pin couldn't schedule a reminder. Open notification settings and try again." }
        }
    }
    private func auditForSimulator(_ event: String) async {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--test-appointment-notification") else { return }
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let row: [String: Any] = ["event": event, "pending": pending.map(\.identifier), "delivered": delivered.map { $0.request.identifier }]
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("notification-audit-" + event + ".json"), options: .atomic)
        }
        #endif
    }

    // UIKit's notification response completion must run on the main queue.
    // The async protocol bridge resumed it on a cooperative worker and crashed
    // state restoration when opening a delivered notification in iOS 26.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sourceID"] as? String
        let fingerprint = response.notification.request.content.userInfo["fingerprint"] as? String
        DispatchQueue.main.async {
            if let id, let fingerprint { self.notificationContext = AppointmentNotificationContext(sourceID: id, fingerprint: fingerprint) }
            completionHandler()
        }
    }

}

#if DEBUG && targetEnvironment(simulator)
/// Authored UI lifecycle control, never a semantic model or a phone provider.
/// Real PhotoKit/index/cache/UI owners still prepare and publish every task.
private actor SavedWarmContextRenderControl:DecisionProvider {
    private var tasks:[String]=[]
    func decide(_ task:ChoiceTask)async throws->DecisionReceipt {
        tasks.append(task.state)
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        try JSONEncoder().encode(tasks).write(to:documents.appendingPathComponent("saved-warm-context-control-tasks.json"),options:.atomic)
        let state=try JSONSerialization.jsonObject(with:Data(task.state.utf8)) as? [String:Any]
        let question=state?["question"] as? String
        let operation:String
        switch question {
        case "What restaurant business ideas did I save?":operation="search"
        case "Which of those propose recurring subscriptions?":
            guard (state?["actuallyDisplayedTitles"] as? [String])?.count==2 || task.questions["operation"]==nil,
                  state?["parentBindingSHA256"] is String || task.questions["operation"]==nil else{throw PinDevelopmentError.configuration}
            operation="filter"
        case "Open the first one.":
            guard (state?["actuallyDisplayedTitles"] as? [String])?.count==1,
                  state?["parentBindingSHA256"] is String else{throw PinDevelopmentError.configuration}
            operation="originals"
        default:throw PinDevelopmentError.configuration
        }
        let items=state?["items"] as? [[String:Any]] ?? []
        let matches=items.map{item in
            operation != "filter" || (item["facts"] as? [[String:Any]] ?? []).contains{($0["text"] as? String ?? "").contains("Membership renews monthly")}
        }
        let answers=Dictionary(uniqueKeysWithValues:task.questions.map{key,_ in
            let choice:String
            if key=="operation"{choice=operation}
            else if key=="target"{choice=operation=="originals" ? "row_1":"none"}
            else if key=="basis"{choice="currentSaved"}
            else {
                let parts=key.split(separator:"_")
                let index=parts.count>1 ? Int(parts[1]) : nil
                let relevant=index.map{matches.indices.contains($0) && matches[$0]} ?? false
                choice=key.hasPrefix("match_") ? (relevant ? "relevant":"notRelevant"):(relevant ? "required":"optional")
            }
            return (key,ChoiceAnswer(choice:choice))
        })
        // Makes the spinner observable to XCTest; excluded from latency claims.
        try await Task.sleep(nanoseconds:1_000_000_000)
        return DecisionReceipt(provider:"authored-warm-ui-control",model:"none",requestSHA256:try task.digest(),answers:answers,elapsedSeconds:0)
    }
}
#endif
