import PinMemory
import PinCore
import struct IBrain.SourceReference
import Foundation
import Photos
import CoreLocation
import UIKit
import Vision
import CoreImage
import CryptoKit
import SwiftUI
import BackgroundTasks

@MainActor
final class PhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var memories: [PhotoMemory] = []
    @Published var status = "Your photos stay on this iPhone."
    @Published var authorized = false
    @Published var indexing = false
    @Published var accessReady = false
    @Published var accessFailure:String?
    @Published var error: String?
    @Published var backgroundStatus: String?
    @Published var readingSummary: PhotoReadSummary?
    let store: MemoryStore
    private var work: Task<Void, Never>?
    private var registered = false
    private var phoneTestIDs:Set<String>?
    private var phoneTestPreparing = false
    private var workGeneration = UUID()
    private var sourceSnapshot: [String: String]?
    private var scanCompleted = false
    private var sourceAccessFullyReconciled = false
    var backgroundLease = false
    var progressChanged: ((Int, Int) -> Void)?

    init(store: MemoryStore) { self.store = store; super.init() }
    deinit { work?.cancel(); if registered { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }

    func connect(requestPermission: Bool = false) async {
        accessFailure=nil
        var permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if permission == .notDetermined && requestPermission { permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        if (SavedPlacesQualification.localReaderEnabled || PeoplePlansQualification.enabled) && permission == .authorized {
            holdIsolatedPhotoAccess("Give Pin Limited Photos access to the fictional test photos.", reason: .fullAccess)
            return
        }
        if PinPublicProductScope.requiresLimitedPhotoAccess && permission == .authorized {
            holdIsolatedPhotoAccess(Self.isolatedFullAccessNotice, reason: .fullAccess)
            return
        }
        authorized = permission == .authorized || permission == .limited
        guard authorized else {
            #if DEBUG
            writeFreshSourceProofStatus(.limitedAccessRequired)
            #endif
            workGeneration = UUID(); work?.cancel(); indexing = false
            accessReady = false; sourceSnapshot = nil; scanCompleted = false; sourceAccessFullyReconciled=false; readingSummary=nil
            do {
                _ = try await store.synchronizeAccess([]); memories = []
                if permission == .denied || permission == .restricted {
                    try PinPrivatePayloadWithdrawal.withdrawIfRevoked(documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
                }
            }
            catch {
                self.error = "Pin couldn't finish clearing photo-derived data. Please try again."
                accessFailure = self.error
            }
            status = permission == .notDetermined ? "Choose which photos Pin can look through." : "Photo access is off. You can change it in Settings."
            return
        }
        if PinFreshProductConfiguration.enabled && !PinPublicProductScope.usesExistingPhotoIntake {
            do {phoneTestIDs=try await prepareFreshProductPhotos()}catch{
                workGeneration=UUID();work?.cancel();indexing=false;accessReady=false
                accessFailure="Pin couldn’t verify the sample photos. Your saved readings are kept."
                status=accessFailure!;return
            }
        }
        else if Self.usesPhoneTestScope {
            guard !phoneTestPreparing else{return}
            phoneTestPreparing=true
            do {phoneTestIDs=try await preparePhoneTestPhotos()}
            catch {
                phoneTestPreparing=false;workGeneration=UUID();work?.cancel();indexing=false;accessReady=false;memories=[]
                status="The fictional test photos need preparation. Your other photos are unchanged.";accessFailure=status;return
            }
            phoneTestPreparing=false
        }
        if !registered { PHPhotoLibrary.shared().register(self); registered = true }
        refresh(force: false)
    }

    private static let isolatedFullAccessNotice = "Full Access is on. In Settings, choose Limited Access and select only the two sample photos."

    private enum FreshSourceProofStatus: String {
        case fullAccess
        case limitedAccessRequired
        case tooManyPhotos
        case selectionIncomplete
        case readingIncomplete
        case sourceStateChanged
        case originalUnavailable
        case originalBytesMismatch
    }

    private func holdIsolatedPhotoAccess(_ explanation: String, reason: FreshSourceProofStatus) {
        #if DEBUG
        writeFreshSourceProofStatus(reason)
        #endif
        workGeneration = UUID(); work?.cancel(); indexing = false
        authorized = false; accessReady = false; sourceSnapshot = nil
        scanCompleted = false; sourceAccessFullyReconciled = false
        readingSummary = nil; memories = []
        status = explanation
    }

    private static var usesPhoneTestScope:Bool {
        #if DEBUG
        return Bundle.main.bundleIdentifier=="app.pin.phonetest" && Bundle.main.object(forInfoDictionaryKey:"PinPairedPhoneTest") as? Bool == true
        #else
        return false
        #endif
    }
    /// Developer setup only: exact frozen fictional JPEGs become real PhotoKit
    /// originals. This identity never enumerates or indexes the owner's library.
    /// A persisted reservation prevents a crash/failed import from retrying and
    /// duplicating originals. Forget never deletes a Photos asset or reimports it.
    private func preparePhoneTestPhotos()async throws->Set<String> {
        #if DEBUG
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let bytes=try Data(contentsOf:documents.appendingPathComponent("phone-test-fixtures.json"))
        guard let expected=Bundle.main.object(forInfoDictionaryKey:"PinPhoneTestFixtureManifestSHA256") as? String else{throw PinStoreError.staleImport}
        struct Phase:Decodable{let phase:Int}
        let phase=try JSONDecoder().decode(Phase.self,from:Data(contentsOf:documents.appendingPathComponent("phone-test-phase.json"))).phase
        let stateFile=documents.appendingPathComponent("phone-test-photo-state.json")
        let stateData=FileManager.default.fileExists(atPath:stateFile.path) ? try Data(contentsOf:stateFile):nil
        let plan:PinPhoneFixtureImport.Plan
        do { plan=try PinPhoneFixtureImport.plan(manifestData:bytes,expectedSHA256:expected,phase:phase,stateData:stateData,maximumAssets:PinSealedQualification.isEnabled ? 4:3) }
        catch { throw PinStoreError.staleImport }
        var state=plan.existing
        let pending=plan.pending
        if !pending.isEmpty {
            for asset in pending {
                let data=try Data(contentsOf:documents.appendingPathComponent(asset.file))
                guard data.count<=4_194_304,SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==asset.sha256 else{throw PinStoreError.staleImport}
            }
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            try encoder.encode(plan.reservation).write(to:stateFile,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            let result=PinPhoneImportedIDs()
            try await PHPhotoLibrary.shared().performChanges {
                for asset in pending {
                    let request=PHAssetCreationRequest.forAsset();request.creationDate=asset.photographedAt
                    request.addResource(with:.photo,fileURL:documents.appendingPathComponent(asset.file),options:nil)
                    if let id=request.placeholderForCreatedAsset?.localIdentifier{result.insert(id,for:asset.sha256)}
                }
            }
            do { state=try plan.completed(adding:result.snapshot()) } catch { throw PinStoreError.staleImport }
            try encoder.encode(state).write(to:stateFile,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
        return Set(state.ids.values)
        #else
        throw PinStoreError.staleImport
        #endif
    }

    private func prepareFreshProductPhotos()async throws->Set<String> {
        struct State:Codable {let importing:Bool;let ids:[String:String]}
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let stateFile=docs.appendingPathComponent(PinPublicProductScope.photoStateFileName())
        let encoder=JSONEncoder()
        // Reopening already-imported, signed public fixtures must not require
        // a live model lease. PhotoKit/protected-data reconciliation below
        // still decides accessReady; no cached ID grants access on its own.
        if let signed=PinPublicProductScope.declaredFixtureManifestSHA256,
           FileManager.default.fileExists(atPath:stateFile.path) {
            let raw=try Data(contentsOf:docs.appendingPathComponent(PinPublicProductScope.configurationFileName()))
            let local=try PinLocalFixtureAccess(configurationData:raw,signedManifestSHA256:signed)
            return try local.importedIDs(stateData:Data(contentsOf:stateFile))
        }
        let config=try PinFreshProductConfiguration.load()
        if FileManager.default.fileExists(atPath:stateFile.path){
            let state=try JSONDecoder().decode(State.self,from:Data(contentsOf:stateFile))
            guard !state.importing,Set(state.ids.keys)==Set(config.photos.map(\.sha256)) else{throw PinStoreError.staleImport}
            return Set(state.ids.values)
        }
        for photo in config.photos {
            let bytes=try Data(contentsOf:docs.appendingPathComponent(photo.file))
            guard bytes.count<=10_000_000,SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==photo.sha256 else{throw PinStoreError.staleImport}
        }
        try encoder.encode(State(importing:true,ids:[:])).write(to:stateFile,options:.atomic)
        let result=PinPhoneImportedIDs()
        try await PHPhotoLibrary.shared().performChanges {
            for photo in config.photos {
                let request=PHAssetCreationRequest.forAsset()
                request.addResource(with:.photo,fileURL:docs.appendingPathComponent(photo.file),options:nil)
                if let id=request.placeholderForCreatedAsset?.localIdentifier{result.insert(id,for:photo.sha256)}
            }
        }
        let ids=result.snapshot();guard ids.count==config.photos.count else{throw PinStoreError.staleImport}
        try encoder.encode(State(importing:false,ids:ids)).write(to:stateFile,options:.atomic)
        return Set(ids.values)
    }

    static func fixtureWitnesses(_ memories:[PhotoMemory],session:PinSealedTestSession,requiresListedText:Bool=true)async throws->[PinFixtureSourceWitness] {
        if requiresListedText{try session.validateNativeProfile()}
        else {
            // Local hold only: prove a known fixture ORIGINAL without granting
            // any model route, OCR admission or stale candidate permission.
            try session.validate()
            guard PinSealedQualification.usesReviewedSession,
                  Bundle.main.object(forInfoDictionaryKey:"PinPhoneTestFixtureManifestSHA256")as?String==session.fixtureManifestSHA256 else{throw PinStoreError.staleImport}
        }
        struct Manifest:Decodable{struct Asset:Decodable{let file:String;let sha256:String};let assets:[Asset]}
        struct State:Decodable{let importing:Bool;let ids:[String:String]}
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0],raw=try Data(contentsOf:docs.appendingPathComponent("phone-test-fixtures.json"))
        guard SHA256.hash(data:raw).map({String(format:"%02x",$0)}).joined()==session.fixtureManifestSHA256 else{throw PinStoreError.staleImport}
        let manifest=try JSONDecoder().decode(Manifest.self,from:raw),state=try JSONDecoder().decode(State.self,from:Data(contentsOf:docs.appendingPathComponent("phone-test-photo-state.json")))
        guard !state.importing,memories.count<=4 else{throw PinStoreError.staleImport}
        var witnesses:[PinFixtureSourceWitness]=[]
        for memory in memories {
            guard let assetSpec=manifest.assets.first(where:{state.ids[$0.sha256]==memory.id}),session.fixtureImageSHA256[assetSpec.file]==assetSpec.sha256,
                  let asset=PHAsset.fetchAssets(withLocalIdentifiers:[memory.id],options:nil).firstObject,
                  currentFingerprint(for:memory.id)==memory.fingerprint,asset.creationDate==memory.photographedAt,
                  asset.mediaSubtypes.contains(.photoScreenshot)==memory.isScreenshot else{throw PinStoreError.staleImport}
            let resources=PHAssetResource.assetResources(for:asset)
            guard let resource=resources.first(where:{$0.type == .photo})else{throw PinStoreError.staleImport}
            let collector=PinFixtureResourceBytes(),options=PHAssetResourceRequestOptions();options.isNetworkAccessAllowed=false
            let manager=PHAssetResourceManager.default()
            let bytes:Data?=await withTaskCancellationHandler(operation:{
                await withCheckedContinuation { continuation in
                    collector.install(continuation)
                    let id=manager.requestData(for:resource,options:options,dataReceivedHandler:{collector.append($0)},completionHandler:{error in collector.finish(error==nil)})
                    collector.started(id)
                    DispatchQueue.global().asyncAfter(deadline:.now()+5){collector.finish(false)}
                }
            },onCancel:{collector.finish(false)})
            guard let bytes,SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==assetSpec.sha256,currentFingerprint(for:memory.id)==memory.fingerprint else{throw PinStoreError.staleImport}
            let witness=PinFixtureSourceWitness(slot:assetSpec.file,originalSHA256:assetSpec.sha256,memory:memory);if requiresListedText{try session.validate(witness,memory:memory)};witnesses.append(witness)
        }
        return witnesses
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in await self?.connect() }
    }

    func downloadMissingPhotos() {
        BackgroundAudit.record("cloud-download-action",count:readingSummary?.needsDownload ?? 0)
        guard authorized, UIApplication.shared.applicationState == .active else {
            BackgroundAudit.record("cloud-download-not-active",count:0)
            status = "Open Pin to download missing photos from iCloud."
            return
        }
        status = "Checking which photos can download from iCloud…"
        refresh(force: true, downloadCloudMissing: true)
    }

    func refresh(force: Bool = true, downloadCloudMissing: Bool = false, retryFailedReads: Bool = false) {
        // PhotoKit may notify after expiration. Only an active OS grant may
        // start/resume the reader while the app is actually in background.
        guard UIApplication.shared.applicationState != .background || backgroundLease else {
            pauseForBackground(); return
        }
        if SavedPlacesQualification.localReaderEnabled || PeoplePlansQualification.enabled,
           PHPhotoLibrary.authorizationStatus(for: .readWrite) != .limited {
            holdIsolatedPhotoAccess("Give Pin Limited Photos access to the fictional test photos.", reason: .limitedAccessRequired)
            return
        }
        if PinPublicProductScope.requiresLimitedPhotoAccess {
            let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard permission == .limited else {
                if permission == .authorized {
                    holdIsolatedPhotoAccess(Self.isolatedFullAccessNotice, reason: .fullAccess)
                } else {
                    holdIsolatedPhotoAccess("In Settings, give Pin Fresh Test Limited Access to the two sample photos.", reason: .limitedAccessRequired)
                }
                return
            }
        }
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetch:PHFetchResult<PHAsset>
        if Self.usesPhoneTestScope || (PinFreshProductConfiguration.enabled && !PinPublicProductScope.usesExistingPhotoIntake) {
            guard let phoneTestIDs else{accessReady=false;indexing=false;return}
            fetch=PHAsset.fetchAssets(withLocalIdentifiers:Array(phoneTestIDs),options:options)
        }else{fetch=PHAsset.fetchAssets(with: .image, options: options)}
        if PinPublicProductScope.requiresLimitedPhotoAccess && fetch.count > 2 {
            holdIsolatedPhotoAccess("Pin Fresh Test can see \(fetch.count) photos. Edit the selection so only the two sample photos are shared.", reason: .tooManyPhotos)
            return
        }
        var assets: [PHAsset] = []; fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        let fingerprints = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, Self.fingerprint($0)) })
        let confirmingAccess=UIApplication.shared.isProtectedDataAvailable
        // Empty/partial locked responses cannot confirm source withdrawal.
        // A cold OS grant can still read sources PhotoKit currently exposes.
        if assets.isEmpty && !confirmingAccess {
            pauseForBackground()
            BackgroundAudit.record("locked-catalogue-deferred",count:memories.count)
            status = "Waiting for photos to become available. Your saved index is kept."
            return
        }
        // An unlock always performs a full reconciliation after a partial pass.
        if PinPhotoAccessReconciliation.canReuseScan(force:force,sameSources:sourceSnapshot==fingerprints,indexing:indexing,scanCompleted:scanCompleted,fullyReconciled:sourceAccessFullyReconciled,protectedDataAvailable:confirmingAccess,accessReady:accessReady) {
            #if DEBUG
            scheduleFreshSourceProof()
            #endif
            return
        }
        work?.cancel()
        let generation = UUID(); workGeneration = generation
        sourceSnapshot = fingerprints; scanCompleted = false; sourceAccessFullyReconciled=confirmingAccess
        accessReady = false; indexing = true
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.workGeneration == generation {
                    self.indexing = false
                    #if DEBUG
                    self.scheduleFreshSourceProof()
                    #endif
                }
            }
            do {
                try Task.checkCancellation()
                let permit = try await self.store.synchronizeSources(fingerprints,confirmingAccess:confirmingAccess,restartingImport:true)
                let current = await self.store.all()
                let retryIssues: [PhotoReadIssue] = (retryFailedReads ? [.photoUnavailable, .analysisFailed] : []) + (downloadCloudMissing ? [.needsDownload] : [])
                let pendingIDs = await self.store.pendingSourceIDs(fingerprints, retrying: retryIssues)
                let cloudDownloadIDs = downloadCloudMissing ? await self.store.sourcesNeedingDownload(fingerprints) : Set<String>()
                #if DEBUG && targetEnvironment(simulator)
                // Explicit no-model UI control for questions accepted while
                // source access is pending. Never present in a phone build.
                if Bundle.main.bundleIdentifier=="app.pin.freshproduct",
                   ProcessInfo.processInfo.arguments.contains("--test-question-access-wait") {
                    try await Task.sleep(for:.seconds(30))
                }
                #endif
                try Task.checkCancellation()
                guard self.workGeneration == generation else { return }
                self.memories = current; self.accessReady = confirmingAccess
                self.readingSummary=await self.store.readSummary(fingerprints)
                BackgroundAudit.record("scan-start", count:current.count)
                BackgroundAudit.record(confirmingAccess ? "source-access-confirmed-v1" : "source-access-available-v1",count:current.count,total:fingerprints.count)
                #if DEBUG && targetEnvironment(simulator)
                // Reproduce the distinct access-ready / reader-running interval
                // without a model or a change to physical-device scheduling.
                if Bundle.main.bundleIdentifier=="app.pin.freshproduct",
                   ProcessInfo.processInfo.arguments.contains("--test-question-reader-wait") {
                    PinFreshProductAudit.record(question:"",stage:"reader-control-access-ready")
                    try await Task.sleep(for:.seconds(30))
                    try Task.checkCancellation()
                    guard self.workGeneration == generation else{return}
                    PinFreshProductAudit.record(question:"",stage:"reader-control-released")
                }
                #endif
                let sourceAudit=await self.store.sourceReconciliationAudit()
                BackgroundAudit.record("source-retained-at-scan",count:sourceAudit.retained)
                BackgroundAudit.record("source-versions-changed",count:sourceAudit.changed)
                BackgroundAudit.record("source-metadata-deferred",count:sourceAudit.metadataDeferred)
                if !cloudDownloadIDs.isEmpty { BackgroundAudit.record("cloud-download-requested",count:cloudDownloadIDs.count) }
                else if downloadCloudMissing { BackgroundAudit.record("cloud-download-no-eligible-source",count:0) }
                for field in sourceAudit.changedFields.keys.sorted() {
                    BackgroundAudit.record("source-changed-" + field,count:sourceAudit.changedFields[field]!)
                }
                let pending = assets.filter { pendingIDs.contains($0.localIdentifier) }
                #if DEBUG
                NSLog("Pin indexing plan: %ld pending, %ld cached", pending.count, current.count)
                #endif
                for (index, asset) in pending.enumerated() {
                    try Task.checkCancellation()
                    guard self.authorized else { return }
                    self.progressChanged?(index, pending.count)
                    self.status = cloudDownloadIDs.contains(asset.localIdentifier) ? "Downloading from iCloud and reading your photo…" : "Reading your photos…"
                    #if DEBUG && targetEnvironment(simulator)
                    // Isolated native failure/recovery lab; never enabled on a
                    // phone, in Release, or in the working Pin bundle.
                    if Bundle.main.bundleIdentifier == "app.pin.coveragecandidate",
                       ProcessInfo.processInfo.arguments.contains("--test-reading-issues"),
                       let fixtureIndex = assets.prefix(4).firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) {
                        if fixtureIndex == 3 {
                            try await self.store.upsert(PhotoMemory(id:asset.localIdentifier,fingerprint:fingerprints[asset.localIdentifier]!,imageRecognitionAvailable:false),permit:permit)
                            self.memories=await self.store.all()
                        } else {
                            let issues:[PhotoReadIssue] = [.needsDownload,.photoUnavailable,.analysisFailed]
                            try await self.store.recordReadIssue(id:asset.localIdentifier,fingerprint:fingerprints[asset.localIdentifier]!,issue:issues[fixtureIndex],permit:permit)
                        }
                        self.readingSummary=await self.store.readSummary(fingerprints)
                        continue
                    }
                    #endif
                    let local=await Self.displayImage(for:asset.localIdentifier,size:CGSize(width:1200,height:1200),download:cloudDownloadIDs.contains(asset.localIdentifier))
                    guard case .ready(let image)=local, let cg=image.cgImage else {
                        try Task.checkCancellation()
                        guard self.workGeneration == generation else { return }
                        let issue:PhotoReadIssue
                        if case .cloud=local { issue = .needsDownload }
                        else if cloudDownloadIDs.contains(asset.localIdentifier) { issue = .needsDownload }
                        else { issue = .photoUnavailable }
                        try await self.store.recordReadIssue(id:asset.localIdentifier,fingerprint:fingerprints[asset.localIdentifier]!,issue:issue,permit:permit)
                        self.readingSummary=await self.store.readSummary(fingerprints)
                        continue
                    }
                    let cpuOnly = self.backgroundLease || UIApplication.shared.applicationState != .active
                    let observation = await Task.detached(priority: .utility) {
                        Self.observe(cg, cpuOnly: cpuOnly)
                    }.value
                    try Task.checkCancellation()
                    guard self.workGeneration == generation else { return }
                    guard Self.currentFingerprint(for:asset.localIdentifier) == fingerprints[asset.localIdentifier] else { throw PinStoreError.staleImport }
                    let coordinate = asset.location.map { PhotoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
                    if observation.2 {
                        try await self.store.recordReadIssue(id:asset.localIdentifier,fingerprint:fingerprints[asset.localIdentifier]!,issue:.analysisFailed,permit:permit)
                        self.readingSummary=await self.store.readSummary(fingerprints)
                        continue
                    }
                    let memory = PhotoMemory(id: asset.localIdentifier, fingerprint: fingerprints[asset.localIdentifier]!, photographedAt: asset.creationDate,
                        coordinate: coordinate, text: observation.0, labels: observation.1, imageRecognitionAvailable: observation.3,textEvidence:observation.4,isScreenshot:asset.mediaSubtypes.contains(.photoScreenshot))
                    try await self.store.upsert(memory, permit: permit)
                    let updated = await self.store.all()
                    try Task.checkCancellation()
                    guard self.workGeneration == generation else { return }
                    self.memories = updated
                    #if DEBUG && targetEnvironment(simulator)
                    if index == 0, Bundle.main.bundleIdentifier == "app.pin.intakecandidate",
                       ProcessInfo.processInfo.arguments.contains("--test-fresh-reader-first-checkpoint") {
                        self.readingSummary=await self.store.readSummary(fingerprints)
                        self.status="Local test checkpoint: one pending photo completed"
                        // Deterministic observation barrier only. The real Home/
                        // background owner must cancel this task before another read.
                        try await Task.sleep(for:.seconds(60))
                        try Task.checkCancellation()
                        guard self.workGeneration == generation else{return}
                    }
                    #endif
                    if updated.count % 10 == 0 { self.readingSummary=await self.store.readSummary(fingerprints) }
                    if updated.count % 10 == 0 { BackgroundAudit.record("checkpoint",count:updated.count) }
                }
                try Task.checkCancellation()
                guard self.workGeneration == generation else { return }
                self.readingSummary=await self.store.readSummary(fingerprints)
                self.scanCompleted = true
                BackgroundAudit.record("scan-complete",count:self.memories.count)
                self.progressChanged?(pending.count, pending.count)
                if downloadCloudMissing {
                    let remaining = self.readingSummary?.needsDownload ?? 0
                    let recovered = cloudDownloadIDs.intersection(Set(self.memories.map(\.id))).count
                    if cloudDownloadIDs.isEmpty {
                        self.status = "No current iCloud-only photo was available to download. Check Photos, then try again."
                    } else if remaining > 0 {
                        BackgroundAudit.record("cloud-download-still-waiting",count:remaining)
                        self.status = "Still waiting for \(remaining) iCloud photo\(remaining == 1 ? "" : "s"). Open Photos to download the original, then try again."
                    } else if recovered == cloudDownloadIDs.count {
                        BackgroundAudit.record("cloud-download-read",count:recovered)
                        self.status = self.readingSummary?.completionStatus ?? "Reading pass finished."
                    } else {
                        BackgroundAudit.record("cloud-download-source-changed",count:cloudDownloadIDs.count - recovered)
                        self.status = "Photo access changed while checking. Your saved readings are kept. Refresh to continue."
                    }
                } else {
                    self.status = self.readingSummary?.completionStatus ?? "Reading pass finished."
                }
            } catch is CancellationError { }
            catch PinStoreError.staleImport {
                guard self.workGeneration == generation else { return }
                self.status = "Photo access changed. Refresh to continue."
                #if DEBUG
                self.writeFreshSourceProofStatus(.sourceStateChanged)
                #endif
            } catch {
                guard self.workGeneration == generation else { return }
                BackgroundAudit.record("scan-error",count:self.memories.count)
                self.error = "Pin couldn't finish reading your photos. Your saved index is kept."
                self.status = "Tap Refresh to try again."
                #if DEBUG
                self.writeFreshSourceProofStatus(.readingIncomplete)
                #endif
            }
        }
    }

    func waitForCurrentScan() async -> Bool {
        while let task=work {
            let generation=workGeneration
            await task.value
            if generation == workGeneration { return scanCompleted }
        }
        return scanCompleted
    }

    func pauseForBackground() {
        guard indexing else { return }
        BackgroundAudit.record("scan-paused",count:memories.count)
        workGeneration = UUID(); work?.cancel()
        indexing = false; scanCompleted = false
        status = "Reading paused. Your progress is saved."
        let generation=workGeneration
        let snapshot=sourceSnapshot ?? [:]
        Task {
            let summary=await store.readSummary(snapshot)
            guard workGeneration == generation else { return }
            readingSummary=summary
        }
        // Completed observations remain durable. Resume plans only the remainder.
    }

    func forget(_ memory: PhotoMemory) async -> Bool {
        guard authorized, accessReady, Self.currentFingerprint(for: memory.id) == memory.fingerprint else {
            error = "This photo changed or is no longer accessible. Reopen it before forgetting it."
            return false
        }
        do {
            try await store.forget(RecallHit(memory: memory, score: 0))
            workGeneration = UUID(); work?.cancel(); indexing = false
            memories = await store.all()
            readingSummary = await store.readSummary(sourceSnapshot ?? [:])
            status = "Forgotten by Pin. The original is still in Photos."
            return true
        } catch {
            self.error = "This photo couldn't be forgotten. Reopen it and try again."
            return false
        }
    }

    nonisolated static func currentFingerprints(for ids:[String]) -> [String:String] {
        let fetch=PHAsset.fetchAssets(withLocalIdentifiers:ids,options:nil)
        var result:[String:String]=[:]
        fetch.enumerateObjects { asset,_,_ in result[asset.localIdentifier]=fingerprint(asset) }
        return result
    }

    nonisolated static func currentFingerprint(for id: String) -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        return fingerprint(asset)
    }

    nonisolated private static func fingerprint(_ asset: PHAsset) -> String {
        let coordinate = asset.location.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" } ?? "none"
        return "vision-v4|\(asset.localIdentifier)|\(asset.modificationDate?.timeIntervalSince1970 ?? 0)|\(asset.creationDate?.timeIntervalSince1970 ?? 0)|\(asset.pixelWidth)x\(asset.pixelHeight)|\(coordinate)"
    }

    nonisolated static func image(for id: String, size: CGSize, download: Bool = false) async -> UIImage? {
        guard case .ready(let image) = await displayImage(for:id,size:size,download:download) else { return nil }
        return image
    }

    /// Visible image loading reports a reason; background indexing stays local-only.
    /// Cancellation releases the Swift waiter and the underlying PhotoKit work.
    nonisolated static func displayImage(for id:String, size:CGSize, download:Bool) async -> PhotoDisplay {
        guard !Task.isCancelled,
              let asset=PHAsset.fetchAssets(withLocalIdentifiers:[id],options:nil).firstObject else { return .unavailable }
        let lifetime = PhotoRequestLifetime()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard lifetime.begin(onCancel: { continuation.resume(returning:.unavailable) }) else { return }
                let options=PHImageRequestOptions();options.deliveryMode = .highQualityFormat
                options.resizeMode = .exact;options.isNetworkAccessAllowed=download
                let manager=PHImageManager.default()
                let request=manager.requestImage(for:asset,targetSize:size,contentMode:.aspectFit,options:options) { image,info in
                    if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                        lifetime.complete { continuation.resume(returning:.unavailable) }
                        return
                    }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    let result:PhotoDisplay
                    if let image { result = .ready(image) }
                    else { result = (info?[PHImageResultIsInCloudKey] as? Bool) == true ? .cloud : .unavailable }
                    lifetime.complete { continuation.resume(returning:result) }
                }
                lifetime.setRequestCancellation {
                    if request != PHInvalidImageRequestID { manager.cancelImageRequest(request) }
                }
            }
        } onCancel: { lifetime.cancel() }
    }

    #if DEBUG
    private static var freshSourceProofNonce: UUID? {
        guard PinPublicProductScope.requiresLimitedPhotoAccess else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--fresh-source-proof"),
              arguments.indices.contains(flag + 1) else { return nil }
        return UUID(uuidString: arguments[flag + 1])
    }

    private func scheduleFreshSourceProof() {
        guard scanCompleted, !indexing, UIApplication.shared.applicationState == .active,
              let nonce = Self.freshSourceProofNonce else { return }
        let generation = workGeneration
        Task { await writeFreshSourceProof(nonce: nonce, generation: generation) }
    }

    /// Pairing setup only. Export identities for the exact two declared originals,
    /// using the same current PhotoKit bytes the question path validates.
    private func writeFreshSourceProof(nonce: UUID, generation: UUID) async {
        guard workGeneration == generation, let manifest = PinPublicProductScope.declaredFixtureManifestSHA256 else { return }
        guard let snapshot = sourceSnapshot, snapshot.count == 2 else {
            writeFreshSourceProofStatus(.selectionIncomplete)
            return
        }
        guard memories.count == 2 else {
            writeFreshSourceProofStatus(.readingIncomplete)
            return
        }
        let sources = memories.map(EvidenceSource.init)
        guard Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.fingerprint) }) == snapshot else {
            writeFreshSourceProofStatus(.sourceStateChanged)
            return
        }
        var hashes: [String: String] = [:]
        do {
            for source in sources {
                let bytes = try await immutableCurrentImageData(for: source)
                hashes[source.id] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
        } catch {
            guard workGeneration == generation else { return }
            writeFreshSourceProofStatus(.originalUnavailable)
            return
        }
        guard workGeneration == generation, !indexing, accessReady,
              UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
              sourceSnapshot == snapshot, memories.map(EvidenceSource.init) == sources,
              Self.currentFingerprints(for: Array(snapshot.keys)) == snapshot else { return }
        guard Set(hashes.values).count == 2,
              PinPublicProductScope.fixtureManifestIdentity(Array(hashes.values)) == manifest else {
            writeFreshSourceProofStatus(.originalBytesMismatch)
            return
        }
        writeFreshSourceProofFile([
            "schemaVersion": 1,
            "sourceBindings": sources.map { source -> [String: Any] in
                ["source": ["id": source.id, "revision": source.revision,
                            "fingerprint": source.fingerprint],
                 "originalSHA256": hashes[source.id]!]
            },
            "nonce": nonce.uuidString, "fixtureManifestSHA256": manifest, "sourceSHA256ByID": hashes
        ], filename: nonce.uuidString + ".json")
    }

    // Keep failure observations separate from the hash-bound success proof.
    private func writeFreshSourceProofStatus(_ status: FreshSourceProofStatus) {
        guard let nonce = Self.freshSourceProofNonce,
              UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else { return }
        writeFreshSourceProofFile(["nonce": nonce.uuidString, "status": status.rawValue],
                                  filename: nonce.uuidString + ".status.json")
    }

    private func writeFreshSourceProofFile(_ contents: [String: Any], filename: String) {
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let directory = documents.appendingPathComponent("fresh-source-proof", isDirectory: true)
            let data = try JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys])
            try PinPrivatePayloadWithdrawal.withWriteAccess {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(filename),
                               options: [.atomic, .completeFileProtection])
            }
        } catch {
            BackgroundAudit.record("fresh-source-proof-unavailable", count: 0)
        }
    }
    #endif

    /// Resolve an already admitted place source selection immediately before
    /// handing it to the original-photo view. The same current readings and
    /// PhotoKit fingerprints are required across the store read.
    func currentSavedPlaceOriginals(_ references: [SourceReference]) async throws -> [PhotoMemory] {
        guard canOpenSavedPlaceOriginals else { throw PinStoreError.staleResult }
        let generation = workGeneration
        let current = await store.all()
        try Task.checkCancellation()
        let resolved = try PinSavedPlaceSourceBinding.resolve(references, in: current)
        try validateCurrentSavedPhotos(resolved, generation: generation)
        return resolved
    }

    func currentSavedPlaceReadings() async throws -> [PhotoMemory] {
        guard canOpenSavedPlaceOriginals,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            throw PinStoreError.staleResult
        }
        let generation = workGeneration
        let readings = await store.all()
        try Task.checkCancellation()
        try validateCurrentSavedPhotos(readings, generation: generation)
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            throw PinStoreError.staleResult
        }
        return readings
    }

    private func validateCurrentSavedPhotos(_ readings: [PhotoMemory], generation: UUID) throws {
        guard generation == workGeneration, canOpenSavedPlaceOriginals else { throw PinStoreError.staleResult }
        let fingerprints = readings.isEmpty ? [:] : Self.currentFingerprints(for: readings.map(\.id))
        guard generation == workGeneration, canOpenSavedPlaceOriginals else { throw PinStoreError.staleResult }
        try PinSavedPlaceSourceBinding.validateCurrentReadings(readings, visible: memories, fingerprints: fingerprints)
    }

    private var canOpenSavedPlaceOriginals: Bool {
        authorized && accessReady && !indexing && sourceAccessFullyReconciled &&
        (!(SavedPlacesQualification.localReaderEnabled || PeoplePlansQualification.enabled) ||
         PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited) &&
        UIApplication.shared.applicationState == .active &&
        UIApplication.shared.isProtectedDataAvailable
    }

    /// Current PhotoKit asset data, never a display UIImage re-encoding. Local
    /// only; network/iCloud transfer remains a separately authorized journey.
    func immutableCurrentImageData(for source:EvidenceSource)async throws->Data {
        func validate()throws {
            guard !Task.isCancelled,authorized,accessReady,!indexing,
                  !PinPublicProductScope.requiresLimitedPhotoAccess || PHPhotoLibrary.authorizationStatus(for:.readWrite) == .limited,
                  UIApplication.shared.applicationState == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  sourceAccessFullyReconciled,
                  memories.contains(where:{EvidenceSource($0)==source}),
                  Self.currentFingerprint(for:source.id)==source.fingerprint else{throw PinStoreError.staleImport}
        }
        try validate();let generation=workGeneration
        guard let asset=PHAsset.fetchAssets(withLocalIdentifiers:[source.id],options:nil).firstObject else{throw PinStoreError.staleImport}
        let lifetime=PhotoRequestLifetime()
        let bytes:Data?=await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard lifetime.begin(onCancel:{continuation.resume(returning:nil)})else{return}
                let options=PHImageRequestOptions();options.version = .current
                options.deliveryMode = .highQualityFormat;options.isNetworkAccessAllowed=false
                let manager=PHImageManager.default()
                DispatchQueue.global().asyncAfter(deadline:.now()+15){lifetime.cancel()}
                let request=manager.requestImageDataAndOrientation(for:asset,options:options){data,_,orientation,info in
                    guard (info?[PHImageCancelledKey] as? Bool) != true,info?[PHImageErrorKey]==nil,
                          let data,!data.isEmpty,data.count<=10_000_000,
                          let image=CGImageSourceCreateWithData(data as CFData,nil)else{
                        lifetime.complete{continuation.resume(returning:nil)};return
                    }
                    let properties=CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any]
                    let embedded=(properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
                    // Never guess orientation or rewrite bytes to hide a mismatch.
                    guard embedded==orientation.rawValue else{lifetime.complete{continuation.resume(returning:nil)};return}
                    lifetime.complete{continuation.resume(returning:data)}
                }
                lifetime.setRequestCancellation{if request != PHInvalidImageRequestID{manager.cancelImageRequest(request)}}
            }
        } onCancel:{lifetime.cancel()}
        try validate();guard generation==workGeneration,let bytes else{throw PinStoreError.staleImport}
        return bytes
    }
    func prepareTextReread(_ source:EvidenceSource)async throws->PhotoTextRereadTicket {
        guard authorized,accessReady,!indexing,sourceAccessFullyReconciled,
              UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable,
              let sourceSnapshot,Self.currentFingerprint(for:source.id)==source.fingerprint else{throw PinStoreError.staleImport}
        let permit=try await store.synchronizeSources(sourceSnapshot,confirmingAccess:true)
        return try await store.prepareTextReread(source,permit:permit)
    }
    func commitPreparedSourceReread(_ prepared:PreparedPhotoReread)async throws {
        guard authorized,accessReady,!indexing,sourceAccessFullyReconciled,
              UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable,
              Self.currentFingerprint(for:prepared.before.id)==prepared.before.fingerprint else{throw PinStoreError.staleImport}
        _=try await store.commitPreparedReread(prepared)
        memories=await store.all()
    }

    func commitTextReread(_ lines:[CardLine],ticket:PhotoTextRereadTicket)async throws {
        guard authorized,accessReady,!indexing,sourceAccessFullyReconciled,
              UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable,
              Self.currentFingerprint(for:ticket.source.id)==ticket.source.fingerprint else{throw PinStoreError.staleImport}
        _=try await store.commitTextReread(lines,ticket:ticket)
        memories=await store.all()
    }

    func commitVisualReread(_ reading:PhotoVisualReading,ticket:PhotoTextRereadTicket)async throws {
        guard authorized,accessReady,!indexing,sourceAccessFullyReconciled,
              UIApplication.shared.applicationState == .active,UIApplication.shared.isProtectedDataAvailable,
              Self.currentFingerprint(for:ticket.source.id)==ticket.source.fingerprint else{throw PinStoreError.staleImport}
        _=try await store.commitVisualReread(reading,ticket:ticket)
        memories=await store.all()
    }

    /// Decode only a current ticket source when a foreground answer needs it.
    /// The check-in payload is never logged, stored, or loaded as a URL.
    nonisolated static func localCheckInCode(for memory: PhotoMemory) async -> CheckInCodeEvidence? {
        guard !Task.isCancelled, currentFingerprint(for: memory.id) == memory.fingerprint else { return nil }
        guard case .ready(let image) = await displayImage(for: memory.id,
                  size: CGSize(width: 1200, height: 1200), download: false),
              let cgImage = image.cgImage else { return nil }
        let source = EvidenceSource(memory)
        let code = await Task.detached(priority: .utility) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            _ = try? VNImageRequestHandler(cgImage: cgImage).perform([request])
            let vision=(request.results ?? []).map(\.payloadStringValue)
            let context=CIContext(options:[.useSoftwareRenderer:true])
            let detector=CIDetector(ofType:CIDetectorTypeQRCode,context:context,
                options:[CIDetectorAccuracy:CIDetectorAccuracyHigh])
            let coreImage=(detector?.features(in:CIImage(cgImage:cgImage)) ?? [])
                .map { ($0 as? CIQRCodeFeature)?.messageString }
            guard let payload=CheckInCodeEvidence.uniquePayload(vision:vision,coreImage:coreImage)
            else { return Optional<CheckInCodeEvidence>.none }
            return CheckInCodeEvidence.luma(payload, source: source)
        }.value
        guard !Task.isCancelled, currentFingerprint(for: memory.id) == memory.fingerprint else { return nil }
        return code
    }

    nonisolated private static func observe(_ image: CGImage, cpuOnly: Bool = false) -> ([String], [VisualLabel], Bool, Bool, [CardLine]) {
        let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate; text.usesLanguageCorrection = false
        text.recognitionLanguages=["en-US","ja-JP"];text.automaticallyDetectsLanguage=true
        let labels = VNClassifyImageRequest()
        // Keep independent reader failures separate. A classifier failure must
        // never discard successfully observed text or be cached as success.
        #if targetEnvironment(simulator)
        text.usesCPUOnly = true
        #endif
        if cpuOnly { text.usesCPUOnly = true; labels.usesCPUOnly = true }
        var textOK = false; var labelsOK = false
        do { try VNImageRequestHandler(cgImage: image).perform([text]); textOK = true }
        catch { NSLog("Pin OCR stage unavailable: %@", String(describing: error)) }
        do { try VNImageRequestHandler(cgImage: image).perform([labels]); labelsOK = true }
        catch { NSLog("Pin image classification stage unavailable: %@", String(describing: error)) }
        let lines=(text.results ?? []).compactMap { item -> CardLine? in
            guard let candidate=item.topCandidates(1).first,candidate.confidence >= 0.5 else { return nil }
            let box=item.boundingBox
            return CardLine(candidate.string,confidence:candidate.confidence,region:EvidenceRegion(x:box.minX,y:box.minY,width:box.width,height:box.height))
        }
        return (lines.map(\.text), (labels.results ?? []).filter { $0.confidence >= 0.1 }.prefix(12).map {
            VisualLabel($0.identifier, confidence: Double($0.confidence))
        }, !textOK && !labelsOK, labelsOK, lines)
    }

}

