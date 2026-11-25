import Foundation
import CryptoKit
import PinCore
import IBrainSemantics
import IBrainVision
import IBrain

/// Transport and test-scope errors must not masquerade as semantic findings.
public enum PinFreshProductFailure:Error,Equatable {
    case unapprovedQuestion
    case unapprovedCorrection
    case requestTooLarge(bytes:Int,limit:Int)
    case sourceStillRunning
    case sourceReadingNotAuthorized
    case unfinishedSourceRead
    case sourceReadNotAdmitted
    case unresolvedEventUnits
    case interpreterSessionExpired
    case pairedMacUnavailable
    public static func notice(for error:any Error)->String {
        switch error {
        case PinCompactQueryMeaningError.clarify:
            return "Could you clarify which event or photo you mean?"
        case PinCompactQueryMeaningError.unknown:
            return "I’m not sure what you’d like to know. Could you ask that another way?"
        case Self.interpreterSessionExpired:
            return "The test connection has ended. Your saved photos and readings are available."
        case Self.pairedMacUnavailable:
            return "Pin Fresh Test couldn’t connect to the paired Mac. Your saved readings and original photos are kept."
        case Self.unapprovedCorrection:
            return "Your correction is saved on this phone. This test connection cannot use that edit yet."
        case Self.unapprovedQuestion:
            return "This question is outside the current sample test. Your saved readings and original photos are kept."
        case Self.requestTooLarge:
            return "I couldn’t send this photo’s reading because it exceeded the test’s request limit. Your saved readings and original photos are kept."
        case Self.sourceReadingNotAuthorized:
            return "Some photos need a new reading. This test connection can only use saved readings. Your original photos are kept."
        case Self.sourceStillRunning:
            return "The earlier photo reading is still processing. Your photos are kept; checking again won’t send another reading."
        case Self.unresolvedEventUnits:
            return "I’ve read ticket details, but I can’t yet establish the distinct events they represent. Your saved readings and original photos are kept."
        case Self.unfinishedSourceRead:
            return "The earlier photo reading didn’t finish. This test can’t start it again. Your saved readings and original photos are kept."
        case Self.sourceReadNotAdmitted:
            return "I couldn’t establish appointment or ticket details from every photo in this test. Your original photos are still available."
        case PinDevelopmentError.oversized:
            return "The sample test reached a data-size limit. Your saved readings and original photos are kept."
        default:
            return "I couldn’t finish processing that question. Your saved readings and original photos are kept."
        }
    }
}

public enum PinFreshProductSubmission {
    /// Repeated Search while the same request is pending keeps its original
    /// task alive. A different question is left to the native continuation owner.
    public static func keepsPendingQuestion(_ question:String,activeQuestion:String?,working:Bool)->Bool {
        guard working,let activeQuestion else{return false}
        return question.trimmingCharacters(in:.whitespacesAndNewlines)==activeQuestion.trimmingCharacters(in:.whitespacesAndNewlines)
    }
}

/// One locally queued input, bound to the operation and displayed context that
/// accepted it. This schedules no inference and grants no source authority.
public struct PinQuestionContinuation<Context> {
    public enum Admission:Equatable {case queued,duplicate,full}
    public enum AccessAdmission:Equatable {case waiting,queued,duplicate,full}
    public struct WaitingForAccess {
        public let requestID:UUID
        public let question:String
        public let submittedAt:Date
    }
    public struct Pending {
        public let question:String
        public let context:Context
        public let submittedAt:Date
        fileprivate let after:UUID
    }
    public private(set) var pending:Pending?
    public private(set) var waitingForAccess:WaitingForAccess?
    public init(){}
    /// Reserve the first operation before source access is ready. A later input
    /// belongs to that operation, not to whichever question is typed last.
    public mutating func waitForAccess(_ question:String,context:(UUID)->Context,submittedAt:Date=Date())->AccessAdmission {
        let text=question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.utf8.count<=4096 else{return .full}
        if let first=waitingForAccess {
            if first.question.utf8.elementsEqual(text.utf8){return .duplicate}
            switch enqueue(text,after:first.requestID,context:context(first.requestID),submittedAt:submittedAt) {
            case .queued:return .queued
            case .duplicate:return .duplicate
            case .full:return .full
            }
        }
        guard pending==nil else{return .full}
        waitingForAccess=WaitingForAccess(requestID:UUID(),question:text,submittedAt:submittedAt)
        return .waiting
    }
    public mutating func takeWaitingForAccess(accessReady:Bool,foreground:Bool,sourceReaderRunning:Bool=false)->WaitingForAccess? {
        // Confirmed access can precede the incremental local OCR pass. Keep
        // the same accepted operation until its source observations settle.
        guard accessReady,foreground,!sourceReaderRunning else{return nil}
        defer{waitingForAccess=nil};return waitingForAccess
    }
    public mutating func enqueue(_ question:String,after requestID:UUID,context:Context,submittedAt:Date=Date())->Admission {
        let text=question.trimmingCharacters(in:.whitespacesAndNewlines)
        if let pending {
            return pending.after==requestID && pending.question.utf8.elementsEqual(text.utf8) ? .duplicate:.full
        }
        guard !text.isEmpty,text.utf8.count<=4096 else{return .full}
        pending=Pending(question:text,context:context,submittedAt:submittedAt,after:requestID);return .queued
    }
    public mutating func take(after requestID:UUID)->Pending? {
        guard waitingForAccess==nil,pending?.after==requestID else{return nil}
        defer{pending=nil};return pending
    }
    public mutating func cancel(){waitingForAccess=nil;pending=nil}
}

