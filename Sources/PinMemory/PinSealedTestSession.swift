import Foundation
import PinCore
import IBrainSemantics

/// A NEW bounded fictional delivery session. It cannot extend/reset the old
/// V4 phone lease or admit arbitrary user photos. This is not an account key.
public struct PinSealedTestSession:Codable,Equatable,Sendable {
    public let id:UUID
    public let sdkRevision:String
    public let candidateRevision:String
    public let fixtureManifestSHA256:String
    public let fixtureImageSHA256:[String:String]
    public let fixtureTextSHA256:[String:Set<String>]
    public let allowedQuestionSHA256:Set<String>
    /// Absence preserves the historical literal test bank. Natural questions
    /// require explicit native/profile/peer agreement and the same source proofs.
    public var questionAdmissionPolicy:String? = nil
    public static let sourceBoundNaturalPolicy="source-bound-natural-v1"
    public var usesNaturalQuestions:Bool{questionAdmissionPolicy==Self.sourceBoundNaturalPolicy}
    public func permitsQuestion(_ question:String)->Bool {
        guard !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,question.utf8.count<=1024 else{return false}
        return usesNaturalQuestions || allowedQuestionSHA256.contains(ChoiceTask.hash(Data(question.utf8)))
    }
    public let contextTimeZoneID:String
    public let issuedAt:Double
    public let expiresAt:Double
    public let sourceCap:Int
    public let questionCap:Int
    /// Absent preserves the sealed V11 contract. V12 is a deliberate opt-in
    /// bound to the exact SDK that supplies inventory/event-time separation.
    public let questionContractVersion:String?
    /// A sealed base revision plus the exact reviewed one-file derivative.
    /// Both fields are absent for legacy V6 sessions.
    public let bundleRolePolicy:String?
    public let bundlePatchSHA256:String?
    public static let currentFieldsPolicy="current-fields-v7"
    public static let currentFieldsPatchSHA256="ac425f58363c7a30fcb5121a01bb69ebf89621752d88008270b988119d92a4c8"
    public var bundleComponentRolePolicy:BundleComponentRolePolicy{bundleRolePolicy==Self.currentFieldsPolicy ? .currentFieldsV7:.separatedRolesV6}
    public static let inventoryTimeSDKRevision="c3c20e39a233709dd2eec0ab72169ccd6afa90cb"
    public var evidenceQuestionContractVersion:String{questionContractVersion ?? "photographed-evidence-question-v11"}
    public var temporalScopePolicy:EvidenceTemporalScopePolicy{questionContractVersion==EvidenceQuestionSession.temporalScopeContractVersion ? .inventoryVsEventTimeV1:.legacy}
    public func validate(now:Date=Date())throws {
        func hex(_ value:String,_ length:Int)->Bool{value.count==length && value.allSatisfy{("0123456789abcdef").contains($0)}}
        guard hex(sdkRevision,40),hex(candidateRevision,40),hex(fixtureManifestSHA256,64),
              issuedAt.isFinite,expiresAt.isFinite,expiresAt>issuedAt,expiresAt-issuedAt<=7200,
              (issuedAt...expiresAt).contains(now.timeIntervalSince1970),(1...20).contains(sourceCap),(1...24).contains(questionCap),
              (1...4).contains(fixtureImageSHA256.count),Set(fixtureImageSHA256.keys)==Set(fixtureTextSHA256.keys),
              fixtureImageSHA256.keys.allSatisfy({!$0.isEmpty && $0.utf8.count<=128}),
              fixtureImageSHA256.values.allSatisfy({hex($0,64)}),
              fixtureTextSHA256.values.allSatisfy({(1...3).contains($0.count) && $0.allSatisfy{hex($0,64)}}),
              (usesNaturalQuestions ? allowedQuestionSHA256.isEmpty:(1...24).contains(allowedQuestionSHA256.count)),allowedQuestionSHA256.allSatisfy({hex($0,64)}),
              TimeZone(identifier:contextTimeZoneID) != nil else{throw PinDevelopmentError.configuration}
        if let questionAdmissionPolicy {
            guard questionAdmissionPolicy==Self.sourceBoundNaturalPolicy,
                  questionContractVersion==EvidenceQuestionSession.temporalScopeContractVersion,
                  sdkRevision==Self.inventoryTimeSDKRevision else{throw PinDevelopmentError.configuration}
        }
        if bundleRolePolicy != nil || bundlePatchSHA256 != nil {
            guard bundleRolePolicy==Self.currentFieldsPolicy,bundlePatchSHA256==Self.currentFieldsPatchSHA256,
                  sdkRevision==Self.inventoryTimeSDKRevision else{throw PinDevelopmentError.configuration}
        }
        if let questionContractVersion {
            guard questionContractVersion==EvidenceQuestionSession.temporalScopeContractVersion,
                  sdkRevision==Self.inventoryTimeSDKRevision else{throw PinDevelopmentError.configuration}
        }
    }
    /// Transfer admission uses the same complete SDK task as native reading
    /// and Mac reconstruction. Merely naming a newer version is insufficient.
    public func validateBundleTask(_ task:ChoiceTask,memories:[PhotoMemory])throws {
        try validate()
        let expected=try ComponentEvidenceBundleInterpreter.task(for:PinDevelopmentSourceReader.bundleRequest(memories),rolePolicy:bundleComponentRolePolicy)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        guard try encoder.encode(task)==encoder.encode(expected)else{throw PinDevelopmentError.sourceNotAllowed}
    }
    public func validateNativeProfile()throws {
        try validate()
        guard PinSealedQualification.usesReviewedSession,
              Bundle.main.object(forInfoDictionaryKey:"PinSealedSDKRevision")as?String==sdkRevision,
              Bundle.main.object(forInfoDictionaryKey:"PinDeliveryCandidateRevision")as?String==candidateRevision,
              Bundle.main.object(forInfoDictionaryKey:"PinPhoneTestFixtureManifestSHA256")as?String==fixtureManifestSHA256 else{throw PinDevelopmentError.disabled}
        guard Bundle.main.object(forInfoDictionaryKey:"PinSealedQuestionAdmissionPolicy")as?String==questionAdmissionPolicy else{throw PinDevelopmentError.disabled}
        if let questionContractVersion {
            guard Bundle.main.object(forInfoDictionaryKey:"PinSealedQuestionContractVersion")as?String==questionContractVersion else{throw PinDevelopmentError.disabled}
        }
        if let bundleRolePolicy,let bundlePatchSHA256 {
            guard Bundle.main.object(forInfoDictionaryKey:"PinSealedBundleRolePolicy")as?String==bundleRolePolicy,
                  Bundle.main.object(forInfoDictionaryKey:"PinSealedBundlePatchSHA256")as?String==bundlePatchSHA256 else{throw PinDevelopmentError.disabled}
        }
    }
    public func validate(_ witness:PinFixtureSourceWitness,memory:PhotoMemory)throws {
        try validate()
        guard witness.source==PinCore.EvidenceSource(memory),fixtureImageSHA256[witness.slot]==witness.originalSHA256,
              witness.capturedAt==memory.photographedAt?.timeIntervalSince1970,
              witness.screenshot==memory.isScreenshot,
              fixtureTextSHA256[witness.slot]?.contains(try PinDevelopmentSourceReader.textDigest((memory.textEvidence ?? []).map(\.text)))==true else{throw PinDevelopmentError.sourceNotAllowed}
    }
}
/// Actual fixture-resource proof from PhotoKit. This SHA is deliberately
/// separate from Pin's real metadata fingerprint; it never replaces sourceFP.
public struct PinFixtureSourceWitness:Codable,Equatable,Sendable {
    public let slot:String
    public let originalSHA256:String
    public let source:PinCore.EvidenceSource
    public let capturedAt:Double?
    public let screenshot:Bool?
    public init(slot:String,originalSHA256:String,memory:PhotoMemory){self.slot=slot;self.originalSHA256=originalSHA256;source=PinCore.EvidenceSource(memory);capturedAt=memory.photographedAt?.timeIntervalSince1970;screenshot=memory.isScreenshot}
}