enum PhotoDisplay { case loading, ready(UIImage), cloud, unavailable }

struct LibraryPhoto: View {
    let id: String
    var full = false
    var pixelSize: CGFloat = 1000
    @State private var display: PhotoDisplay = .loading
    var body: some View {
        Group {
            switch display {
            case .ready(let image): Image(uiImage:image).resizable().aspectRatio(contentMode:full ? .fit : .fill)
            case .loading: ZStack { Color.pinSurface;ProgressView().tint(Color.pinRose).accessibilityLabel("Loading photo") }
            case .cloud: ZStack { Color.pinSurface; VStack(spacing:6) { ProgressView().tint(Color.pinRose);Text("Loading from iCloud").font(.caption2).foregroundStyle(Color.pinMuted) } }
            case .unavailable: placeholder("Photo unavailable",icon:"photo")
            }
        }
        .task(id:"\(id)|\(full)|\(pixelSize)") { await load() }
    }
    private func placeholder(_ title:String,icon:String) -> some View {
        ZStack {
            Color.pinSurface
            VStack(spacing:6) {
                Image(systemName:icon)
                Text(title).font(.caption2).multilineTextAlignment(.center)
                if full { Button("Try again") { Task { await load() } }.font(.caption).tint(Color.pinRose) }
            }.foregroundStyle(Color.pinMuted).padding(4)
        }
    }
    @MainActor private func load() async {
        display = .loading
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-photo-unavailable") { display = .unavailable; return }
        #endif
        let size:CGFloat=full ? 3000 : pixelSize
        var loaded=await PhotoLibrary.displayImage(for:id,size:CGSize(width:size,height:size),download:full)
        guard !Task.isCancelled else { return }
        if case .cloud = loaded {
            display = .cloud
            // Only this displayed source is fetched. Indexing uses image(download:false).
            loaded=await PhotoLibrary.displayImage(for:id,size:CGSize(width:size,height:size),download:true)
        }
        guard !Task.isCancelled else { return }
        display=PhotoLibrary.currentFingerprint(for:id) == nil ? .unavailable : loaded
    }
}