/// An isolated session over exact public originals. Physical Debug execution
/// additionally requires an explicit build profile and expiring private-LAN pair.
public struct PinFreshProductConfiguration:Codable,Sendable {
    public struct Photo:Codable,Sendable {public let id:String;public let file:String;public let sha256:String;public var sourceID:String?=nil}
    public let session:UUID
    public let endpoint:URL
    public let certificateSHA256:String
    public let token:String
    public let expiresAt:Date
    public let photos:[Photo]
    public let questions:[String]
    public let temporalPolicy:ObservationTemporalPolicy
    public let planningPolicy:String
    public let temporalRoleExplanations:Bool?
    public let sourcePreparationRecovery:Bool?
    public let declaredImageProfileSHA256:String?
    /// Development continuation over retained native evidence; never reacquire it.
    public var nativeCorrectionPolicy:String?=nil
    public var allowedNativeCorrectionSHA256:Set<String>?=nil
    /// Opt-in intent policy; authority still requires authenticated native history.
    public var currentSavedInventoryV21:Bool?=nil
    public var photoScopeInventoryV22:Bool?=nil
    public var currentSourceScopeV23:Bool?=nil
    public var sourceDocumentListAssessmentV1:Bool?=nil
    public var selectedUnitContinuationV1:Bool?=nil
    public var savedLocationExtentV1:Bool?=nil
    public var inventoryDocumentIdentityV1:Bool?=nil
    public var photoCalendarDefaultsV1:Bool?=nil
    public var calendarInventoryDefaultsV1:Bool?=nil
    public var retainedEvidenceOnly:Bool?=nil
    /// Mirrored host dispatch partition, not semantic source authority.
    public var retainedSourceOnly:Bool?=nil
    public func requireSourceReading()throws {
        guard retainedSourceOnly != true,retainedEvidenceOnly != true else {
            throw PinFreshProductFailure.sourceReadingNotAuthorized
        }
    }
    public var printedClockNotation:Bool?=nil
    public var retainedClockRepair:Bool?=nil
    public var phoneTest:PinPhoneTestBinding?=nil
    public var productPlanning:Bool?=nil
    public var productSDKProfile:String?=nil
    public var productSDKIdentitySHA256:String?=nil
    public var sealedWorld:Bool?=nil
    public var productReconciliation:Bool?=nil
    public var productFactoryProfile:String?=nil
    public var combinedSourceFields:Bool?=nil
    public var selectedSourceValues:Bool?=nil
    public var sourceValueRecovery:String?=nil
    public var selectedValueRecovery:SourceReadingRecoveryPolicy {sourceValueRecovery=="nativeCompletionsV4" ? .nativeCompletionsV4:.nativeCompletionsV3}
    public var sourceCompletionCapacity:String?=nil
    public var selectedCompletionCapacity:SourceCompletionCapacity {sourceCompletionCapacity=="denseSourceV1" ? .denseSourceV1:.bounded64V1}
    public var pixelBoundImageFrameV2:Bool?=nil
    public var selectedImageProfileSHA256:String {pixelBoundImageFrameV2==true ? PinDeclaredAgentImageReader.pixelBoundProfileSHA256:unitSourceRecovery==true ? PinDeclaredAgentImageReader.runtimeProfileSHA256:PinDeclaredAgentImageReader.profileSHA256}
    /// Optional native dispatch partition; semantic source evidence remains separate.
    public var imageReadSourceIDs:Set<String>?=nil
    public var retainedImageSession:UUID?=nil
    public var retainedImageLedgerSHA256:String?=nil
    public var imageAttemptContinuation:PinImageAttemptContinuation?=nil
    /// Question-only sessions use admitted evidence. They must not reopen a
    /// prior acquisition continuation, whose authorization belongs to its session.
    public func authorizedImageRereadLedger(documents:URL)throws->PinImageRereadLedger? {
        guard retainedSourceOnly != true,retainedEvidenceOnly != true else{return nil}
        return try imageRereadLedger(documents:documents)
    }
    public func imageRereadLedger(documents:URL)throws->PinImageRereadLedger {
        guard questionAdmission==nil || (questionAdmission==PinPublicQuestionAdmission.naturalV1 && sourceOccurrencePolicy=="jointIdentityV3" && unitSourceRecovery==true && productReconciliation==true && sealedWorld==false)else{throw PinDevelopmentError.configuration}
        guard (retainedImageSession==nil)==(retainedImageLedgerSHA256==nil),retainedImageSession==nil || (sourceOccurrencePolicy=="jointIdentityV3" && unitSourceRecovery==true && retainedImageSession != session)else{throw PinDevelopmentError.configuration}
        let selected=retainedImageSession ?? session
        let directory=documents.appendingPathComponent("fresh-reread/"+selected.uuidString)
        if let expected=retainedImageLedgerSHA256,imageAttemptContinuation==nil {
            let bytes=try Data(contentsOf:directory.appendingPathComponent("attempts.json"))
            guard bytes.count<=131072,SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==expected else{throw PinDevelopmentError.configuration}
        }
        if let continuation=imageAttemptContinuation {
            try continuation.validate(continuationSession:session)
            guard retainedImageSession==continuation.session,retainedImageLedgerSHA256==continuation.ledgerSHA256 else{throw PinDevelopmentError.configuration}
        }
        return try PinImageRereadLedger(directory:directory,session:selected,maximumReads:imageReadSourceIDs?.count ?? 2,allowedSourceIDs:imageReadSourceIDs,continuation:imageAttemptContinuation,continuationSession:imageAttemptContinuation==nil ? nil:session)
    }
    public var compactQueryPolicy:String?=nil
    public var questionAdmission:String?=nil
    public var sourceOccurrencePolicy:String?=nil
    public var unitSourceRecovery:Bool?=nil
    public var resultUnits:Bool?=nil
    public var retainedOCRGrouping:Bool?=nil
    /// Bind native initial-read allocation to the complete source policy. Delivery
    /// credentials/nonces may change only through ordinary authorized setup;
    /// every stage still validates its exact normalized task and envelope.
    public func initialSourceRecoveryContractSHA256(contextZone:String)throws->String {
        let encoded=try JSONEncoder().encode(self)
        guard var value=try JSONSerialization.jsonObject(with:encoded) as? [String:Any] else{throw PinDevelopmentError.configuration}
        for key in ["session","endpoint","certificateSHA256","token","expiresAt","photos","questions","phoneTest","imageReadSourceIDs","retainedImageSession","retainedImageLedgerSHA256","imageAttemptContinuation","sourceRegressions","completedSourceArchives"] {value.removeValue(forKey:key)}
        value["initialSourceCoordinatorVersion"]="native-initial-stage-recovery-v1"
        value["contextZone"]=contextZone
        let bytes=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])
        return SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
    public var permitsLegacyProductQueries:Bool {retainedOCRGrouping != true}
    public var sourceFieldPolicy:String?=nil
    public var selectedFieldPolicy:ObservedTextFieldsPolicy {sourceFieldPolicy=="denseSourceV2" ? .denseSourceV2:.bounded64V1}
    public var sourceTaskPolicy:String?=nil
    public var sourceReceiptRecovery:String?=nil
    public var initialSourcePolicy:PinInitialSourcePolicy {(try? PinInitialSourcePolicy.configured(sourceTaskPolicy)) ?? .legacy}
    public var sourceInputProfile:String?=nil
    public var sourceOutputProfile:String?=nil
    public var localDenseOCR:Bool?=nil
    public var sourceRegressions:[PinSourceRegression]?=nil
    public var completedSourceArchives:[PinCompletedSourceArchive]?=nil
    /// Compare only for fixture authorization; the original question is retained
    /// verbatim in its task/receipt. Quotes are not semantic rewrites.
    public func permitsQuestion(_ question:String)->Bool {
        PinPublicQuestionAdmission.permits(question,policy:questionAdmission,configured:questions)
    }
    public func requestByteLimit(isSource:Bool)->Int {
        if productPlanning==true && (!isSource || (productReconciliation==true && [PinPublicProductScope.factoryProfile,PinPublicProductScope.unitFactoryProfile,PinPublicProductScope.unitRecoveryFactoryProfile].contains(productFactoryProfile ?? ""))){return 1_048_576}
        return 262144
    }
    public var selectedPlanningPolicy:ExhaustivePlanningPolicy {planningPolicy==ExhaustivePlanningPolicy.resultUnitsV4.rawValue ? .resultUnitsV4:planningPolicy==ExhaustivePlanningPolicy.composedOutputV3.rawValue ? .composedOutputV3:.sourceEvidenceV2}
    public var sourceVersion:String {temporalPolicy == .anchoredSpansV9 ? "appointment-visual-observations-v8/temporal-v9":"appointment-visual-observations-v8/temporal-v8"}
    public var printedStartVersion:String {temporalPolicy == .anchoredSpansV9 ? "printed-start-field-roles-v5-named-clocks":"printed-start-field-roles-v4"}
    public var explanationVersion:String {temporalPolicy == .anchoredSpansV9 ? "non-start-clock-explanations-v2/temporal-v9":TemporalRoleExplanationInterpreter.version}
    public func effectiveCompactQueryVersion(hasPrevious:Bool,hasVerifiedNativeCorrections:Bool=false)->String? {
        if calendarInventoryDefaultsV1==true && (hasPrevious || !hasVerifiedNativeCorrections) {return selectedUnitContinuationV1==true ? CompactProductQueryPlanner.selectedUnitContinuationVersion:savedLocationExtentV1==true ? CompactProductQueryPlanner.locationExtentVersion:photoCalendarDefaultsV1==true ? CompactProductQueryPlanner.photoCalendarDefaultsVersion:CompactProductQueryPlanner.calendarDefaultsVersion}
        if compactQueryPolicy==CompactProductQueryPlanner.memberAwareVersion && !hasPrevious {
            if currentSourceScopeV23==true && !hasVerifiedNativeCorrections{return PinPublicProductScope.currentSourceScopeQueryVersion}
            if photoScopeInventoryV22==true && !hasVerifiedNativeCorrections{return CompactProductQueryPlanner.photoScopeInventoryVersion}
            return currentSavedInventoryV21==true && hasVerifiedNativeCorrections ? CompactProductQueryPlanner.currentSavedInventoryVersion:CompactProductQueryPlanner.linkedUnitVersion
        }
        return compactQueryPolicy
    }
    public var queryVersion:String {compactQueryPolicy ?? (resultUnits==true ? ProductQuestionPlanner.resultUnitsVersion:productPlanning==true ? ProductQuestionPlanner.version:selectedPlanningPolicy == .composedOutputV3 ? ExhaustiveAppointmentPlanner.composedOutputVersion:ExhaustiveAppointmentPlanner.sourceEvidenceVersion)}
    public static var enabled:Bool {
        if PinPublicProductScope.isPhoneEnabled || PinPublicProductScope.usesExistingPhotoIntake{return true}
        #if DEBUG && targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier=="app.pin.freshproduct" && ProcessInfo.processInfo.arguments.contains("--fresh-product")
        #else
        return false
        #endif
    }
    public var nativeProcessingScope:PinNativePhotoProcessingScope? {
        get throws {
            let ids=photos.compactMap(\.sourceID)
            guard ids.isEmpty || (ids.count==photos.count && Set(ids).count==ids.count)else{throw PinDevelopmentError.sourceNotAllowed}
            return ids.isEmpty ? nil:try PinNativePhotoProcessingScope(sourceIDs:Set(ids))
        }
    }
    public func validate()throws {
        guard selectedSourceValues==nil || (selectedSourceValues==true && compactQueryPolicy==CompactProductQueryPlanner.memberAwareVersion && sourceValueRecovery=="nativeCompletionsV4" && unitSourceRecovery==true)else{throw PinDevelopmentError.configuration}
        let processing=try nativeProcessingScope
        if PinPublicProductScope.usesExistingPhotoIntake {
            guard processing != nil,PinPublicProductScope.declaredFixtureManifestSHA256==PinPublicProductScope.fixtureManifestIdentity(photos.map(\.sha256))else{throw PinDevelopmentError.sourceNotAllowed}
        }
        guard selectedUnitContinuationV1==nil || (selectedUnitContinuationV1==true && savedLocationExtentV1==true)else{throw PinDevelopmentError.configuration}
        guard savedLocationExtentV1==nil || (savedLocationExtentV1==true && inventoryDocumentIdentityV1==true)else{throw PinDevelopmentError.configuration}
        guard inventoryDocumentIdentityV1==nil || (inventoryDocumentIdentityV1==true && photoCalendarDefaultsV1==true && sourceDocumentListAssessmentV1==true)else{throw PinDevelopmentError.configuration}
        guard photoCalendarDefaultsV1==nil || (photoCalendarDefaultsV1==true && calendarInventoryDefaultsV1==true)else{throw PinDevelopmentError.configuration}
        guard calendarInventoryDefaultsV1==nil || (calendarInventoryDefaultsV1==true && currentSourceScopeV23==true && productPlanning==true && resultUnits==true && selectedPlanningPolicy == .resultUnitsV4)else{throw PinDevelopmentError.configuration}
        guard sourceDocumentListAssessmentV1==nil || (sourceDocumentListAssessmentV1==true && currentSourceScopeV23==true && productPlanning==true)else{throw PinDevelopmentError.configuration}
        guard currentSourceScopeV23==nil || (currentSourceScopeV23==true && photoScopeInventoryV22==true && selectedSourceValues==true && compactQueryPolicy==CompactProductQueryPlanner.memberAwareVersion)else{throw PinDevelopmentError.configuration}
        guard photoScopeInventoryV22==nil || (photoScopeInventoryV22==true && selectedSourceValues==true && compactQueryPolicy==CompactProductQueryPlanner.memberAwareVersion)else{throw PinDevelopmentError.configuration}
        guard currentSavedInventoryV21 != true || (compactQueryPolicy==CompactProductQueryPlanner.memberAwareVersion && nativeCorrectionPolicy==PinNativeCorrectionWitness.policy && retainedEvidenceOnly==true)else{throw PinDevelopmentError.configuration}
        if let policy=nativeCorrectionPolicy {
            guard policy==PinNativeCorrectionWitness.policy,[CompactProductQueryPlanner.linkedUnitVersion,CompactProductQueryPlanner.memberAwareVersion].contains(compactQueryPolicy ?? ""),
                  retainedEvidenceOnly==true,resultUnits==true,unitSourceRecovery==true,
                  let allowed=allowedNativeCorrectionSHA256,(1...16).contains(allowed.count),
                  allowed.allSatisfy({$0.count==64 && $0.allSatisfy({"0123456789abcdef".contains($0)})})else{throw PinDevelopmentError.configuration}
        }else{guard allowedNativeCorrectionSHA256==nil else{throw PinDevelopmentError.configuration}}
        try PinDevelopmentDestination.validate(endpoint,path:"/v1/source-choice",phoneTest:phoneTest)
        guard compactQueryPolicy==nil || ([CompactProductQueryPlanner.version,CompactProductQueryPlanner.linkedUnitVersion,CompactProductQueryPlanner.memberAwareVersion].contains(compactQueryPolicy!) && resultUnits==true && unitSourceRecovery==true && sourceOccurrencePolicy=="jointIdentityV3" && productPlanning==true && productReconciliation==true)else{throw PinDevelopmentError.configuration}
        guard questionAdmission==nil || (questionAdmission==PinPublicQuestionAdmission.naturalV1 && sourceOccurrencePolicy=="jointIdentityV3" && unitSourceRecovery==true && productReconciliation==true && sealedWorld==false)else{throw PinDevelopmentError.configuration}
        if let allowed=imageReadSourceIDs {
            guard ((retainedImageSession==nil && retainedImageLedgerSHA256==nil) || imageAttemptContinuation != nil),unitSourceRecovery==true,pixelBoundImageFrameV2==true,productReconciliation==true,sourceOccurrencePolicy=="jointIdentityV3",!allowed.isEmpty,allowed.count<photos.count,allowed.isSubset(of:Set(photos.compactMap(\.sourceID)))else{throw PinDevelopmentError.configuration}
        }
        if let continuation=imageAttemptContinuation {
            try continuation.validate(continuationSession:session)
            guard retainedImageSession==continuation.session,retainedImageLedgerSHA256==continuation.ledgerSHA256,
                  imageReadSourceIDs?.contains(continuation.source.id)==true,pixelBoundImageFrameV2==true,
                  unitSourceRecovery==true else{throw PinDevelopmentError.configuration}
        }
        guard (retainedImageSession==nil)==(retainedImageLedgerSHA256==nil) else{throw PinDevelopmentError.configuration}
        if let old=retainedImageSession,let hash=retainedImageLedgerSHA256 {guard old != session,sourceOccurrencePolicy=="jointIdentityV3",unitSourceRecovery==true,hash.count==64,hash.allSatisfy(\.isHexDigit)else{throw PinDevelopmentError.configuration}}
        guard sourceOccurrencePolicy==nil || (sourceOccurrencePolicy=="jointIdentityV3" && unitSourceRecovery==true) else{throw PinDevelopmentError.configuration}
        guard (planningPolicy==ExhaustivePlanningPolicy.resultUnitsV4.rawValue)==(resultUnits==true)else{throw PinDevelopmentError.configuration}
        guard productPlanning != true || (resultUnits==true ? selectedPlanningPolicy == .resultUnitsV4:selectedPlanningPolicy == .composedOutputV3) else{throw PinDevelopmentError.configuration}
        if productPlanning==true {
            guard productSDKProfile==(selectedUnitContinuationV1==true ? PinPublicProductScope.selectedUnitContinuationSDKProfile:savedLocationExtentV1==true ? PinPublicProductScope.savedLocationExtentSDKProfile:inventoryDocumentIdentityV1==true ? PinPublicProductScope.documentIdentitySDKProfile:photoCalendarDefaultsV1==true ? PinPublicProductScope.photoCalendarDefaultsSDKProfile:calendarInventoryDefaultsV1==true ? PinPublicProductScope.calendarDefaultsSDKProfile:sourceDocumentListAssessmentV1==true ? PinPublicProductScope.sourceDocumentListSDKProfile:currentSourceScopeV23==true ? PinPublicProductScope.currentSourceScopeSDKProfile:photoScopeInventoryV22==true ? PinPublicProductScope.photoScopeSDKProfile:selectedSourceValues==true ? PinPublicProductScope.selectedValuesSDKProfile:compactQueryPolicy==CompactProductQueryPlanner.memberAwareVersion ? PinPublicProductScope.memberCompactQuerySDKProfile:compactQueryPolicy==CompactProductQueryPlanner.linkedUnitVersion ? PinPublicProductScope.linkedCompactQuerySDKProfile:compactQueryPolicy != nil ? PinPublicProductScope.compactQuerySDKProfile:sourceOccurrencePolicy=="jointIdentityV3" ? PinPublicProductScope.jointOccurrenceSDKProfile:unitSourceRecovery==true ? PinPublicProductScope.unitRecoverySDKProfile:resultUnits==true ? PinPublicProductScope.unitSDKProfile:combinedSourceFields==true ? PinPublicProductScope.combinedFieldsSDKProfile:sourceValueRecovery != nil ? PinPublicProductScope.separatedDateSDKProfile:sourceCompletionCapacity != nil ? PinPublicProductScope.sharedCapacitySDKProfile:retainedOCRGrouping==true ? PinPublicProductScope.retainedGroupingSDKProfile:sourceFieldPolicy != nil ? PinPublicProductScope.denseFieldsSDKProfile:sourceTaskPolicy==nil ? PinPublicProductScope.sdkProfile:PinPublicProductScope.compactSDKProfile),productSDKIdentitySHA256==(selectedUnitContinuationV1==true ? PinPublicProductScope.selectedUnitContinuationSDKIdentitySHA256:savedLocationExtentV1==true ? PinPublicProductScope.savedLocationExtentSDKIdentitySHA256:inventoryDocumentIdentityV1==true ? PinPublicProductScope.documentIdentitySDKIdentitySHA256:photoCalendarDefaultsV1==true ? PinPublicProductScope.photoCalendarDefaultsSDKIdentitySHA256:calendarInventoryDefaultsV1==true ? PinPublicProductScope.calendarDefaultsSDKIdentitySHA256:sourceDocumentListAssessmentV1==true ? PinPublicProductScope.sourceDocumentListSDKIdentitySHA256:currentSourceScopeV23==true ? PinPublicProductScope.currentSourceScopeSDKIdentitySHA256:photoScopeInventoryV22==true ? PinPublicProductScope.photoScopeSDKIdentitySHA256:selectedSourceValues==true ? PinPublicProductScope.selectedValuesSDKIdentitySHA256:compactQueryPolicy==CompactProductQueryPlanner.memberAwareVersion ? PinPublicProductScope.memberCompactQuerySDKIdentitySHA256:compactQueryPolicy==CompactProductQueryPlanner.linkedUnitVersion ? PinPublicProductScope.linkedCompactQuerySDKIdentitySHA256:compactQueryPolicy != nil ? PinPublicProductScope.compactQuerySDKIdentitySHA256:sourceOccurrencePolicy=="jointIdentityV3" ? PinPublicProductScope.jointOccurrenceSDKIdentitySHA256:unitSourceRecovery==true ? PinPublicProductScope.unitRecoverySDKIdentitySHA256:resultUnits==true ? PinPublicProductScope.unitSDKIdentitySHA256:combinedSourceFields==true ? PinPublicProductScope.combinedFieldsSDKIdentitySHA256:sourceValueRecovery != nil ? PinPublicProductScope.separatedDateSDKIdentitySHA256:sourceCompletionCapacity != nil ? PinPublicProductScope.sharedCapacitySDKIdentitySHA256:retainedOCRGrouping==true ? PinPublicProductScope.retainedGroupingSDKIdentitySHA256:sourceFieldPolicy != nil ? PinPublicProductScope.denseFieldsSDKIdentitySHA256:sourceTaskPolicy==nil ? PinPublicProductScope.sdkIdentitySHA256:PinPublicProductScope.compactSDKIdentitySHA256),sealedWorld==false else{throw PinDevelopmentError.configuration}
        }else if productSDKProfile != nil || productSDKIdentitySHA256 != nil {throw PinDevelopmentError.configuration}
        if productReconciliation==true {
            guard productPlanning==true,productFactoryProfile==(unitSourceRecovery==true ? PinPublicProductScope.unitRecoveryFactoryProfile:resultUnits==true ? PinPublicProductScope.unitFactoryProfile:PinPublicProductScope.factoryProfile),(unitSourceRecovery==true ? declaredImageProfileSHA256==selectedImageProfileSHA256:declaredImageProfileSHA256==nil),retainedClockRepair != true,(retainedEvidenceOnly != true || nativeCorrectionPolicy==PinNativeCorrectionWitness.policy) else{throw PinDevelopmentError.configuration}
        }else if productFactoryProfile != nil {throw PinDevelopmentError.configuration}
        guard pixelBoundImageFrameV2==nil || (pixelBoundImageFrameV2==true && unitSourceRecovery==true) else{throw PinDevelopmentError.configuration}
        guard unitSourceRecovery==nil || unitSourceRecovery==true else{throw PinDevelopmentError.configuration}
        let undispatched=sourceRegressions?.first?.undispatchedEnvelopeSHA256 != nil
        let closedAllocation=sourceRegressions?.first?.closedAllocationSHA256 != nil
        if undispatched || closedAllocation {
            guard let regressions=sourceRegressions,regressions.count==1,
                  let regression=regressions.first,(closedAllocation ? regression.source.revision>0:regression.source.revision==1),
                  photos.contains(where:{$0.sourceID==regression.source.id}),
                  processing != nil,PinPublicProductScope.usesExistingPhotoIntake,
                  phoneTest?.bundleID==PinPublicProductScope.isolatedPhoneBundleID,
                  unitSourceRecovery==true,pixelBoundImageFrameV2==true,selectedSourceValues==true,
                  retainedEvidenceOnly != true,localDenseOCR != true else{throw PinDevelopmentError.configuration}
        }
        if unitSourceRecovery==true{guard photos.count<=2,resultUnits==true,sourcePreparationRecovery==true,temporalRoleExplanations != true,localDenseOCR != true,(sourceRegressions==nil || undispatched || closedAllocation) else{throw PinDevelopmentError.configuration}}
        guard resultUnits==nil || resultUnits==true else{throw PinDevelopmentError.configuration}
        if resultUnits==true {guard productPlanning==true,productReconciliation==true,combinedSourceFields==true,retainedOCRGrouping==true,printedClockNotation==true,temporalPolicy == .anchoredSpansV9 else{throw PinDevelopmentError.configuration}}
        guard combinedSourceFields==nil || combinedSourceFields==true else{throw PinDevelopmentError.configuration}
        if combinedSourceFields==true {guard sourceValueRecovery=="nativeCompletionsV4",sourceCompletionCapacity=="denseSourceV1",sourceFieldPolicy=="denseSourceV2",retainedOCRGrouping==true else{throw PinDevelopmentError.configuration}}
        guard sourceValueRecovery==nil || sourceValueRecovery=="nativeCompletionsV4" else{throw PinDevelopmentError.configuration}
        if sourceValueRecovery != nil {guard sourceCompletionCapacity=="denseSourceV1" else{throw PinDevelopmentError.configuration}}
        guard sourceCompletionCapacity==nil || sourceCompletionCapacity=="denseSourceV1" else{throw PinDevelopmentError.configuration}
        if sourceCompletionCapacity != nil {guard retainedOCRGrouping==true,sourceFieldPolicy=="denseSourceV2" else{throw PinDevelopmentError.configuration}}
        guard retainedOCRGrouping==nil || retainedOCRGrouping==true else{throw PinDevelopmentError.configuration}
        if retainedOCRGrouping==true {guard sourceReceiptRecovery=="initial-and-retained-grouping-v2",sourceFieldPolicy=="denseSourceV2",initialSourcePolicy.usesCompactKeys else{throw PinDevelopmentError.configuration}}
        guard sourceFieldPolicy==nil || sourceFieldPolicy=="denseSourceV2" else{throw PinDevelopmentError.configuration}
        if sourceFieldPolicy != nil {guard initialSourcePolicy.usesCompactKeys else{throw PinDevelopmentError.configuration}}
        _=try PinInitialSourcePolicy.configured(sourceTaskPolicy)
        if initialSourcePolicy == .compactCurrentVisualV1 || initialSourcePolicy == .initialImageFirstV1 {guard unitSourceRecovery==true,pixelBoundImageFrameV2==true else{throw PinDevelopmentError.configuration}}
        if sourceTaskPolicy != nil {guard temporalPolicy == .anchoredSpansV9,["initial-v1","initial-and-retained-grouping-v2"].contains(sourceReceiptRecovery ?? ""),sourceInputProfile=="pin-finite-choice-shared-input-v1",sourceOutputProfile=="pin-shared-finite-output-schema-v1" else{throw PinDevelopmentError.configuration}}
        guard sourceReceiptRecovery==nil || ["initial-v1","initial-and-retained-grouping-v2"].contains(sourceReceiptRecovery!),
              sourceInputProfile==nil || sourceInputProfile=="pin-finite-choice-shared-input-v1",
              sourceOutputProfile==nil || sourceOutputProfile=="pin-shared-finite-output-schema-v1" else{throw PinDevelopmentError.configuration}
        if sourceTaskPolicy != nil || sourceReceiptRecovery != nil || sourceInputProfile != nil || sourceOutputProfile != nil {
            guard productReconciliation==true,sourcePreparationRecovery==true else{throw PinDevelopmentError.configuration}
        }
        if localDenseOCR==true || (sourceRegressions != nil && !undispatched && !closedAllocation) {
            guard productReconciliation==true,declaredImageProfileSHA256==nil,sourcePreparationRecovery==true else{throw PinDevelopmentError.configuration}
        }
        if let regressions=sourceRegressions {
            guard (1...4).contains(regressions.count),Set(regressions.map(\.source)).count==regressions.count else{throw PinDevelopmentError.configuration}
            for regression in regressions {
                guard (regression.undispatchedEnvelopeSHA256 != nil)==undispatched else{throw PinDevelopmentError.configuration}
                guard (regression.closedAllocationSHA256 != nil)==closedAllocation else{throw PinDevelopmentError.configuration}
                try regression.validate(session:session)
            }
        }
        if let archives=completedSourceArchives {
            guard unitSourceRecovery==true,(1...2).contains(archives.count),
                  Set(archives.map{$0.source.id}).count==archives.count,
                  archives.allSatisfy({archive in !(sourceRegressions ?? []).contains(where:{$0.source.id==archive.source.id})}) else{throw PinDevelopmentError.configuration}
            for archive in archives {try archive.validate(currentSession:session)}
        }
        if let continuation=imageAttemptContinuation {
            guard continuation.source.revision==2,
                  completedSourceArchives?.filter({$0.session==continuation.session && $0.source==continuation.source}).count==1 else{throw PinDevelopmentError.configuration}
        }
        if PinPublicProductScope.isPhoneEnabled {
            if let mode=questionAdmission {guard Bundle.main.object(forInfoDictionaryKey:"PinPublicQuestionAdmission")as?String==mode,PinPublicProductScope.declaredFixtureManifestSHA256 != nil else{throw PinDevelopmentError.configuration}}
            if let manifest=PinPublicProductScope.declaredFixtureManifestSHA256 {guard manifest==PinPublicProductScope.fixtureManifestIdentity(photos.map(\.sha256))else{throw PinDevelopmentError.configuration}}
            guard let phoneTest,expiresAt.timeIntervalSince1970<=phoneTest.expiresAt,productReconciliation==true,Bundle.main.object(forInfoDictionaryKey:"PinProductSDKIdentitySHA256")as?String==productSDKIdentitySHA256 else{throw PinDevelopmentError.configuration}
        }else if phoneTest != nil {throw PinDevelopmentError.configuration}
        guard retainedClockRepair != true || (printedClockNotation==true && temporalRoleExplanations==true && retainedEvidenceOnly != true) else{throw PinDevelopmentError.configuration}
        guard printedClockNotation != true || temporalPolicy == .anchoredSpansV9 else{throw PinDevelopmentError.configuration}
        if let profile=declaredImageProfileSHA256 {guard profile==selectedImageProfileSHA256,temporalPolicy == .anchoredSpansV9,sourcePreparationRecovery==true else{throw PinDevelopmentError.configuration}}
        guard [.anchoredSpansV8,.anchoredSpansV9].contains(temporalPolicy),[ExhaustivePlanningPolicy.sourceEvidenceV2.rawValue,ExhaustivePlanningPolicy.composedOutputV3.rawValue,ExhaustivePlanningPolicy.resultUnitsV4.rawValue].contains(planningPolicy),expiresAt>Date(),expiresAt.timeIntervalSinceNow<=14400,
              certificateSHA256.count==64,certificateSHA256.allSatisfy(\.isHexDigit),
              (32...128).contains(token.count),(1...4).contains(photos.count),Set(photos.map(\.sha256)).count==photos.count,
              photos.allSatisfy({$0.sha256.count==64 && $0.sha256.allSatisfy(\.isHexDigit) && $0.file=="photos/"+$0.id+".jpg" && $0.id.allSatisfy({$0.isLetter || $0.isNumber})}),
              (1...8).contains(questions.count),questions.allSatisfy({!$0.isEmpty && $0.utf8.count<=4096})else{throw PinDevelopmentError.configuration}
    }
    /// Reopen local indexing/projections without renewing a model lease.
    /// Manifest verification supplies only processing IDs; every dispatch still
    /// requires a live configuration and current original-SHA/native checks.
    public static func localNativeProcessingScope()throws->PinNativePhotoProcessingScope? {
        guard PinPublicProductScope.usesExistingPhotoIntake else{return nil}
        guard let signed=PinPublicProductScope.declaredFixtureManifestSHA256 else{throw PinDevelopmentError.configuration}
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let bytes=try Data(contentsOf:docs.appendingPathComponent(PinPublicProductScope.configurationFileName()))
        return try PinLocalFixtureAccess(configurationData:bytes,signedManifestSHA256:signed).existingProcessingScope()
    }
    public static func load()throws->Self {
        guard enabled else{throw PinDevelopmentError.disabled}
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent(PinPublicProductScope.configurationFileName())
        let bytes=try Data(contentsOf:file);guard bytes.count<=16384 else{throw PinDevelopmentError.oversized}
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let value=try decoder.decode(Self.self,from:bytes)
        guard value.expiresAt>Date()else{throw PinFreshProductFailure.interpreterSessionExpired}
        try value.validate();return value
    }
}
private struct PinFreshProductEnvelope<Payload:Encodable>:Encodable {let session:UUID;let task:Payload;let memory:PhotoMemory?;let originalSHA256:String?;let recordID:String?;let recordRevision:Int?;let contextZone:String;let temporalPolicy:ObservationTemporalPolicy;let planningPolicy:String;let temporalRoleExplanations:Bool?;let sourcePreparationRecovery:Bool?;let declaredImageProfileSHA256:String?;let groupContext:PinVisualGroupContext?;let retainedEvidenceOnly:Bool?;let printedClockNotation:Bool?;let retainedClockRepair:Bool?;let clockRepair:PinPrintedClockRepairInput?;let productPlanning:Bool?;let authority:PinProductQuestionAuthority?;let parentPublication:PinProductPublishedParent?;let questionRequestID:UUID?;let productReconciliation:Bool?;let productFactoryProfile:String?;let localDenseOCR:Bool?;let sourceRegressions:[PinSourceRegression]?;let combinedSourceFields:Bool?;let selectedSourceValues:Bool?;let sourceValueRecovery:String?;let sourceCompletionCapacity:String?;let resultUnits:Bool?;let questionAdmission:String?;let sourceOccurrencePolicy:String?;let unitSourceRecovery:Bool?;let retainedOCRGrouping:Bool?;let retainedGroupingInitialReceipt:DecisionReceipt?;let sourceFieldPolicy:String?;let sourceTaskPolicy:String?;let sourceReceiptRecovery:String?;let sourceInputProfile:String?;let sourceOutputProfile:String?;let compactQueryPolicy:String?}

