import Foundation
import IBrain
import IBrainSemantics
import IBrainRetrieval

/// Finite public-sample pairing, isolated from ordinary and Release routes.
public struct PinSavedContentReplayPair:Codable,Sendable {
    public let endpoint:URL
    public let certificateSHA256:String
    public let token:String
    public let sessionID:UUID
    public let privacyScopeSHA256:String
    public let originals:[SavedContentReplayOriginal]
    public let issuedAt:Date
    public let expiresAt:Date
    public var phoneTest:PinPhoneTestBinding? = nil
    /// Local source validation does not authorize inference or network requests.
    /// A settled answer's originals and corrections remain usable after its
    /// finite inference lease ends; all source/profile bindings still apply.
    public func validateLocalSourceBinding(at now:Date=Date())throws {
        try validateLocalSourceBinding(at:now,bundle:Bundle.main.bundleIdentifier,
            optIn:Bundle.main.object(forInfoDictionaryKey:"PinSavedContentPhoneTest") as? Bool == true,
            sdk:Bundle.main.object(forInfoDictionaryKey:"PinSavedContentSDKIdentitySHA256") as? String,
            manifest:PinPublicProductScope.declaredFixtureManifestSHA256)
    }
    // Explicit environment inputs let offline integration controls exercise the
    // complete phone contract; public entry points always use the installed bundle.
    func validateLocalSourceBinding(at now:Date,bundle:String?,optIn:Bool,sdk:String?,manifest:String?)throws {
        #if DEBUG
        if let phoneTest {
            try PinSavedContentPhoneProfile.validateLocalSourceBinding(endpoint, binding:phoneTest, originals:originals, now:now,
                bundle:bundle,optIn:optIn,sdk:sdk,manifest:manifest)
            guard abs(phoneTest.issuedAt-issuedAt.timeIntervalSince1970)<0.001,
                  abs(phoneTest.expiresAt-expiresAt.timeIntervalSince1970)<0.001 else{throw PinDevelopmentError.configuration}
        } else {
            #if targetEnvironment(simulator) || os(macOS)
            try PinDevelopmentDestination.validate(endpoint,path:"/v1/saved-content-choice",phoneTest:nil)
            #else
            throw PinDevelopmentError.disabled
            #endif
        }
        func sha(_ value:String)->Bool{value.count==64 && value.allSatisfy{"0123456789abcdef".contains($0)}}
        guard sha(certificateSHA256),sha(privacyScopeSHA256),(32...128).contains(token.count),
              !originals.isEmpty,originals.count<=12,Set(originals.map{$0.source.id}).count==originals.count,
              originals.allSatisfy({sha($0.originalSHA256)}),issuedAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,issuedAt<=now,
              (0...1800).contains(expiresAt.timeIntervalSince(issuedAt)) else{throw PinDevelopmentError.configuration}
        #else
        throw PinDevelopmentError.disabled
        #endif
    }
    /// Load saved local authority without opening an inference provider.
    public static func loadLocal(from url:URL,at now:Date=Date())throws -> (pair:Self,bytes:Data) {
        let handle=try FileHandle(forReadingFrom:url)
        defer {try? handle.close()}
        let bytes=try handle.read(upToCount:131073) ?? Data()
        guard bytes.count<=131072 else{throw PinDevelopmentError.configuration}
        let pair=try JSONDecoder().decode(Self.self,from:bytes)
        try pair.validateLocalSourceBinding(at:now)
        return (pair,bytes)
    }
    /// Every provider entry point must use this live authorization check.
    public func validate(at now:Date=Date())throws {
        try validateLocalSourceBinding(at:now)
        guard now<expiresAt else{throw PinDevelopmentError.testEnded}
    }
    func validate(at now:Date,bundle:String?,optIn:Bool,sdk:String?,manifest:String?)throws {
        try validateLocalSourceBinding(at:now,bundle:bundle,optIn:optIn,sdk:sdk,manifest:manifest)
        guard now<expiresAt else{throw PinDevelopmentError.testEnded}
    }
}

/// Written only by the native source/publication owner. The host receives its
/// path out of band, not through HTTP. Hashes in HTTP never grant authority.
public struct PinSavedContentNativeWitness:Codable,Sendable {
    public let sessionID:UUID
    public let requestID:UUID
    public let currentSnapshotSHA256:String
    public let displayedHistorySHA256:String
    public let currentQuerySHA256:String
    public let expectedTaskSHA256:String
}