// A single PhotoLibrary/store owner serves foreground and OS-granted background
// time. Neither mode creates a second writer or relaxes file protection.
@MainActor extension MemoryStore {
    func mapLibrary() -> PhotoLibrary { PhotoLibrary(store:self) }
}

@MainActor final class PhotoIndexBackground {
    private let library: PhotoLibrary?
    private let identifier = (Bundle.main.bundleIdentifier ?? "app.pin.local") + ".photo-index"
    private var active: BGTask?
    private var lastSubmission = Date.distantPast
    private var generation = UUID()
    private var continuedRequested = false
    private var continuedRegistered = false
    private var processingRegistered = false
    private var runner: Task<Void, Never>?
    init(library: PhotoLibrary?) {
        self.library = library
        processingRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier:identifier,using:nil) { [weak self] task in
            Task { @MainActor in self?.run(task) }
        }
        if #available(iOS 26.0, *) {
            continuedRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier:identifier + ".continued",using:nil) { [weak self] task in
                Task { @MainActor in self?.run(task) }
            }
        }
    }
    func continueCurrentScan() {
        guard let library else { return }
        BackgroundAudit.record("continued-action",count:library.memories.count)
        library.backgroundStatus="Requesting background reading…"
        guard library.indexing else {
            library.backgroundStatus="There is no active reading pass to continue."
            BackgroundAudit.record("continued-no-active-pass",count:library.memories.count);return
        }
        guard #available(iOS 26.0, *) else { library.backgroundStatus="Continued background reading needs iOS 26. Scheduled reading is requested when you leave Pin."; return }
        guard continuedRegistered else {
            library.backgroundStatus="Background reading isn't available in this build. Foreground reading continues."
            BackgroundAudit.record("continued-registration-unavailable",count:library.memories.count);return
        }
        guard active == nil else {
            library.backgroundStatus="Background reading is already running."
            BackgroundAudit.record("continued-already-running",count:library.memories.count);return
        }
        guard !continuedRequested else {
            library.backgroundStatus="Waiting for iOS to start background reading."
            BackgroundAudit.record("continued-already-requested",count:library.memories.count);return
        }
        guard UIApplication.shared.applicationState == .active else {
            library.backgroundStatus="Return to Pin to request background reading. Your progress is saved."
            BackgroundAudit.record("continued-action-inactive",count:library.memories.count);return
        }
        guard Date().timeIntervalSince(lastSubmission) > 5 else {
            library.backgroundStatus="Please wait a moment before trying background reading again."
            BackgroundAudit.record("continued-action-too-soon",count:library.memories.count);return
        }
        let request=BGContinuedProcessingTaskRequest(identifier:identifier + ".continued",title:"Reading your photos",subtitle:"Progress is saved as Pin reads.")
        // If iOS is busy, retain the person's request until it can grant time.
        // The scan still pauses without an OS grant and resumes from its saved
        // checkpoint only when the scheduler invokes run(_:).
        request.strategy = .queue
        lastSubmission=Date()
        do {
            try BGTaskScheduler.shared.submit(request);continuedRequested=true
            library.backgroundStatus="Background reading requested. Pin saves progress while waiting for iOS to start it."
            BackgroundAudit.record("continued-request-accepted",count:library.memories.count)
        } catch {
            library.backgroundStatus="iOS couldn't start background reading now. Your progress is saved; you can try again."
            BackgroundAudit.record("continued-request-rejected",count:library.memories.count)
            BackgroundAudit.record("continued-rejection-code-\((error as NSError).code)",count:library.memories.count)
            NSLog("Pin background continuation unavailable: %@",String(describing:error))
        }
    }
    func didEnterBackground() {
        BackgroundAudit.record(active == nil ? "background-without-grant" : "background-with-grant",count:library?.memories.count ?? 0)
        scheduleLater()
        if active == nil { library?.pauseForBackground() }
    }
    private func scheduleLater() {
        guard processingRegistered else { return }
        guard PHPhotoLibrary.authorizationStatus(for:.readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for:.readWrite) == .limited else { return }
        let request = BGProcessingTaskRequest(identifier:identifier)
        request.earliestBeginDate=Date(timeIntervalSinceNow:15 * 60)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do { try BGTaskScheduler.shared.submit(request) }
        catch { /* Retry next foreground/background cycle. */ }
    }
    private func run(_ task: BGTask) {
        guard active == nil, let library else {
            task.setTaskCompleted(success:false); return
        }
        active = task; generation = UUID(); let runID=generation
        library.backgroundStatus = "Reading with background time provided by iOS."
        NSLog("Pin background grant started")
        BackgroundAudit.record("grant-start",count:library.memories.count)
        BackgroundAudit.record("grant-build-delivery-20261025-r34",count:library.memories.count)
        if #available(iOS 26.0, *), task is BGContinuedProcessingTask {
            BackgroundAudit.record("grant-continued",count:library.memories.count)
        } else { BackgroundAudit.record("grant-processing",count:library.memories.count) }
        library.backgroundLease = true
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.finish(runID, success:false, pause:true) }
        }
        if #available(iOS 26.0, *), let continued=task as? BGContinuedProcessingTask {
            continued.progress.totalUnitCount=1
            library.progressChanged = { read,total in
                continued.progress.totalUnitCount=Int64(max(total,1))
                continued.progress.completedUnitCount=Int64(read)
                continued.updateTitle("Reading your photos",subtitle:"\(read) of \(total) remaining photos checked")
            }
        }
        runner = Task {
            await library.connect()
            let success=await library.waitForCurrentScan()
            guard !Task.isCancelled else { return }
            finish(runID,success:success,pause:false)
        }
    }
    private func finish(_ runID: UUID, success: Bool, pause: Bool) {
        guard runID == generation, let task=active else { return }
        generation=UUID();active=nil;runner?.cancel();runner=nil
        if pause {
            BackgroundAudit.record("grant-expired",count:library?.memories.count ?? 0)
            library?.pauseForBackground()
        }
        library?.backgroundLease=false;library?.progressChanged=nil
        continuedRequested=false
        library?.backgroundStatus = success ? "Reading pass finished." : "Background reading paused. Your progress is saved."
        NSLog("Pin background grant finished: %@",success ? "complete" : "paused")
        BackgroundAudit.record(success ? "grant-complete" : "grant-paused",count:library?.memories.count ?? 0)
        if !success || library?.accessReady == false { scheduleLater() }
        task.setTaskCompleted(success:success)
    }
}