public struct PinFreshProductProvider:DecisionProvider,CompactProductQueryProvider {
    let config:PinFreshProductConfiguration
    let memory:PhotoMemory?
    let originalSHA256:String?
    let recordID:String?
    let recordRevision:Int?
    let groupContext:PinVisualGroupContext?
    let clockRepair:PinPrintedClockRepairInput?
    let authority:PinProductQuestionAuthority?
    let parentPublication:PinProductPublishedParent?
    let questionRequestID:UUID?
    let retainedGroupingInitialReceipt:DecisionReceipt?
    let initialAttempt:URL?
    let recoverInitial:Bool
    let requiredEnvelopeSHA256:String?
    let retainedFirstAssessment:URL?
    let completedSourceCheckpoint:PinCompletedSourceCheckpoint?
    let sourceStages:PinSourceStageJournal?
    let beforeSourceStageSend:(@Sendable ()async throws->Void)?
    let check:@Sendable()async throws->Void
    public init(config:PinFreshProductConfiguration,memory:PhotoMemory?=nil,originalSHA256:String?=nil,recordID:String?=nil,recordRevision:Int?=nil,groupContext:PinVisualGroupContext?=nil,clockRepair:PinPrintedClockRepairInput?=nil,authority:PinProductQuestionAuthority?=nil,parentPublication:PinProductPublishedParent?=nil,questionRequestID:UUID?=nil,retainedGroupingInitialReceipt:DecisionReceipt?=nil,initialAttempt:URL?=nil,recoverInitial:Bool=false,requiredEnvelopeSHA256:String?=nil,retainedFirstAssessment:URL?=nil,completedSourceCheckpoint:PinCompletedSourceCheckpoint?=nil,sourceStages:PinSourceStageJournal?=nil,beforeSourceStageSend:(@Sendable ()async throws->Void)?=nil,check:@escaping @Sendable()async throws->Void)throws {
        guard beforeSourceStageSend==nil || sourceStages != nil else{throw PinDevelopmentError.configuration}
        self.beforeSourceStageSend=beforeSourceStageSend
        self.sourceStages=sourceStages
        if let sourceStages {
            guard config.unitSourceRecovery==true,let memory,let originalSHA256,
                  clockRepair==nil,authority==nil,parentPublication==nil,initialAttempt==nil,!recoverInitial,
                  requiredEnvelopeSHA256==nil,retainedFirstAssessment==nil,completedSourceCheckpoint==nil else{throw PinDevelopmentError.configuration}
            try sourceStages.validateBinding(memory:memory,originalSHA256:originalSHA256,transaction:sourceStages.transactionID)
        }
        self.retainedFirstAssessment=retainedFirstAssessment
        self.completedSourceCheckpoint=completedSourceCheckpoint
        if completedSourceCheckpoint != nil {
            guard config.unitSourceRecovery==true,let memory,memory.revision>=2,try memory.visualReading?.validatedReceipt().visibleDocumentCount==1,
                  groupContext==nil,clockRepair==nil,authority==nil,parentPublication==nil,retainedGroupingInitialReceipt==nil,
                  initialAttempt==nil,!recoverInitial,requiredEnvelopeSHA256==nil,retainedFirstAssessment==nil else{throw PinDevelopmentError.configuration}
        }
        if retainedFirstAssessment != nil {guard memory?.revision==1,memory?.visualReading==nil,groupContext?.schema==2,groupContext?.ordinal==1,recordID==nil,recordRevision==nil,initialAttempt==nil,!recoverInitial,requiredEnvelopeSHA256==nil,authority==nil,parentPublication==nil,clockRepair==nil,retainedGroupingInitialReceipt==nil else{throw PinDevelopmentError.configuration}}
        try config.validate()
        if memory != nil,completedSourceCheckpoint==nil,sourceStages?.replayOnly != true {try config.requireSourceReading()}
        self.requiredEnvelopeSHA256=requiredEnvelopeSHA256
        if let expected=requiredEnvelopeSHA256 {guard config.unitSourceRecovery==true,expected.count==64,expected.allSatisfy(\.isHexDigit),memory != nil,groupContext==nil,recordID==nil,recordRevision==nil,authority==nil,parentPublication==nil,initialAttempt==nil,!recoverInitial else{throw PinDevelopmentError.configuration}}
        self.config=config;self.memory=memory;self.originalSHA256=originalSHA256;self.recordID=recordID;self.recordRevision=recordRevision;self.groupContext=groupContext;self.clockRepair=clockRepair;self.check=check;self.authority=authority;self.parentPublication=parentPublication
        self.retainedGroupingInitialReceipt=retainedGroupingInitialReceipt
        if retainedGroupingInitialReceipt != nil {guard config.retainedOCRGrouping==true,(config.unitSourceRecovery==true ? (memory?.revision ?? 0)>0:memory?.revision==1),memory?.visualReading==nil,groupContext==nil,recordID==nil,recordRevision==nil,authority==nil,parentPublication==nil else{throw PinDevelopmentError.configuration}}
        self.questionRequestID=questionRequestID;self.initialAttempt=initialAttempt;self.recoverInitial=recoverInitial
        guard !recoverInitial || initialAttempt != nil else{throw PinDevelopmentError.configuration}
        if initialAttempt != nil {
            guard ["initial-v1","initial-and-retained-grouping-v2"].contains(config.sourceReceiptRecovery ?? ""),memory?.revision==1,memory?.visualReading==nil,recordID==nil,recordRevision==nil,groupContext==nil,clockRepair==nil,authority==nil,parentPublication==nil else{throw PinDevelopmentError.configuration}
        }
        guard config.productReconciliation != true || questionRequestID != nil else{throw PinDevelopmentError.configuration}
        guard memory != nil || config.productPlanning != true || authority != nil else{throw PinDevelopmentError.configuration}
        if let authority{guard config.productPlanning==true,authority.sealedWorld==config.sealedWorld else{throw PinDevelopmentError.configuration}}
        if let authority,let scope=try config.nativeProcessingScope {
            guard scope.memories(authority.memories)==authority.memories,
                  scope.records(authority.records)==authority.records,
                  Set(authority.memories.map(\.id)).count==authority.memories.count,
                  Set(authority.originalSHA256BySourceID.keys)==Set(authority.memories.map(\.id)),
                  authority.memories.allSatisfy({memory in config.photos.contains{photo in
                      photo.sourceID==memory.id && photo.sha256==authority.originalSHA256BySourceID[memory.id]
                  }})else{throw PinDevelopmentError.sourceNotAllowed}
        }
        guard clockRepair==nil || (config.retainedClockRepair==true && memory==clockRepair?.memory) else{throw PinDevelopmentError.configuration}
        guard config.retainedEvidenceOnly != true || memory==nil else{throw PinDevelopmentError.sourceNotAllowed}
        if let groupContext {guard groupContext.schema != 3 || config.unitSourceRecovery==true else{throw PinDevelopmentError.configuration};guard (groupContext.isRetainedOCR ? config.retainedOCRGrouping==true:config.declaredImageProfileSHA256 != nil),let memory else{throw PinDevelopmentError.configuration};_=try groupContext.evidence(memory:memory)}
        if let memory {
            guard let originalSHA256,config.photos.contains(where:{$0.sha256==originalSHA256 && ($0.sourceID==nil || $0.sourceID==memory.id)})else{throw PinDevelopmentError.sourceNotAllowed}
        }
    }
    public func decide(_ task:ChoiceTask)async throws->DecisionReceipt {
        // Exact completed receipts are transport-free and can be checked in a
        // host preservation control. Ordinary dispatch keeps its app gate.
        guard completedSourceCheckpoint != nil || sourceStages?.replayOnly==true || PinFreshProductConfiguration.enabled else{throw PinDevelopmentError.disabled}
        try config.validate();try Task.checkCancellation();try await check()
        let unitRelation=config.resultUnits==true && [config.sourceOccurrencePolicy=="jointIdentityV3" ? SourceOccurrenceInterpreter.jointIdentityVersion:SourceOccurrenceInterpreter.version,InventoryOccurrenceInterpreter.version].contains(task.version) || (config.inventoryDocumentIdentityV1==true && config.resultUnits==true && task.version==InventoryDocumentIdentityInterpreter.version)
        if unitRelation {
            guard memory==nil,parentPublication==nil,authority?.unitEvidence != nil else{throw PinDevelopmentError.sourceNotAllowed}
        }else if memory==nil {
            guard config.compactQueryPolicy==nil else{throw PinDevelopmentError.sourceNotAllowed}
            guard config.resultUnits==true || config.permitsLegacyProductQueries else{throw PinFreshProductFailure.unresolvedEventUnits}
            guard (task.version==config.queryVersion || (config.resultUnits==true && parentPublication?.units != nil && task.version==ProductQuestionPlanner.displayedUnitContextVersion)),task.id==(config.productPlanning==true ? "pin-product-question":"pin-exhaustive-question"),
                  let state=try JSONSerialization.jsonObject(with:Data(task.state.utf8))as?[String:Any]else{throw PinDevelopmentError.sourceNotAllowed}
            let question:String?
            if config.productPlanning==true {
                let branches=state["branches"]as?[String:Any],inventory=branches?["inventory"]as?[String:Any],input=inventory?["state"]as?[String:Any]
                question=input?["question"]as?String
            }else{question=state["question"]as?String}
            guard let question,config.permitsQuestion(question)else{throw PinFreshProductFailure.unapprovedQuestion}
        }else{
            guard ([RetainedOCRSourceGrouper.version]+(config.unitSourceRecovery==true ? [RetainedOCRSourceGrouper.currentSourceVersion]:[])).contains(task.version)==(retainedGroupingInitialReceipt != nil) else{throw PinDevelopmentError.sourceNotAllowed}
            if config.retainedClockRepair==true {guard task.version==PrintedClockNotationInterpreter.version,clockRepair != nil else{throw PinDevelopmentError.sourceNotAllowed}}
            guard ((config.selectedSourceValues==true && task.version==SelectedSourceFieldValuesInterpreter.version) || [config.initialSourcePolicy.selected(for:memory!).usesCompactKeys && groupContext==nil && recordID==nil ? CompactQuestionKeys.version:config.sourceVersion,config.combinedSourceFields==true ? CombinedObservedTextFieldsInterpreter.denseVersion:config.selectedFieldPolicy == .denseSourceV2 ? ObservedTextFieldsInterpreter.denseVersion:ObservedTextFieldsInterpreter.version,config.selectedCompletionCapacity.taskVersion(TemporalMeaningInterpreter.version),config.printedStartVersion].contains(task.version) || (config.printedClockNotation==true && task.version==config.selectedCompletionCapacity.taskVersion(PrintedClockNotationInterpreter.version)) || (config.retainedOCRGrouping==true && (task.version==RetainedOCRSourceGrouper.version || (config.unitSourceRecovery==true && task.version==RetainedOCRSourceGrouper.currentSourceVersion))) || (config.declaredImageProfileSHA256 != nil && task.version==BoundedVisualSourceGrouper.contractVersion) || (config.temporalPolicy == .anchoredSpansV9 && [PrintedDateComponentsInterpreter.version,PrintedDateSupplementInterpreter.version].map{config.selectedCompletionCapacity.taskVersion($0)}.contains(task.version)) || (config.temporalRoleExplanations==true && task.version==config.explanationVersion))else{throw PinDevelopmentError.sourceNotAllowed}
        }
        let envelopeData=try encodedEnvelope(task)
        if let completedSourceCheckpoint {
            let receipt=try completedSourceCheckpoint.validatedReceipt(currentEnvelope:envelopeData,task:task)
            try await check();try Task.checkCancellation()
            return receipt // Exact terminal receipts only; this branch has no transport.
        }
        if let retainedFirstAssessment {
            let data=try Data(contentsOf:retainedFirstAssessment)
            guard data.count<=2_097_152 else{throw PinDevelopmentError.oversized}
            let checkpoint=try JSONDecoder().decode(PinFirstGroupAssessmentCheckpoint.self,from:data)
            let receipt=try checkpoint.validatedReceipt(currentEnvelope:envelopeData,task:task)
            try await check();try Task.checkCancellation()
            return receipt // No URLSession, reservation, dispatch or model retry.
        }
        let receive:@Sendable()async throws->DecisionReceipt={
            let data=try await transport(envelopeData,isSource:memory != nil)
            let receipt=try JSONDecoder().decode(DecisionReceipt.self,from:data)
            guard receipt.provider=="pin-native-subscription",receipt.model=="gpt-6.1-sol",receipt.answers.values.allSatisfy({$0.confidence==nil && $0.probabilities==nil})else{throw PinDevelopmentError.invalidReceipt}
            try receipt.validate(for:task);return receipt
        }
        let receipt:DecisionReceipt
        if let sourceStages{receipt=try await sourceStages.receipt(envelope:envelopeData,task:task,beforeSend:{
            try config.validate();try config.requireSourceReading()
            try await beforeSourceStageSend?()
            try config.validate();try await check();try Task.checkCancellation()
        },send:receive)}
        else{receipt=try await receive()}
        try await check();try Task.checkCancellation();return receipt
    }
    func verifiedCorrectionsForCompactQuery()throws->Bool {
        guard config.currentSavedInventoryV21==true,let authority,let witness=authority.nativeCorrectionWitness else{return false}
        guard config.nativeCorrectionPolicy==PinNativeCorrectionWitness.policy,let allowed=config.allowedNativeCorrectionSHA256,let requestID=questionRequestID else{throw PinFreshProductFailure.unapprovedCorrection}
        try witness.verify(authority:authority,session:config.session,requestID:requestID,token:config.token,allowedCorrections:allowed)
        return true
    }
    public func decide(_ task:CompactProductQueryTask)async throws->CompactProductQueryReceipt {
        guard PinFreshProductConfiguration.enabled else{throw PinDevelopmentError.disabled}
        try config.validate();try Task.checkCancellation();try await check()
        guard [CompactProductQueryPlanner.version,CompactProductQueryPlanner.linkedUnitVersion,CompactProductQueryPlanner.memberAwareVersion,CompactProductQueryPlanner.currentSavedInventoryVersion,CompactProductQueryPlanner.photoScopeInventoryVersion,PinPublicProductScope.currentSourceScopeQueryVersion,CompactProductQueryPlanner.calendarDefaultsVersion,CompactProductQueryPlanner.photoCalendarDefaultsVersion,CompactProductQueryPlanner.locationExtentVersion,CompactProductQueryPlanner.selectedUnitContinuationVersion].contains(task.version),config.effectiveCompactQueryVersion(hasPrevious:parentPublication != nil,hasVerifiedNativeCorrections:try verifiedCorrectionsForCompactQuery())==task.version,task.id=="pin-product-question",
              memory==nil,originalSHA256==nil,recordID==nil,recordRevision==nil,groupContext==nil,clockRepair==nil,initialAttempt==nil,retainedFirstAssessment==nil,completedSourceCheckpoint==nil,sourceStages==nil,
              authority?.unitEvidence != nil,questionRequestID != nil,
              let state=try JSONSerialization.jsonObject(with:Data(task.state.utf8))as?[String:Any],
              let prepared=state["preparedState"]as?[String:Any],let branches=prepared["branches"]as?[String:Any],let inventory=branches["inventory"]as?[String:Any],let input=inventory["state"]as?[String:Any],let question=input["question"]as?String else{throw PinDevelopmentError.sourceNotAllowed}
        guard config.permitsQuestion(question)else{throw PinFreshProductFailure.unapprovedQuestion}
        let data=try await transport(encodedEnvelope(task),isSource:false)
        let receipt=try JSONDecoder().decode(CompactProductQueryReceipt.self,from:data)
        guard receipt.provider=="pin-native-subscription",receipt.model=="gpt-6.1-sol"else{throw PinDevelopmentError.invalidReceipt}
        try receipt.validate(for:task);return receipt
    }
    func encodedEnvelope<Payload:Encodable>(_ task:Payload)throws->Data {
        let envelope=PinFreshProductEnvelope(session:config.session,task:task,memory:memory,originalSHA256:originalSHA256,recordID:recordID,recordRevision:recordRevision,contextZone:"America/Los_Angeles",temporalPolicy:config.temporalPolicy,planningPolicy:config.planningPolicy,temporalRoleExplanations:config.temporalRoleExplanations,sourcePreparationRecovery:config.sourcePreparationRecovery,declaredImageProfileSHA256:config.declaredImageProfileSHA256,groupContext:groupContext,retainedEvidenceOnly:config.retainedEvidenceOnly,printedClockNotation:config.printedClockNotation,retainedClockRepair:config.retainedClockRepair,clockRepair:clockRepair,productPlanning:config.productPlanning,authority:authority,parentPublication:parentPublication,questionRequestID:questionRequestID,productReconciliation:config.productReconciliation,productFactoryProfile:config.productFactoryProfile,localDenseOCR:config.localDenseOCR,sourceRegressions:config.sourceRegressions,combinedSourceFields:config.combinedSourceFields,selectedSourceValues:config.selectedSourceValues,sourceValueRecovery:config.sourceValueRecovery,sourceCompletionCapacity:config.sourceCompletionCapacity,resultUnits:config.resultUnits,questionAdmission:config.questionAdmission,sourceOccurrencePolicy:config.sourceOccurrencePolicy,unitSourceRecovery:config.unitSourceRecovery,retainedOCRGrouping:config.retainedOCRGrouping,retainedGroupingInitialReceipt:retainedGroupingInitialReceipt,sourceFieldPolicy:config.sourceFieldPolicy,sourceTaskPolicy:config.sourceTaskPolicy,sourceReceiptRecovery:config.sourceReceiptRecovery,sourceInputProfile:config.sourceInputProfile,sourceOutputProfile:config.sourceOutputProfile,compactQueryPolicy:memory==nil ? config.compactQueryPolicy:nil)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }
    /// A pinned, authenticated request with no task body reaches the host’s
    /// length check without reserving a model call or sending photo evidence.
    public static func verifyPairedConnection(_ config:PinFreshProductConfiguration,requiresSourceReading:Bool=false)async throws {
        try config.validate()
        if requiresSourceReading {try config.requireSourceReading()}
        try await checkPairedTransport(endpoint: config.endpoint, certificateSHA256: config.certificateSHA256, token: config.token, requiresSourceReading:requiresSourceReading)
        try config.validate()
    }

