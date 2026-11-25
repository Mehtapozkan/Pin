import Foundation
import IBrainSemantics

/// Explicit fictional Simulator evaluation configuration, never an account key.
/// The separate bound phone user session uses a real clock and sealed fictional facts.
public struct PinDevelopmentQuestionPair:Codable,Sendable {
    public let endpoint:URL
    public let certificateSHA256:String
    public let token:String
    public let allowedTaskSHA256:Set<String>
    public let evaluationNow:Date
    public let timeZoneID:String
    public let firstWeekday:Int
    public var phoneTest:PinPhoneTestBinding? = nil
    public var userSession:PinPhoneQuestionSession? = nil
    public var testEnded:Bool? = nil
    public var questionNow:Date {userSession == nil ? evaluationNow:Date()}
    public func validate()throws {
        try PinDevelopmentDestination.validate(endpoint,path:"/v1/question-choice",phoneTest:phoneTest)
        guard
              certificateSHA256.count==64,certificateSHA256.allSatisfy({$0.isHexDigit}),token.count>=32,token.count<=128,
              (userSession != nil ? allowedTaskSHA256.isEmpty:(1...16).contains(allowedTaskSHA256.count)),allowedTaskSHA256.allSatisfy({$0.count==64 && $0.allSatisfy{$0.isHexDigit}}),
              evaluationNow.timeIntervalSince1970.isFinite,TimeZone(identifier:timeZoneID) != nil,(1...7).contains(firstWeekday)else{throw PinDevelopmentError.configuration}
        if let userSession {guard phoneTest != nil else{throw PinDevelopmentError.configuration};try userSession.validate()}
    }
    public func calendar()throws->Calendar{try validate();var value=Calendar(identifier:.gregorian);value.timeZone=TimeZone(identifier:timeZoneID)!;value.firstWeekday=firstWeekday;value.minimumDaysInFirstWeek=1;return value}
}
public struct PinDevelopmentQuestionProvider:DecisionProvider {
    let pair:PinDevelopmentQuestionPair
    let contractVersion:String
    let authority:PinPhoneQuestionAuthority?
    let timingID:UUID?
    public init(pair:PinDevelopmentQuestionPair,policy:EvidenceQuestionPolicy = .completeV3,temporalScopePolicy:EvidenceTemporalScopePolicy = .legacy,authority:PinPhoneQuestionAuthority? = nil,timingID:UUID?=nil)throws {
        try pair.validate();self.pair=pair;self.authority=authority;self.timingID=timingID
        guard policy == .completeV9 || temporalScopePolicy == .legacy else{throw PinDevelopmentError.configuration}
        switch policy {
        case .completeV3:contractVersion=EvidenceQuestionSession.contractVersionV3
        case .completeV4:contractVersion=EvidenceQuestionSession.contractVersionV4
        case .currentV2,.completeV5,.completeV6,.completeV7,.completeV8:throw PinDevelopmentError.configuration
        case .completeV9:
            guard PinSealedQualification.isEnabled else{throw PinDevelopmentError.disabled}
            guard temporalScopePolicy == (pair.userSession?.sealedSession?.temporalScopePolicy ?? .legacy)else{throw PinDevelopmentError.configuration}
            contractVersion=pair.userSession?.sealedSession?.evidenceQuestionContractVersion ?? "photographed-evidence-question-v11"
        }
    }
    public func decide(_ task:ChoiceTask)async throws->DecisionReceipt {
        #if DEBUG
        if pair.testEnded==true {throw PinDevelopmentError.testEnded}
        try pair.validate()
        #if os(iOS) && !targetEnvironment(simulator)
        guard pair.phoneTest != nil else{throw PinDevelopmentError.disabled}
        #endif
        try Task.checkCancellation()
        guard task.id=="pin-current-question",task.version==contractVersion else{throw PinDevelopmentError.sourceNotAllowed}
        if let session=pair.userSession {try session.validateTask(task)}
        else {guard pair.allowedTaskSHA256.contains(try task.digest())else{throw PinDevelopmentError.sourceNotAllowed}}
        let timeLimit:TimeInterval=pair.userSession == nil ? 125:135
        let started=Date(),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        var request=URLRequest(url:pair.endpoint);request.httpMethod="POST";request.timeoutInterval=timeLimit
        if let session=pair.userSession {request.setValue(session.id.uuidString,forHTTPHeaderField:"X-Pin-Question-Session")}
        request.setValue("Bearer "+pair.token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");if let session=pair.userSession,session.authorityPolicy != nil {
            guard let authority else{throw PinDevelopmentError.configuration}
            struct FixtureState:Decodable{let importing:Bool;let ids:[String:String]}
            let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0],manifest=try Data(contentsOf:docs.appendingPathComponent("phone-test-fixtures.json"))
            guard let expected=Bundle.main.object(forInfoDictionaryKey:"PinPhoneTestFixtureManifestSHA256")as?String,ChoiceTask.hash(manifest)==expected else{throw PinDevelopmentError.sourceNotAllowed}
            let state=try JSONDecoder().decode(FixtureState.self,from:Data(contentsOf:docs.appendingPathComponent("phone-test-photo-state.json")))
            guard !state.importing,state.ids.count<=(pair.userSession?.sealedSession==nil ? 3:4) else{throw PinDevelopmentError.sourceNotAllowed}
            if let sealed=session.sealedSession {
                try sealed.validateNativeProfile()
                guard let binding=pair.phoneTest,binding.issuedAt==sealed.issuedAt,binding.expiresAt==sealed.expiresAt else{throw PinDevelopmentError.configuration}
                request.setValue(sealed.id.uuidString,forHTTPHeaderField:"X-Pin-Delivery-Session")
            }
            try authority.validate(session:session,sourceIDs:Set(state.ids.values),manifestSHA256:expected)
            struct Envelope:Encodable{let task:ChoiceTask;let authority:PinPhoneQuestionAuthority}
            request.httpBody=try encoder.encode(Envelope(task:task,authority:authority))
        }else {request.httpBody=try encoder.encode(task)}
        guard request.httpBody!.count<=(pair.userSession?.authorityPolicy == nil ? 131072:524288) else{throw PinDevelopmentError.oversized}
        let config=PinDevelopmentTransport.configuration(phoneTest:pair.phoneTest != nil,maximumDuration:timeLimit,waitForConnectivity:false)
        let pin=PinPinnedTLS(pair.certificateSHA256),session=URLSession(configuration:config,delegate:pin,delegateQueue:nil);defer{pin.endConnectionBudget();session.invalidateAndCancel()}
        pin.beginConnectionBudget(3,session:session)
        PinQuestionTiming.mark(timingID,"transport.begin")
        let(bytes,response)=try await session.bytes(for:request,delegate:pin)
        PinQuestionTiming.mark(timingID,"transport.headers")
        guard let http=response as? HTTPURLResponse,http.url==pair.endpoint,http.mimeType=="application/json"else{throw PinDevelopmentError.transport}
        if pair.phoneTest != nil,http.statusCode==429 {throw PinDevelopmentError.testEnded}
        guard http.statusCode==200 else{throw PinDevelopmentError.transport}
        var data=Data();for try await byte in bytes{try Task.checkCancellation();guard data.count<131072 else{throw PinDevelopmentError.oversized};data.append(byte)}
        guard (0...timeLimit).contains(Date().timeIntervalSince(started))else{throw PinDevelopmentError.transport}
        try pair.validate() // An expired phone lease cannot publish a late response.
        let receipt=try JSONDecoder().decode(DecisionReceipt.self,from:data)
        guard receipt.provider=="pin-native-subscription",receipt.model=="gpt-6.1-sol",receipt.elapsedSeconds.isFinite,receipt.elapsedSeconds>=0,
              receipt.answers.values.allSatisfy({$0.confidence==nil && $0.probabilities==nil})else{throw PinDevelopmentError.invalidReceipt}
        try receipt.validate(for:task);PinQuestionTiming.mark(timingID,"transport.receipt");return receipt
        #else
        throw PinDevelopmentError.disabled
        #endif
    }
}