// Only the separately identified diagnostic app emits aggregate proof. It never
// exports photo identifiers, images, OCR, locations or the personal index.
@MainActor enum BackgroundAudit {
    static func record(_ event:String,count:Int,total:Int?=nil) {
        #if DEBUG
        guard let bundleID=Bundle.main.bundleIdentifier,
              ["app.pin.backgroundcandidate", "app.pin.backgroundcandidate2"].contains(bundleID) else { return }
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("background-index-audit.json")
        var rows=((try? Data(contentsOf:file)).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [[String:Any]]) ?? []
        var row:[String:Any] = ["event":event,"read":count,"time":Date().timeIntervalSince1970,"background":UIApplication.shared.applicationState == .background,"applicationState":UIApplication.shared.applicationState.rawValue,"completeProtectionAvailable":UIApplication.shared.isProtectedDataAvailable]
        if let total { row["total"]=total }
        rows.append(row)
        if let data=try? JSONSerialization.data(withJSONObject:Array(rows.suffix(200)),options:[.sortedKeys]) {
            try? data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
        #endif
    }
    static func storageProbe() async {
        #if DEBUG
        guard let bundleID=Bundle.main.bundleIdentifier,
              ["app.pin.backgroundcandidate", "app.pin.backgroundcandidate2"].contains(bundleID) else { return }
        record("diagnostic-coverage-4",count:0)
        record("diagnostic-delivery-20261025-r34",count:0)
        // This fixture deliberately sets complete protection to test migration.
        // It cannot be read while locked; defer instead of reporting a false
        // migration error for the separate, already-readable production index.
        guard UIApplication.shared.isProtectedDataAvailable else {
            record("storage-probe-deferred-locked",count:0);return
        }
        do {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let file=directory.appendingPathComponent("old-index.json")
            let old=try MemoryStore(file:file)
            let permit=try await old.synchronizeAccess(["fictional-shoe","fictional-forgotten"])
            try await old.upsert(PhotoMemory(id:"fictional-shoe",fingerprint:"vision-v4|fixture",text:["CREAM"],labels:[VisualLabel("sneakers",confidence:0.9)]),permit:permit)
            try await old.forget("fictional-forgotten")
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:file.path)
            let before=try Data(contentsOf:file)
            let migrated=try MemoryStore(file:file)
            let unchanged=try Data(contentsOf:file) == before
            let protection=try FileManager.default.attributesOfItem(atPath:file.path)[.protectionKey] as? FileProtectionType
            _=try await migrated.synchronizeAccess(["fictional-shoe","fictional-forgotten"])
            let hits=await migrated.find("shoes")
            let forgotten=await migrated.isForgotten("fictional-forgotten")
            record(unchanged && hits.count == 1 && forgotten ? "storage-content-pass" : "storage-content-fail",count:0)
            record(protection == .completeUntilFirstUserAuthentication ? "storage-protection-pass" : "storage-protection-unverified",count:0)
            record(unchanged && protection == .completeUntilFirstUserAuthentication && hits.count == 1 && forgotten ? "storage-migration-pass" : "storage-migration-unverified",count:0)
            try? FileManager.default.removeItem(at:directory)
        } catch { record("storage-migration-error",count:0) }
        #endif
    }
}