    private static func checkPairedTransport(endpoint: URL, certificateSHA256: String, token: String,requiresSourceReading:Bool=false) async throws {
        let tls=PinPinnedTLS(certificateSHA256)
        let session=URLSession(configuration:PinDevelopmentTransport.configuration(
            phoneTest:true,maximumDuration:3,waitForConnectivity:true),delegate:tls,delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        var request=URLRequest(url:endpoint)
        request.httpMethod="POST"
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if requiresSourceReading {request.setValue("source-reading-v1",forHTTPHeaderField:"X-Pin-Source-Readiness")}
        let clock = ContinuousClock()
        let started = clock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            let transportError = error as NSError
            let elapsed = (clock.now - started).components
            PinFreshProductAudit.recordTransport(requestData: Data(), channel: "paired-readiness",
                elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                status: nil, mime: nil, urlMatches: false,
                errorDomain: transportError.domain, errorCode: transportError.code)
            throw PinFreshProductFailure.pairedMacUnavailable
        }
        let http = response as? HTTPURLResponse
        let elapsed = (clock.now - started).components
        PinFreshProductAudit.recordTransport(requestData: Data(), channel: "paired-readiness",
            elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            status: http?.statusCode, mime: http?.mimeType, urlMatches: http?.url == endpoint,
            errorDomain: nil, errorCode: nil)
        guard http?.url == endpoint,
              http?.statusCode == 400, http?.mimeType == "application/json",
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            throw PinFreshProductFailure.pairedMacUnavailable
        }
        try validatePairedReadiness(body,requiresSourceReading:requiresSourceReading)
        try Task.checkCancellation()
    }
    /// Only the authenticated, pinned host can state its dispatch partition.
    /// A source capability never grants a new allocation or proves source truth.
    static func validatePairedReadiness(_ body:[String:String],requiresSourceReading:Bool)throws {
        var expected=["error":"invalid request envelope","dispatchState":"not-started"]
        if requiresSourceReading {
            guard let permission=body["sourceReading"],["enabled","disabled"].contains(permission) else {
                throw PinFreshProductFailure.pairedMacUnavailable
            }
            expected["sourceReading"]=permission
        }
        guard body==expected else{throw PinFreshProductFailure.pairedMacUnavailable}
        if requiresSourceReading,body["sourceReading"]=="disabled" {
            throw PinFreshProductFailure.sourceReadingNotAuthorized
        }
    }

    #if DEBUG && !targetEnvironment(simulator) && os(iOS)
    public static func runConnectionProbe(id: UUID) async throws {
        struct Probe: Decodable {
            let endpoint: URL
            let certificateSHA256: String
            let token: String
            let phoneTest: PinPhoneTestBinding
        }
        guard PinPublicProductScope.usesExistingPhotoIntake else { throw PinDevelopmentError.disabled }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stem = "fresh-network-probe-" + id.uuidString
        let file = documents.appendingPathComponent(stem + ".json")
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 4096 else { throw PinDevelopmentError.oversized }
        let probe = try JSONDecoder().decode(Probe.self, from: bytes)
        try PinDevelopmentDestination.validate(probe.endpoint, path: "/v1/pin-connectivity", phoneTest: probe.phoneTest)
        guard probe.phoneTest.expiresAt - probe.phoneTest.issuedAt <= 600,
              probe.certificateSHA256.utf8.count == 64,
              probe.certificateSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              (32...128).contains(probe.token.utf8.count),
              probe.token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { throw PinDevelopmentError.configuration }
        try await checkPairedTransport(endpoint: probe.endpoint, certificateSHA256: probe.certificateSHA256, token: probe.token)
    }
    #endif

    private func transport(_ envelopeData:Data,isSource:Bool)async throws->Data {
        var request=URLRequest(url:config.endpoint);request.httpMethod="POST";request.timeoutInterval=125
        request.setValue("Bearer "+config.token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=envelopeData
        if let expected=requiredEnvelopeSHA256 {guard SHA256.hash(data:request.httpBody!).map({String(format:"%02x",$0)}).joined()==expected else{throw PinDevelopmentError.sourceNotAllowed}}
        let limit=config.requestByteLimit(isSource:isSource)
        guard request.httpBody!.count<=limit else{throw PinFreshProductFailure.requestTooLarge(bytes:request.httpBody!.count,limit:limit)}
        if let initialAttempt {
            request.httpBody=try PinInitialSourceRecovery.body(request.httpBody!,file:initialAttempt,recover:recoverInitial)
            if recoverInitial {request.setValue(config.sourceReceiptRecovery,forHTTPHeaderField:"X-Pin-Source-Recovery")}
        }
        let tls=PinPinnedTLS(config.certificateSHA256),session=URLSession(configuration:PinDevelopmentTransport.configuration(phoneTest:config.phoneTest != nil,maximumDuration:125,waitForConnectivity:false),delegate:tls,delegateQueue:nil)
        defer{tls.endConnectionBudget();session.invalidateAndCancel()}
        tls.beginConnectionBudget(3,session:session)
        let started=Date()
        let bytes:URLSession.AsyncBytes,response:URLResponse
        do{(bytes,response)=try await session.bytes(for:request,delegate:tls)}
        catch {
            let e=error as NSError
            PinFreshProductAudit.recordTransport(requestData:request.httpBody ?? Data(),elapsed:Date().timeIntervalSince(started),status:nil,mime:nil,urlMatches:false,errorDomain:e.domain,errorCode:e.code)
            throw error
        }
        let observed=response as?HTTPURLResponse
        PinFreshProductAudit.recordTransport(requestData:request.httpBody ?? Data(),elapsed:Date().timeIntervalSince(started),status:observed?.statusCode,mime:observed?.mimeType,urlMatches:observed?.url==config.endpoint,errorDomain:nil,errorCode:nil)
        if recoverInitial,let http=response as?HTTPURLResponse,http.url==config.endpoint {
            if http.statusCode==202{throw PinFreshProductFailure.sourceStillRunning}
            if [404,409].contains(http.statusCode){throw PinFreshProductFailure.unfinishedSourceRead}
        }
        guard let http=response as?HTTPURLResponse,http.statusCode==200,http.url==config.endpoint,http.mimeType=="application/json"else{throw PinDevelopmentError.transport}
        var data=Data();for try await byte in bytes{try Task.checkCancellation();guard data.count<131072 else{throw PinDevelopmentError.oversized};data.append(byte)}
        try config.validate();try await check();try Task.checkCancellation()
        return data
    }

}

