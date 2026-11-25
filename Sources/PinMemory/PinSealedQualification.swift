import Foundation
import PinCore
import IBrainSemantics

/// Explicit consumer qualification. Ordinary/Release paths cannot enter it.
/// A physical test additionally requires the new sealed fixture session.
public enum PinSealedQualification {
    public static var usesReviewedSession:Bool {
        #if DEBUG
        return Bundle.main.bundleIdentifier=="app.pin.phonetest" && Bundle.main.object(forInfoDictionaryKey:"PinSealedAppointmentTest")as?Bool==true
        #else
        return false
        #endif
    }
    public static var isEnabled:Bool {
        if usesReviewedSession{return true}
        #if DEBUG && targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier=="app.pin.phonetest" && Bundle.main.object(forInfoDictionaryKey:"PinSealedBrainQualification")as?Bool==true
        #else
        return false
        #endif
    }
}
public struct PinSealedSourceEnvelope:Codable,Sendable {
    public let task:ChoiceTask
    public let memory:PhotoMemory
    public let recordID:String?
    public let recordRevision:Int?
    public let contextZone:String
    public var sessionID:UUID? = nil
    public var witness:PinFixtureSourceWitness? = nil
    public var groupContext:PinVisualGroupContext? = nil
    public init(task:ChoiceTask,memory:PhotoMemory,recordID:String?=nil,recordRevision:Int?=nil,contextZone:String){
        self.task=task;self.memory=memory;self.recordID=recordID;self.recordRevision=recordRevision;self.contextZone=contextZone
    }
}
/// Same pinned native development transport, with a typed source-only input
/// for exact replay/reconstruction of each completion stage on the paired Mac.
/// Raw native memory is local to that peer; the model receives only ChoiceTask.
public struct PinSealedBundleEnvelope:Codable,Sendable {
    public let task:ChoiceTask
    public let memories:[PhotoMemory]
    public let recordID:String
    public let recordRevision:Int
    public let contextZone:String
    public let sessionID:UUID
    public let witnesses:[PinFixtureSourceWitness]
}
public struct PinSealedSourceDecisionProvider:DecisionProvider {
    let pair:PinDevelopmentPair,memories:[PhotoMemory],recordID:String?,recordRevision:Int?,contextZone:String,witnesses:[PinFixtureSourceWitness]
    let validateCurrent:@Sendable()async throws->Void
    public init(pair:PinDevelopmentPair,memory:PhotoMemory,recordID:String?=nil,recordRevision:Int?=nil,contextZone:String,witnesses:[PinFixtureSourceWitness]=[],validateCurrent:@escaping @Sendable()async throws->Void)throws {
        try self.init(pair:pair,memories:[memory],recordID:recordID,recordRevision:recordRevision,contextZone:contextZone,witnesses:witnesses,validateCurrent:validateCurrent)
    }
    public init(pair:PinDevelopmentPair,memories:[PhotoMemory],recordID:String?,recordRevision:Int?,contextZone:String,witnesses:[PinFixtureSourceWitness],validateCurrent:@escaping @Sendable()async throws->Void)throws {
        try pair.validate();guard (1...3).contains(memories.count)else{throw PinDevelopmentError.sourceNotAllowed}
        self.pair=pair;self.memories=memories;self.recordID=recordID;self.recordRevision=recordRevision;self.contextZone=contextZone;self.witnesses=witnesses;self.validateCurrent=validateCurrent
    }
    public func decide(_ task:ChoiceTask)async throws->DecisionReceipt {
        #if DEBUG
        guard PinSealedQualification.isEnabled else{throw PinDevelopmentError.disabled}
        try pair.validate();try Task.checkCancellation();try await validateCurrent()
        for memory in memories{guard pair.allowedTextSHA256.contains(try PinDevelopmentSourceReader.textDigest((memory.textEvidence ?? []).map(\.text)))else{throw PinDevelopmentError.sourceNotAllowed}}
        guard TimeZone(identifier:contextZone) != nil else{throw PinDevelopmentError.configuration}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        var request=URLRequest(url:pair.endpoint);request.httpMethod="POST";request.timeoutInterval=125
        request.setValue("Bearer "+pair.token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        var reviewedBundle=false
        if let session=pair.sealedSession {
            try session.validateNativeProfile()
            guard contextZone==session.contextTimeZoneID,witnesses.count==memories.count,Set(witnesses.map{ $0.source.id }).count==memories.count else{throw PinDevelopmentError.sourceNotAllowed}
            for memory in memories{guard let witness=witnesses.first(where:{$0.source.id==memory.id})else{throw PinDevelopmentError.sourceNotAllowed};try session.validate(witness,memory:memory)}
            request.setValue(session.id.uuidString,forHTTPHeaderField:"X-Pin-Delivery-Session")
            if memories.count==1 {
                var envelope=PinSealedSourceEnvelope(task:task,memory:memories[0],recordID:recordID,recordRevision:recordRevision,contextZone:contextZone);envelope.sessionID=session.id;envelope.witness=witnesses[0];request.httpBody=try encoder.encode(envelope)
            }else{
                guard let recordID,let recordRevision else{throw PinDevelopmentError.sourceNotAllowed}
                try session.validateBundleTask(task,memories:memories);reviewedBundle=true
                request.httpBody=try encoder.encode(PinSealedBundleEnvelope(task:task,memories:memories,recordID:recordID,recordRevision:recordRevision,contextZone:contextZone,sessionID:session.id,witnesses:witnesses))
            }
        }else {
            #if targetEnvironment(simulator)
            guard !PinSealedQualification.usesReviewedSession,memories.count==1 else{throw PinDevelopmentError.disabled}
            request.httpBody=try encoder.encode(PinSealedSourceEnvelope(task:task,memory:memories[0],recordID:recordID,recordRevision:recordRevision,contextZone:contextZone))
            #else
            throw PinDevelopmentError.disabled
            #endif
        }
        let allowed:Set<String>=["appointment-visual-observations-v8/temporal-v7",ObservedTextFieldsInterpreter.version,TemporalMeaningInterpreter.version,"printed-start-field-roles-v3"]
        guard (reviewedBundle || allowed.contains(task.version)),request.httpBody!.count<=262144 else{throw PinDevelopmentError.sourceNotAllowed}
        let pin=PinPinnedTLS(pair.certificateSHA256),session=URLSession(configuration:PinDevelopmentTransport.configuration(phoneTest:pair.phoneTest != nil,maximumDuration:125),delegate:pin,delegateQueue:nil);defer{session.invalidateAndCancel()}
        let started=Date(),(bytes,response)=try await session.bytes(for:request,delegate:pin)
        guard let http=response as?HTTPURLResponse,http.statusCode==200,http.url==pair.endpoint,http.mimeType=="application/json"else{throw PinDevelopmentError.transport}
        var data=Data();for try await byte in bytes{try Task.checkCancellation();guard data.count<131072 else{throw PinDevelopmentError.oversized};data.append(byte)}
        guard (0...125).contains(Date().timeIntervalSince(started))else{throw PinDevelopmentError.transport}
        try pair.validate();try await validateCurrent();try Task.checkCancellation()
        let receipt=try JSONDecoder().decode(DecisionReceipt.self,from:data)
        guard receipt.provider=="pin-native-subscription",receipt.model=="gpt-6.1-sol",receipt.elapsedSeconds.isFinite,receipt.elapsedSeconds>=0,receipt.answers.values.allSatisfy({$0.confidence==nil && $0.probabilities==nil})else{throw PinDevelopmentError.invalidReceipt}
        try receipt.validate(for:task);return receipt
        #else
        throw PinDevelopmentError.disabled
        #endif
    }
}

public struct PinSealedValidatedProvider:DecisionProvider {
    let base:any DecisionProvider
    let validate:@Sendable()async throws->Void
    public init(base:any DecisionProvider,validate:@escaping @Sendable()async throws->Void){self.base=base;self.validate=validate}
    public func decide(_ task:ChoiceTask)async throws->DecisionReceipt{try await validate();let value=try await base.decide(task);try await validate();return value}
}
