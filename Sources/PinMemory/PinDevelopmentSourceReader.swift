import Foundation
import CryptoKit
import Security
import PinCore
import IBrain
import IBrainSemantics

public enum PinDevelopmentError:Error {case disabled,configuration,sourceNotAllowed,transport,oversized,invalidReceipt,testEnded}
/// Only a paired loopback development service. This config is absent from the
/// app bundle and carries no OpenAI credential. Ordinary and Release paths never load it.
public struct PinDevelopmentPair:Codable,Sendable {
    public let endpoint:URL
    public let certificateSHA256:String
    public let token:String
    public let allowedTextSHA256:Set<String>
    public var phoneTest:PinPhoneTestBinding? = nil
    public var sealedSession:PinSealedTestSession? = nil
    public func validate()throws {
        try PinDevelopmentDestination.validate(endpoint,path:"/v1/source-choice",phoneTest:phoneTest)
        guard
              certificateSHA256.count==64,certificateSHA256.allSatisfy({$0.isHexDigit}),
              token.count>=32,token.count<=128,!allowedTextSHA256.isEmpty,allowedTextSHA256.count<=16 else{throw PinDevelopmentError.configuration}
        if let sealedSession{try sealedSession.validate();guard let phoneTest,phoneTest.issuedAt==sealedSession.issuedAt,phoneTest.expiresAt==sealedSession.expiresAt else{throw PinDevelopmentError.configuration}}
    }
}
final class PinPinnedTLS:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    let pin:String
    private let connectionLock=NSLock()
    private var connectionTimer:DispatchSourceTimer?
    init(_ pin:String){self.pin=pin}
    // The connection/upload deadline ends once the request body is sent.
    // Model response time retains its separate existing resource budget.
    func beginConnectionBudget(_ seconds:TimeInterval,session:URLSession) {
        let timer=DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.utility))
        timer.schedule(deadline:.now()+seconds)
        timer.setEventHandler{[weak self,weak session]in
            guard let self,self.endConnectionBudget()else{return}
            session?.invalidateAndCancel()
        }
        connectionLock.lock();connectionTimer=timer;timer.resume();connectionLock.unlock()
    }
    @discardableResult func endConnectionBudget()->Bool {
        connectionLock.lock();defer{connectionLock.unlock()}
        guard let timer=connectionTimer else{return false}
        connectionTimer=nil;timer.cancel();return true
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didSendBodyData bytesSent:Int64,totalBytesSent:Int64,totalBytesExpectedToSend:Int64) {
        if totalBytesExpectedToSend>0,totalBytesSent>=totalBytesExpectedToSend {endConnectionBudget()}
    }
    deinit {endConnectionBudget()}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
    func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void){handle(challenge,completionHandler)}
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void){handle(challenge,completionHandler)}
    private func handle(_ challenge:URLAuthenticationChallenge,_ completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void){
        guard challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust,
              let trust=challenge.protectionSpace.serverTrust,let chain=SecTrustCopyCertificateChain(trust) as? [SecCertificate],let certificate=chain.first,
              ChoiceTask.hash(SecCertificateCopyData(certificate) as Data)==pin else{completionHandler(.cancelAuthenticationChallenge,nil);return}
        completionHandler(.useCredential,URLCredential(trust:trust))
    }
}
public struct PinDevelopmentDecisionProvider:DecisionProvider {
    let pair:PinDevelopmentPair
    public init(pair:PinDevelopmentPair)throws{try pair.validate();self.pair=pair}
    public func decide(_ task:ChoiceTask)async throws->DecisionReceipt {
        #if DEBUG
        try pair.validate()
        #if os(iOS) && !targetEnvironment(simulator)
        guard pair.phoneTest != nil else{throw PinDevelopmentError.disabled}
        #endif
        try Task.checkCancellation()
        let submittedWall=Date()
        let state=try JSONSerialization.jsonObject(with:Data(task.state.utf8)) as? [String:Any]
        let groups:[[[String:Any]]]
        if task.version==VisualObservationInterpreter.contractVersionV4,let lines=state?["observations"] as? [[String:Any]] {groups=[lines]}
        else if [ComponentEvidenceBundleInterpreter.contractVersion,ComponentEvidenceBundleInterpreter.contractVersionV3].contains(task.version),let sources=state?["sources"] as? [[String:Any]],(2...3).contains(sources.count) {
            groups=try sources.map{guard let lines=$0["lines"] as? [[String:Any]] else{throw PinDevelopmentError.sourceNotAllowed};return lines}
        }else{throw PinDevelopmentError.sourceNotAllowed}
        for lines in groups {
            guard lines.allSatisfy({$0["text"] is String}) else{throw PinDevelopmentError.sourceNotAllowed}
            let digest=try PinDevelopmentSourceReader.textDigest(lines.compactMap{$0["text"] as? String})
            guard pair.allowedTextSHA256.contains(digest) else{throw PinDevelopmentError.sourceNotAllowed}
        }
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        var request=URLRequest(url:pair.endpoint);request.httpMethod="POST";request.timeoutInterval=125
        request.setValue("Bearer "+pair.token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try e.encode(task)
        guard request.httpBody!.count<=131072 else{throw PinDevelopmentError.oversized}
        let config=PinDevelopmentTransport.configuration(phoneTest:pair.phoneTest != nil,maximumDuration:125)
        let tls=PinPinnedTLS(pair.certificateSHA256)
        let session=URLSession(configuration:config,delegate:tls,delegateQueue:nil)
        defer{session.invalidateAndCancel()}
        let (bytes,response)=try await session.bytes(for:request,delegate:tls)
        guard let http=response as? HTTPURLResponse,http.statusCode==200,http.url==pair.endpoint,
              http.mimeType=="application/json" else{throw PinDevelopmentError.transport}
        var data=Data()
        for try await byte in bytes {try Task.checkCancellation();guard data.count<131072 else{throw PinDevelopmentError.oversized};data.append(byte)}
        guard (0...125).contains(Date().timeIntervalSince(submittedWall)) else{throw PinDevelopmentError.transport}
        try pair.validate() // An expired phone lease cannot publish a late response.
        let receipt=try JSONDecoder().decode(DecisionReceipt.self,from:data)
        guard receipt.provider=="pin-native-subscription",receipt.model=="gpt-6.1-sol",receipt.elapsedSeconds.isFinite,
              receipt.elapsedSeconds>=0,receipt.answers.values.allSatisfy({$0.confidence==nil && $0.probabilities==nil}) else{throw PinDevelopmentError.invalidReceipt}
        try receipt.validate(for:task);return receipt
        #else
        throw PinDevelopmentError.disabled
        #endif
    }
}
/// Local Vision observations remain the proof. The model selects their semantic
/// roles; it cannot invent OCR, choose record IDs or write native memory.
public struct PinDevelopmentSourceReader:Sendable {
    public let provider:any DecisionProvider
    public init(provider:any DecisionProvider){self.provider=provider}
    public static func textDigest(_ texts:[String])throws->String {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return ChoiceTask.hash(try e.encode(texts))
    }
    public static func request(_ memory:PhotoMemory)throws->ObservationRequest {
        let scope=MemoryScope(ownerID:"local-photo-owner",namespace:"pin-appointments-v1")
        let snapshot=try PinEvidenceSnapshot(memories:[memory],records:[],scope:scope)
        guard let source=snapshot.authority.sources.first else{throw PinDevelopmentError.sourceNotAllowed}
        let lines=try (memory.textEvidence ?? []).enumerated().map{offset,line in
            ObservedLine(id:try PinOCRObservationID.make(line,offset:offset),text:line.text,confidence:Double(line.confidence),
                region:line.region.map{ObservationRegion(x:$0.x,y:$0.y,width:$0.width,height:$0.height)})
        }
        return ObservationRequest(taskID:"pin-source-"+memory.id+"-"+String(memory.revision),source:source,lines:lines,declaredVisualClues:source.observations.filter{$0.kind == .visualLabel}.map(\.value),documentPolicy:.documentContentV4,temporalPolicy:.anchoredSpansV5)
    }
    public func read(_ memory:PhotoMemory)async throws->AppointmentCandidate {
        try await VisualObservationInterpreter(provider:provider,detailPolicy:.componentsV1).interpret(Self.request(memory))
    }
    /// Exact reference is retrieval only. A separate two-source semantic
    /// decision and native identity/revision ticket are required for replacement.
    public static func matchingRecords(_ incoming:AppointmentCandidate,records:[AppointmentItem],memories:[PhotoMemory])throws->[AppointmentItem] {
        guard let reference=incoming.bookingReferenceEvidence else{return []}
        guard reference.source==incoming.source,
              let source=memories.first(where:{$0.id==incoming.source.id}),
              let line=try Self.request(source).lines.first(where:{$0.id==reference.observationID}),line.text==reference.quote else{throw PinEvidenceError.invalidSupport}
        return records.filter{row in row.canonicalRecordID != nil && row.allSources.contains{binding in
            memories.contains{memory in AppointmentSource(memory)==binding && memory.id != incoming.source.id && (memory.textEvidence ?? []).contains{$0.text==reference.quote}}
        }}
    }
    /// Full observed reference lines cannot establish that differently labelled
    /// references are distinct. Without a linked bundle, the same or unknown
    /// issuer remains pending rather than silently creating a second booking.
    /// This deliberately also holds a new independent booking from that issuer.
    public static func unlinkedAdmissionAllowed(provider:String?,records:[AppointmentItem])->Bool {
        let canonical=records.filter{$0.canonicalRecordID != nil}
        guard !canonical.isEmpty else{return true}
        func key(_ value:String?)->String? {
            guard let value else{return nil}
            let result=value.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            return result.isEmpty ? nil:result
        }
        guard let incoming=key(provider) else{return false}
        return canonical.allSatisfy{guard let old=key($0.observation.provider)else{return false};return old != incoming}
    }
    public static func bundleRequest(_ memories:[PhotoMemory])throws->EvidenceBundleRequest {
        guard (2...3).contains(memories.count)else{throw PinEvidenceError.invalidSupport}
        let reads=try memories.map(Self.request)
        return EvidenceBundleRequest(taskID:"pin-source-bundle-"+reads.map{$0.source.reference.id+"-"+String($0.source.reference.revision)}.joined(separator:"|"),documents:reads.map{BundleDocument(source:$0.source,lines:$0.lines)})
    }
    public func bundle(_ memories:[PhotoMemory],rolePolicy:BundleComponentRolePolicy = .legacyV2)async throws->AppointmentBundleCandidate {
        try await ComponentEvidenceBundleInterpreter(provider:provider,rolePolicy:rolePolicy).interpret(Self.bundleRequest(memories))
    }
    public static func bundleDraft(_ candidate:AppointmentBundleCandidate,ticket:CanonicalWriteTicket,memories:[PhotoMemory],primarySourceID:String,rolePolicy:BundleComponentRolePolicy = .legacyV2,valuePolicy:LabelledFieldValuePolicy = .legacyWholeLines)throws->CanonicalAppointmentDraft {
        let request=try Self.bundleRequest(memories),expected=try ComponentEvidenceBundleInterpreter.task(for:request,rolePolicy:rolePolicy)
        try candidate.receipt.validate(for:expected)
        guard candidate.relation == .sameBooking,let appointment=candidate.appointment,
              Set(candidate.contributors)==Set(request.documents.map(\.source.reference)) else{throw PinEvidenceError.invalidSupport}
        let scope=MemoryScope(ownerID:"local-photo-owner",namespace:"pin-appointments-v1")
        let sources=Set(candidate.factSources.map{PinCore.EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)})
        let snapshot=try PinEvidenceSnapshot(memories:memories,records:[PinRecordPin(id:ticket.id,revision:ticket.nextRevision,sources:sources)],scope:scope)
        let projection=MemoryProjection(recordID:ticket.id,recordRevision:ticket.nextRevision,scope:scope,appointment:appointment,support:candidate.support)
        let values=try LabelledAppointmentFieldValues.project(projection,sources:snapshot.authority.sources,policy:valuePolicy)
        let draft=try PinCanonicalMapping.draft(snapshot.bindEvidence(for:values.projection),primarySourceID:primarySourceID)
        let identities=try JSONDecoder().decode([AppointmentBookingIdentityEvidence].self,from:JSONEncoder().encode(candidate.identityEvidence))
        let link=AppointmentBookingLinkEvidence(identities:identities,taskSHA256:try expected.digest())
        return CanonicalAppointmentDraft(recordID:draft.recordID,recordRevision:draft.recordRevision,observation:draft.observation,sources:draft.sources,support:draft.support,documentOnlyWithoutDate:draft.documentOnlyWithoutDate,bookingLinkEvidence:link)
    }
    public static func rejection(_ candidate:AppointmentCandidate,memory:PhotoMemory)throws->AppointmentSourceRejection {
        let request=try Self.request(memory),task=try VisualObservationInterpreter.task(request,detailPolicy:.componentsV1)
        guard candidate.disposition == .notBooking,candidate.source==request.source.reference else{throw PinEvidenceError.invalidSupport}
        try candidate.receipt.validate(for:task)
        guard try candidate.receipt.choice("document")=="notBooking" else{throw PinEvidenceError.invalidSupport}
        return AppointmentSourceRejection(source:AppointmentSource(memory),observationIDs:request.lines.map(\.id),taskSHA256:try task.digest())
    }
    public static func draft(_ candidate:AppointmentCandidate,ticket:CanonicalWriteTicket,memory:PhotoMemory,valuePolicy:LabelledFieldValuePolicy = .legacyWholeLines)throws->CanonicalAppointmentDraft {
        let source=PinCore.EvidenceSource(memory)
        guard candidate.source.id==source.id,candidate.source.revision==source.revision,candidate.source.fingerprint==source.fingerprint,
              candidate.disposition == .booking,let appointment=candidate.appointment ?? candidate.partialAppointment else{throw PinEvidenceError.invalidSupport}
        let scope=MemoryScope(ownerID:"local-photo-owner",namespace:"pin-appointments-v1")
        let snapshot=try PinEvidenceSnapshot(memories:[memory],records:[PinRecordPin(id:ticket.id,revision:ticket.nextRevision,sources:[source])],scope:scope)
        let projection=MemoryProjection(recordID:ticket.id,recordRevision:ticket.nextRevision,scope:scope,appointment:appointment,support:candidate.support,documentOnlyWithoutDate:candidate.appointment==nil)
        let values=try LabelledAppointmentFieldValues.project(projection,sources:snapshot.authority.sources,policy:valuePolicy)
        return try PinCanonicalMapping.draft(snapshot.bindEvidence(for:values.projection),primarySourceID:memory.id)
    }
}

/// A resource budget includes connectivity waiting and the entire body, even
/// when a slow peer keeps resetting the idle request timeout. This changes no
/// admission, pairing, source allowlist or post-response lease check.
enum PinDevelopmentTransport {
    static func configuration(phoneTest:Bool,maximumDuration:TimeInterval,waitForConnectivity:Bool?=nil)->URLSessionConfiguration {
        let config=URLSessionConfiguration.ephemeral
        config.waitsForConnectivity=waitForConnectivity ?? phoneTest
        config.timeoutIntervalForRequest=maximumDuration
        config.timeoutIntervalForResource=maximumDuration
        config.httpCookieStorage=nil;config.urlCache=nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }
}