public enum PinFreshProductAudit {
    /// Local test observation only. View appearance is not a measured display
    /// frame, and these events never authorize or resume an operation.
    public static func recordLifecycle(stage:String,requestID:UUID?,epoch:Int,busy:Bool) {
        struct Event:Encodable {let at:Date;let stage:String;let requestID:UUID?;let epoch:Int;let busy:Bool;let processID:Int32}
        save(Event(at:Date(),stage:stage,requestID:requestID,epoch:epoch,busy:busy,processID:ProcessInfo.processInfo.processIdentifier))
    }
    public static func recordTransport(requestData:Data,channel:String="finite-choice",elapsed:Double,status:Int?,mime:String?,urlMatches:Bool,errorDomain:String?,errorCode:Int?) {
        struct Event:Encodable {let stage:String,requestSHA256:String,channel:String;let elapsed:Double;let status:Int?;let mime:String?;let urlMatches:Bool;let errorDomain:String?;let errorCode:Int?}
        save(Event(stage:"transportObserved",requestSHA256:SHA256.hash(data:requestData).map{String(format:"%02x",$0)}.joined(),channel:channel,elapsed:elapsed,status:status,mime:mime,urlMatches:urlMatches,errorDomain:errorDomain,errorCode:errorCode))
    }
    private struct UnitMember:Encodable {
        let item:AppointmentItem;let selection:String;let cancellation:String?
        let support:[PinSourceStatusEvidenceAnswer.Support];let sources:Set<PinCore.EvidenceSource>
        init(_ member:PinUnitQuestionMember){item=member.item;selection=member.selection;cancellation=member.cancellation;support=member.statusSupport;sources=member.sources}
    }
    private struct UnitRow:Encodable {
        let id:String;let membershipUncertain:Bool;let conflictingFields:Set<String>;let members:[UnitMember]
        init(_ row:PinUnitQuestionRow){id=row.id;membershipUncertain=row.membershipUncertain;conflictingFields=row.conflictingFields;members=row.members.map(UnitMember.init)}
    }
    /// Observational export only. This file never restores source or context
    /// authority and is not consumed by the runtime or semantic interpreter.
    public static func recordUnits(question:String,answer:PinUnitQuestionAnswer,parent:PinProductPublishedParent?) {
        struct Event:Encodable {
            let at:Date,question:String,stage:String,operation:String,resultUnit:String
            let parent:PinProductPublishedParent?;let rows:[UnitRow]
            let countLowerBound:Int,countUpperBound:Int,exactCount:Int?
            let identityResolved:Bool,requestedComplete:Bool,coverage:String
            let unresolved:[String:Set<String>],requestedEvidence:Set<String>,originalReceipt:DecisionReceipt
        }
        save(Event(at:Date(),question:question,stage:"unitPresented",operation:answer.operation,resultUnit:answer.resultUnit,parent:parent,rows:answer.rows.map(UnitRow.init),countLowerBound:answer.countLowerBound,countUpperBound:answer.countUpperBound,exactCount:answer.exactCount,identityResolved:answer.identityResolved,requestedComplete:answer.requestedAnswerComplete,coverage:answer.coverage.notice,unresolved:answer.unresolvedFieldsByUnit,requestedEvidence:answer.requestedSourceEvidence,originalReceipt:answer.receipt))
    }
    public static func recordUnitContextual(question:String,answer:PinUnitContextualAnswer,parent:PinProductPublishedParent) {
        struct Event:Encodable {
            let at:Date,question:String,stage:String,operation:String
            let parent:PinProductPublishedParent,selected:UnitRow,selectedOrdinal:Int
            let requestedEvidence:Set<String>,originalReceipt:DecisionReceipt
        }
        save(Event(at:Date(),question:question,stage:"unitContextualPresented",operation:answer.operation,parent:parent,selected:UnitRow(answer.selection.row),selectedOrdinal:answer.selection.ordinal,requestedEvidence:answer.requestedSourceEvidence,originalReceipt:answer.receipt))
    }
    public static func record(question:String,stage:String,rows:[AppointmentItem]=[],answer:PinExhaustiveQuestionAnswer?=nil,error:String?=nil,reconciliation:PinProductReconciliation?=nil) {
        guard PinFreshProductConfiguration.enabled else{return}
        struct Event:Encodable {let at:Date;let question:String;let stage:String;let rows:[AppointmentItem];let summary:String?;let coverage:String?;let requestedComplete:Bool?;let unresolved:[String:Set<String>]?;let error:String?;let sourceStatusEvidence:PinSourceStatusEvidenceAnswer?;let originalReceipt:DecisionReceipt?;let questionRequestID:UUID?;let reconciliation:PinProductReconciliation?}
        let event=Event(at:Date(),question:question,stage:stage,rows:rows,summary:answer?.summary,coverage:answer?.coverage.notice,requestedComplete:answer?.requestedAnswerComplete,unresolved:answer?.unresolvedDetails,error:error,sourceStatusEvidence:answer?.sourceStatusEvidence,originalReceipt:answer?.receipt,questionRequestID:answer?.requestID,reconciliation:reconciliation)
        save(event)
    }
    public static func recordContextual(question:String,stage:String,answer:PinRecordQuestionAnswer) {
        struct Event:Encodable {
            let at:Date;let question:String;let stage:String;let route:String
            let matched:[AppointmentItem];let unresolved:[AppointmentItem];let displayedRecordIDs:[String];let contextOrderedRecordIDs:[String]
            let location:String?;let comparison:[String:String];let clarification:String?
            let unresolvedDetails:[String:[String]];let selectedOrdinal:Int?;let originalReceipt:DecisionReceipt
        }
        save(Event(at:Date(),question:question,stage:stage,route:answer.route,matched:answer.matched,unresolved:answer.unresolved,displayedRecordIDs:(answer.matched+answer.unresolved).compactMap(\.canonicalRecordID),contextOrderedRecordIDs:answer.ordered.compactMap(\.canonicalRecordID),location:answer.location,comparison:answer.comparison,clarification:answer.clarification,unresolvedDetails:answer.unresolvedDetails,selectedOrdinal:answer.context?.selectedOrdinal,originalReceipt:answer.receipt))
    }
    public static func recordLinkedUnitContextual(question:String,answer:PinLinkedUnitContextualAnswer,parent:PinProductPublishedParent) {
        struct Event:Encodable {
            let at:Date,question:String,stage:String,operation:String
            let parent:PinProductPublishedParent,rows:[UnitRow],requestedDetails:Set<String>,requestedChanges:Set<String>,requestedEvidence:Set<String>
            let gaps:[String:[String]],allRequestedValuesEstablished:Bool,allSelectedMemberReadsComplete:Bool
            let originalReceipt:DecisionReceipt
        }
        let gaps=Dictionary(uniqueKeysWithValues:answer.rows.flatMap(\.gaps).reduce(into:[String:[String]]()){map,gap in map[gap.recordID,default:[]].append(gap.field)}.map{($0.key,$0.value.sorted())})
        save(Event(at:Date(),question:question,stage:"unitLinkedContextualPresented",operation:answer.operation,parent:parent,rows:answer.rows.map{UnitRow($0.selection.row)},requestedDetails:answer.requestedDetails,requestedChanges:answer.requestedChanges,requestedEvidence:answer.requestedSourceEvidence,gaps:gaps,allRequestedValuesEstablished:answer.allRequestedValuesEstablished,allSelectedMemberReadsComplete:answer.allSelectedMemberReadsComplete,originalReceipt:answer.receipt))
    }
    public static func recordNavigation(stage:String,parent:PinProductPublishedParent,source:PinCore.EvidenceSource?=nil,answerID:UUID?=nil) {
        struct Event:Encodable {let at:Date;let stage:String;let parent:PinProductPublishedParent;let source:PinCore.EvidenceSource?;let answerID:UUID?}
        save(Event(at:Date(),stage:stage,parent:parent,source:source,answerID:answerID))
    }
    private static func save<E:Encodable>(_ event:E) {
        guard PinFreshProductConfiguration.enabled else{return}
        do {
            let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("fresh-results")
            try PinPrivatePayloadWithdrawal.withWriteAccess {
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                try PinPrivatePayloadWithdrawal.write(encoder.encode(event),to:root.appendingPathComponent(String(Date().timeIntervalSince1970)+"-"+UUID().uuidString+".json"),options:.atomic)
            }
        }catch{ /* Observational export must never grant publication authority. */ }
    }
}