private final class PinPhoneImportedIDs:@unchecked Sendable {
    private let lock=NSLock()
    private var ids:[String:String]=[:]
    func insert(_ id:String,for hash:String){lock.lock();defer{lock.unlock()};ids[hash]=id}
    func snapshot()->[String:String]{lock.lock();defer{lock.unlock()};return ids}
}

private final class PinFixtureResourceBytes:@unchecked Sendable {
    private let lock=NSLock();private var bytes=Data();private var valid=true,finished=false
    private var requestID:PHAssetResourceDataRequestID?
    private var continuation:CheckedContinuation<Data?,Never>?
    func install(_ value:CheckedContinuation<Data?,Never>){lock.lock();let done=finished;if !done{continuation=value};lock.unlock();if done{value.resume(returning:nil)}}
    func started(_ id:PHAssetResourceDataRequestID){lock.lock();let done=finished;if !done{requestID=id};lock.unlock();if done{PHAssetResourceManager.default().cancelDataRequest(id)}}
    func append(_ data:Data){lock.lock();defer{lock.unlock()};guard !finished,valid,bytes.count+data.count<=4_194_304 else{valid=false;bytes.removeAll();return};bytes.append(data)}
    func finish(_ success:Bool){
        lock.lock();guard !finished else{lock.unlock();return};finished=true
        let result=success && valid ? bytes:nil,id=requestID,c=continuation;continuation=nil;bytes.removeAll();lock.unlock()
        if !success,let id{PHAssetResourceManager.default().cancelDataRequest(id)};c?.resume(returning:result)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// PhotoKit-only laboratory mutation of one predeclared authored original.
/// Never available on a phone, Release, or any other bundle; no model/store API.
@MainActor private struct PinFreshLocalSourceChangeCommand:Decodable {
    let schema:String,sourceID:String,expectedFingerprint:String,sourceOriginalSHA256:String,originalFile:String
    let creationEpoch:Double,latitude:Double,longitude:Double,duplicateCreationEpoch:Double
    let maximumMutations:Int,modelCalls:Int,phoneActions:Int
}
@MainActor struct PinFreshLocalSourceChangeControl:View {
    static var enabled:Bool {
        Bundle.main.bundleIdentifier=="app.pin.intakecandidate" && ProcessInfo.processInfo.arguments.contains("--test-fresh-local-source-change")
    }
    @State private var status="Preparing predeclared local source changes"
    var body:some View {Text(status).accessibilityIdentifier("localSourceChangeStatus").task{await run()}}
    private func run()async {
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let output=docs.appendingPathComponent("fresh-local-source-change")
        do {
            guard Self.enabled,PHPhotoLibrary.authorizationStatus(for:.readWrite) == .authorized else{throw PinStoreError.staleImport}
            let command=try JSONDecoder().decode(PinFreshLocalSourceChangeCommand.self,from:Data(contentsOf:docs.appendingPathComponent("fresh-local-source-change-command.json")))
            guard command.schema=="pin-local-source-change-control-v1",command.originalFile=="photos/g01.jpg",command.maximumMutations==2,command.modelCalls==0,command.phoneActions==0,
                  PhotoLibrary.currentFingerprint(for:command.sourceID)==command.expectedFingerprint,
                  let asset=PHAsset.fetchAssets(withLocalIdentifiers:[command.sourceID],options:nil).firstObject else{throw PinStoreError.staleImport}
            let original=docs.appendingPathComponent(command.originalFile)
            func digest(_ bytes:Data)->String{SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
            guard digest(try Data(contentsOf:original))==command.sourceOriginalSHA256 else{throw PinStoreError.staleImport}
            // A persisted reservation prevents repeating a partly completed edit/import.
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
            try Data("reserved; no model calls".utf8).write(to:output.appendingPathComponent("ATTEMPT.txt"),options:.atomic)
            guard let resource=PHAssetResource.assetResources(for:asset).first(where:{$0.type == .photo || $0.type == .fullSizePhoto})else{throw PinStoreError.staleImport}
            let exported=output.appendingPathComponent("before-original.jpg"),options=PHAssetResourceRequestOptions();options.isNetworkAccessAllowed=false
            try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>)in
                PHAssetResourceManager.default().writeData(for:resource,toFile:exported,options:options){error in
                    if let error{continuation.resume(throwing:error)}else{continuation.resume()}
                }
            }
            guard digest(try Data(contentsOf:exported))==command.sourceOriginalSHA256,
                  PhotoLibrary.currentFingerprint(for:command.sourceID)==command.expectedFingerprint else{throw PinStoreError.staleImport}
            var duplicateID:String?
            try await PHPhotoLibrary.shared().performChanges {
                let edit=PHAssetChangeRequest(for:asset)
                edit.creationDate=Date(timeIntervalSince1970:command.creationEpoch)
                edit.location=CLLocation(latitude:command.latitude,longitude:command.longitude)
                let duplicate=PHAssetCreationRequest.forAsset()
                duplicate.addResource(with:.photo,fileURL:original,options:nil)
                duplicate.creationDate=Date(timeIntervalSince1970:command.duplicateCreationEpoch)
                duplicateID=duplicate.placeholderForCreatedAsset?.localIdentifier
            }
            guard let duplicateID,duplicateID != command.sourceID,
                  let changed=PhotoLibrary.currentFingerprint(for:command.sourceID),changed != command.expectedFingerprint,
                  let copied=PhotoLibrary.currentFingerprint(for:duplicateID)else{throw PinStoreError.staleImport}
            let result:[String:Any]=["status":"PASS_PHOTOKIT_MUTATIONS_ONLY","sourceID":command.sourceID,"beforeFingerprint":command.expectedFingerprint,"afterFingerprint":changed,"duplicateID":duplicateID,"duplicateFingerprint":copied,"originalSHA256":command.sourceOriginalSHA256,"modelCalls":0,"phoneActions":0]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("RESULT.json"),options:.atomic)
            status="Local source changes completed"
        }catch {
            status="Local source changes held: \(error)"
            try? JSONSerialization.data(withJSONObject:["status":"FAIL","error":String(describing:error),"modelCalls":0]).write(to:output.appendingPathComponent("FAILURE.json"),options:.atomic)
        }
    }
}
#endif