public final class PinSavedContentReplayProvider:PinSavedContentReplayProviding,@unchecked Sendable {
    public var replaySessionID:UUID{pair.sessionID}
    private let pair:PinSavedContentReplayPair
    private let witnessURL:URL
    private let lock=NSLock()
    private var active:UUID?
    private var generation=0
    public init(pair:PinSavedContentReplayPair,witnessURL:URL)throws {
        try pair.validate();self.pair=pair;self.witnessURL=witnessURL
        // Never carry a process-local publication/intent grant across launch.
        try? FileManager.default.removeItem(at:witnessURL)
    }
    public func decide(_ task:ChoiceTask)async throws->DecisionReceipt{throw PinDevelopmentError.disabled}
    public func bound(snapshot:SavedContentReplaySnapshot,query:SavedContentReplayQuery,
                      history:[SavedContentReplayPublication])throws->any DecisionProvider {
        try pair.validate();try Task.checkCancellation()
        guard Set(snapshot.sources.map(\.reference)).isSubset(of:Set(pair.originals.map(\.source))),history.count<8 else{throw PinDevelopmentError.sourceNotAllowed}
        let stamp=lock.withLock{generation+=1;active=query.requestID;return generation}
        return PinSavedContentBoundProvider(owner:self,snapshot:snapshot,query:query,history:history,generation:stamp)
    }
    public func invalidate(requestID:UUID?=nil) {
        lock.withLock {
            guard requestID==nil || requestID==active else{return}
            generation+=1;active=nil;try? FileManager.default.removeItem(at:witnessURL)
        }
    }
    func authorize(snapshot:SavedContentReplaySnapshot,query:SavedContentReplayQuery,history:[SavedContentReplayPublication],receipts:[DecisionReceipt],task:ChoiceTask,generation stamp:Int)throws->(SavedContentReplayRequest,Data) {
        try Task.checkCancellation();try pair.validate()
        let originals=pair.originals.filter{snapshot.sourceIDs.contains($0.source.id)}
        let request=SavedContentReplayRequest(sessionID:pair.sessionID,privacyScopeSHA256:pair.privacyScopeSHA256,originals:originals,snapshot:snapshot,history:history,query:query,receipts:receipts,expectedTask:task)
        let witness=PinSavedContentNativeWitness(sessionID:pair.sessionID,requestID:query.requestID,currentSnapshotSHA256:try snapshot.digest(),displayedHistorySHA256:try SavedContentReplay.historyDigest(history),currentQuerySHA256:try query.digest(),expectedTaskSHA256:try task.digest())
        let trusted=(history.flatMap(\.receipts)+receipts).map{SavedContentReplayTrustedReceipt(sessionID:pair.sessionID,receipt:$0)}
        let policy=SavedContentReplayPolicy(sessionID:pair.sessionID,scope:snapshot.scope,privacyScopeSHA256:pair.privacyScopeSHA256,currentSnapshotSHA256:witness.currentSnapshotSHA256,displayedHistorySHA256:witness.displayedHistorySHA256,currentQuerySHA256:witness.currentQuerySHA256,originalSHA256BySourceID:Dictionary(uniqueKeysWithValues:pair.originals.map{($0.source.id,$0.originalSHA256)}),receiptProvider:"pin-native-subscription",receiptModel:"gpt-6.1-sol",trustedReceipts:trusted,issuedAt:pair.issuedAt,expiresAt:pair.expiresAt)
        try SavedContentReplay.validateAuthorization(request,policy:policy)
        let bytes=try SavedContentReplay.encoded(witness)
        try lock.withLock {
            guard active==query.requestID,generation==stamp else{throw PinEvidenceError.staleRecord}
            try bytes.write(to:witnessURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:witnessURL.path)
        }
        PinQuestionTiming.markSaved(query.requestID,.witnessWritten)
        return (request,bytes)
    }
    func check(_ witness:Data,queryID:UUID,generation stamp:Int)throws {
        try Task.checkCancellation();try pair.validate()
        try lock.withLock {
            guard active==queryID,generation==stamp,try Data(contentsOf:witnessURL)==witness else{throw PinEvidenceError.staleRecord}
        }
    }
    fileprivate func dispatch(_ envelope:SavedContentReplayRequest,witness:Data,generation stamp:Int)async throws->DecisionReceipt {
        try check(witness,queryID:envelope.query.requestID,generation:stamp)
        let body=try SavedContentReplay.encoded(envelope)
        guard body.count<=8_388_608 else{throw PinDevelopmentError.oversized}
        var request=URLRequest(url:pair.endpoint);request.httpMethod="POST";request.timeoutInterval=125;request.httpBody=body
        request.setValue("Bearer "+pair.token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let pin=PinPinnedTLS(pair.certificateSHA256)
        let session=URLSession(configuration:PinDevelopmentTransport.configuration(phoneTest:pair.phoneTest != nil,maximumDuration:125,waitForConnectivity:false),delegate:pin,delegateQueue:nil)
        defer{pin.endConnectionBudget();session.invalidateAndCancel()}
        PinQuestionTiming.markSaved(envelope.query.requestID,.connecting)
        pin.beginConnectionBudget(3,session:session)
        let (bytes,response)=try await session.bytes(for:request,delegate:pin)
        PinQuestionTiming.markSaved(envelope.query.requestID,.responseReceived)
        guard let http=response as? HTTPURLResponse,http.statusCode==200,http.url==pair.endpoint,http.mimeType=="application/json"else{throw PinDevelopmentError.transport}
        var data=Data()
        for try await byte in bytes {try Task.checkCancellation();guard data.count<131072 else{throw PinDevelopmentError.oversized};data.append(byte)}
        try check(witness,queryID:envelope.query.requestID,generation:stamp)
        let receipt=try JSONDecoder().decode(DecisionReceipt.self,from:data)
        guard receipt.provider=="pin-native-subscription",receipt.model=="gpt-6.1-sol",receipt.elapsedSeconds.isFinite,receipt.elapsedSeconds>=0,
              receipt.answers.values.allSatisfy({$0.confidence==nil && $0.probabilities==nil})else{throw PinDevelopmentError.invalidReceipt}
        try receipt.validate(for:envelope.expectedTask)
        PinQuestionTiming.markSaved(envelope.query.requestID,.receiptValidated)
        return receipt
    }
}
private actor PinSavedContentBoundProvider:DecisionProvider {
    let owner:PinSavedContentReplayProvider
    let snapshot:SavedContentReplaySnapshot
    let query:SavedContentReplayQuery
    let history:[SavedContentReplayPublication]
    let generation:Int
    var receipts:[DecisionReceipt]=[]
    var inFlight=false
    init(owner:PinSavedContentReplayProvider,snapshot:SavedContentReplaySnapshot,query:SavedContentReplayQuery,history:[SavedContentReplayPublication],generation:Int){self.owner=owner;self.snapshot=snapshot;self.query=query;self.history=history;self.generation=generation}
    func decide(_ task:ChoiceTask)async throws->DecisionReceipt {
        guard !inFlight else{throw PinDevelopmentError.configuration};inFlight=true;defer{inFlight=false}
        let (request,witness)=try owner.authorize(snapshot:snapshot,query:query,history:history,receipts:receipts,task:task,generation:generation)
        let receipt=try await owner.dispatch(request,witness:witness,generation:generation)
        receipts.append(receipt);return receipt
    }
}


public enum PinSavedContentPhoneProfile {
    public static let bundleID="app.pin.savedscreenshotstest"
    public static let sdkIdentity="16e82ce416f503c3319c7aa4d56c487d7e75d9813b61691e1dcf64cff7b3d946"
    public static var enabled:Bool {
        enabled(bundle:Bundle.main.bundleIdentifier, optIn:Bundle.main.object(forInfoDictionaryKey:"PinSavedContentPhoneTest") as? Bool == true,
                sdk:Bundle.main.object(forInfoDictionaryKey:"PinSavedContentSDKIdentitySHA256") as? String,
                manifest:PinPublicProductScope.declaredFixtureManifestSHA256)
    }
    static func enabled(bundle:String?,optIn:Bool,sdk:String?,manifest:String?)->Bool {
        #if DEBUG
        return bundle==bundleID && optIn && sdk==sdkIdentity && manifest?.count==64 && manifest!.allSatisfy{"0123456789abcdef".contains($0)}
        #else
        return false
        #endif
    }
    static func validate(_ endpoint:URL,binding:PinPhoneTestBinding,originals:[SavedContentReplayOriginal],now:Date,
                         bundle:String?=Bundle.main.bundleIdentifier,optIn:Bool=Bundle.main.object(forInfoDictionaryKey:"PinSavedContentPhoneTest") as? Bool == true,
                         sdk:String?=Bundle.main.object(forInfoDictionaryKey:"PinSavedContentSDKIdentitySHA256") as? String,
                         manifest:String?=PinPublicProductScope.declaredFixtureManifestSHA256)throws {
        try validateLocalSourceBinding(endpoint,binding:binding,originals:originals,now:now,
            bundle:bundle,optIn:optIn,sdk:sdk,manifest:manifest)
        guard now.timeIntervalSince1970<binding.expiresAt else{throw PinDevelopmentError.testEnded}
    }
    static func validateLocalSourceBinding(_ endpoint:URL,binding:PinPhoneTestBinding,originals:[SavedContentReplayOriginal],now:Date,
                         bundle:String?=Bundle.main.bundleIdentifier,optIn:Bool=Bundle.main.object(forInfoDictionaryKey:"PinSavedContentPhoneTest") as? Bool == true,
                         sdk:String?=Bundle.main.object(forInfoDictionaryKey:"PinSavedContentSDKIdentitySHA256") as? String,
                         manifest:String?=PinPublicProductScope.declaredFixtureManifestSHA256)throws {
        #if DEBUG
        let t=now.timeIntervalSince1970
        guard enabled(bundle:bundle,optIn:optIn,sdk:sdk,manifest:manifest),binding.bundleID==bundle,
              binding.purpose=="fictional-saved-content-v1",binding.issuedAt.isFinite,binding.expiresAt.isFinite,
              binding.issuedAt<=t,binding.expiresAt>binding.issuedAt,binding.expiresAt-binding.issuedAt<=1800,
              endpoint.scheme=="https",let host=endpoint.host,PinDevelopmentDestination.isPrivateIPv4(host),
              let port=endpoint.port,(1...65535).contains(port),endpoint.path=="/v1/saved-content-choice",
              endpoint.user==nil,endpoint.password==nil,endpoint.query==nil,endpoint.fragment==nil,
              originals.count==2,Set(originals.map(\.originalSHA256)).count==2,
              PinPublicProductScope.fixtureManifestIdentity(originals.map(\.originalSHA256))==manifest else{throw PinDevelopmentError.configuration}
        #else
        throw PinDevelopmentError.disabled
        #endif
    }
}