/// Simulator-only replay of one exact public request through the normal native
/// provider. Its host is a frozen read-only receipt server, never a model peer.
public enum PinFreshRetainedTransportControl {
    public static var enabled:Bool {
        #if DEBUG && targetEnvironment(simulator)
        return PinFreshProductConfiguration.enabled && ProcessInfo.processInfo.arguments.contains(where:{["--fresh-retained-transport-control","--fresh-retained-sequence-control"].contains($0)})
        #else
        return false
        #endif
    }
    public static func run()async {
        #if DEBUG && targetEnvironment(simulator)
        guard enabled else{return}
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let stem=ProcessInfo.processInfo.arguments.contains("--fresh-retained-sequence-control") ? "fresh-retained-sequence-control":"fresh-retained-transport-control"
        let result=docs.appendingPathComponent(stem+".result.json")
        guard !FileManager.default.fileExists(atPath:result.path)else{return}
        let began=Date()
        do {
            struct Input:Decodable {let file:String;let requestSHA256:String}
            struct Control:Decodable {let requestSHA256:String?;let requests:[Input]?}
            struct Envelope:Decodable {let session:UUID;let task:ChoiceTask;let authority:PinProductQuestionAuthority;let questionRequestID:UUID;let parentPublication:PinProductPublishedParent?}
            let control=try JSONDecoder().decode(Control.self,from:Data(contentsOf:docs.appendingPathComponent(stem+".json")))
            let inputs=control.requests ?? [Input(file:stem+".request.json",requestSHA256:control.requestSHA256 ?? "")]
            guard (1...2).contains(inputs.count),Set(inputs.map(\.file)).count==inputs.count else{throw PinDevelopmentError.configuration}
            let config=try PinFreshProductConfiguration.load()
            guard config.phoneTest==nil,config.endpoint.host=="127.0.0.1" else{throw PinDevelopmentError.sourceNotAllowed}
            var envelopes:[(Input,Envelope)]=[]
            for input in inputs {
                guard input.file.hasPrefix(stem),!input.file.contains("/"),input.file.hasSuffix(".json")else{throw PinDevelopmentError.configuration}
                let raw=try Data(contentsOf:docs.appendingPathComponent(input.file))
                guard raw.count<=1_048_576,SHA256.hash(data:raw).map({String(format:"%02x",$0)}).joined()==input.requestSHA256 else{throw PinDevelopmentError.configuration}
                let envelope=try JSONDecoder().decode(Envelope.self,from:raw)
                guard envelope.session==config.session,[SourceOccurrenceInterpreter.version,ProductQuestionPlanner.resultUnitsVersion].contains(envelope.task.version),
                      Set(envelope.authority.originalSHA256BySourceID.values)==Set(config.photos.map(\.sha256))else{throw PinDevelopmentError.sourceNotAllowed}
                envelopes.append((input,envelope))
            }
            try PinPrivatePayloadWithdrawal.write(Data("started".utf8),to:result,options:.atomic)
            var responses:[[String:Any]]=[]
            for(input,envelope)in envelopes {
                let start=Date(),provider=try PinFreshProductProvider(config:config,authority:envelope.authority,parentPublication:envelope.parentPublication,questionRequestID:envelope.questionRequestID,check:{})
                let receipt=try await provider.decide(envelope.task)
                let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
                responses.append(["requestSHA256":input.requestSHA256,"receiptSHA256":SHA256.hash(data:try encoder.encode(receipt)).map{String(format:"%02x",$0)}.joined(),"elapsedSeconds":Date().timeIntervalSince(start)])
            }
            let record:[String:Any]=["verdict":"PASS","responses":responses,"elapsedSeconds":Date().timeIntervalSince(began),"mode":"normal native providers; host forbids model dispatch; no result admission"]
            try PinPrivatePayloadWithdrawal.write(JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),to:result,options:.atomic)
        }catch {
            let e=error as NSError
            let record:[String:Any]=["verdict":"FAIL","errorType":String(describing:type(of:error)),"errorDomain":e.domain,"errorCode":e.code,"elapsedSeconds":Date().timeIntervalSince(began)]
            try? PinPrivatePayloadWithdrawal.write(JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),to:result,options:.atomic)
        }
        #endif
    }
}


/// Export platform-native prepared frames before dispatch. The host freezes and
/// qualifies these exact artifacts; it must never regenerate them on another OS.
public enum PinFreshNativeFramePreparation {
    static func directory(in documents:URL,fixtureManifestSHA256:String?)throws->URL {
        let root=documents.appendingPathComponent("fresh-native-frames-v2",isDirectory:true)
        guard let manifest=fixtureManifestSHA256 else{return root}
        guard manifest.utf8.count==64,manifest.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)})else{
            throw PinDevelopmentError.configuration
        }
        return root.appendingPathComponent(manifest,isDirectory:true)
    }

    private static var fixtureManifest:String? {
        PinPublicProductScope.requiresLimitedPhotoAccess ? PinPublicProductScope.declaredFixtureManifestSHA256 : nil
    }

    public static var enabled:Bool {
        #if DEBUG
        return PinFreshProductConfiguration.enabled && ProcessInfo.processInfo.arguments.contains("--fresh-native-frame-prepare")
        #else
        return false
        #endif
    }
    public static func restore(originalImageData:Data)throws->PreparedVisualFrame {
        guard PinFreshProductConfiguration.enabled else{throw PinDevelopmentError.disabled}
        struct Manifest:Decodable {let verdict:String;let frames:[String:Entry]}
        struct Entry:Decodable {let file:String,frameSHA256:String,artifactSHA256:String}
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let current=try directory(in:documents,fixtureManifestSHA256:fixtureManifest)
        // Existing installations may have a legacy flat export. Its original
        // and frame hashes must still match before it can be restored.
        let root=FileManager.default.fileExists(atPath:current.appendingPathComponent("RESULT.json").path)
            ? current : try directory(in:documents,fixtureManifestSHA256:nil)
        let original=VisualEvidenceRequest.hash(originalImageData),manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("RESULT.json")))
        guard manifest.verdict=="PASS",let entry=manifest.frames[original],entry.file==original+".json"else{throw PinDevelopmentError.sourceNotAllowed}
        let bytes=try Data(contentsOf:root.appendingPathComponent(entry.file))
        guard bytes.count<=14_000_000,VisualEvidenceRequest.hash(bytes)==entry.artifactSHA256 else{throw PinDevelopmentError.invalidReceipt}
        let frame=try PreparedVisualFrame.restoreTrustedHostArtifact(bytes,originalImageData:originalImageData)
        guard frame.preprocessing==VisualEvidenceRequest.frameVersionV2,frame.imageSHA256==entry.frameSHA256 else{throw PinDevelopmentError.invalidReceipt}
        return frame
    }
    #if DEBUG
    private static func canPrepare(in root: URL) -> Bool {
        let result = root.appendingPathComponent("RESULT.json")
        guard FileManager.default.fileExists(atPath: result.path) else { return true }
        struct FailedAttempt: Decodable { let verdict: String; let modelCalls: Int }
        guard let bytes = try? Data(contentsOf: result),
              let attempt = try? JSONDecoder().decode(FailedAttempt.self, from: bytes) else { return false }
        return attempt.verdict == "FAIL" && attempt.modelCalls == 0
    }

    static func publish(_ files:[String:Data], to root:URL) throws {
        let manager=FileManager.default
        let pending=root.appendingPathExtension("pending")
        try PinPrivatePayloadWithdrawal.withWriteAccess {
            guard canPrepare(in: root) else { return }
            // An interrupted export or older partial directory has no result
            // and cannot be read by the provider.
            for directory in [pending,root] where manager.fileExists(atPath:directory.path) {
                try manager.removeItem(at:directory)
            }
            try manager.createDirectory(at:pending,withIntermediateDirectories:true)
            defer {try? manager.removeItem(at:pending)}
            for (name,bytes) in files {
                try bytes.write(to:pending.appendingPathComponent(name),options:.atomic)
            }
            try manager.moveItem(at:pending,to:root)
        }
    }
    #endif

    public static func run() {
        #if DEBUG
        guard enabled else{return}
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        guard let root=try? directory(in:docs,fixtureManifestSHA256:fixtureManifest) else{return}
        guard canPrepare(in: root) else { return }
        do {
            let config=try PinFreshProductConfiguration.load()
            guard config.pixelBoundImageFrameV2==true,config.unitSourceRecovery==true,config.photos.count<=2 else{throw PinDevelopmentError.configuration}
            var artifacts:[(String,Data,String)]=[]
            for photo in config.photos {
                let original=try Data(contentsOf:docs.appendingPathComponent(photo.file))
                guard original.count<=10_000_000,VisualEvidenceRequest.hash(original)==photo.sha256 else{throw PinDevelopmentError.sourceNotAllowed}
                let frame=try PreparedVisualFrame.prepare(originalImageData:original,policy:.pixelBound2400kV2),artifact=try frame.encodedArtifact()
                guard try PreparedVisualFrame.restoreTrustedHostArtifact(artifact,originalImageData:original)==frame else{throw PinDevelopmentError.invalidReceipt}
                artifacts.append((photo.sha256,artifact,frame.imageSHA256))
            }
            var files:[String:Data]=[:], manifest:[String:[String:String]]=[:]
            for(original,artifact,frame)in artifacts {
                let file=original+".json";files[file]=artifact
                manifest[original]=["file":file,"frameSHA256":frame,"artifactSHA256":VisualEvidenceRequest.hash(artifact)]
            }
            files["RESULT.json"]=try JSONSerialization.data(withJSONObject:["verdict":"PASS","modelCalls":0,"frames":manifest],options:[.sortedKeys])
            try publish(files,to:root)
        }catch {
            if let result=try? JSONSerialization.data(withJSONObject:["verdict":"FAIL","errorType":String(describing:type(of:error)),"modelCalls":0],options:[.sortedKeys]) {
                try? publish(["RESULT.json":result],to:root)
            }
        }
        #endif
    }
}
