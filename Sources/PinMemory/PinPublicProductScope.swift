import Foundation
import CryptoKit

/// Explicit Debug-only public-fixture route. The normal app and the existing
/// fictional phone test retain their original storage and source scope.
public enum PinPublicProductScope {
    /// Separate container for fresh-intake acceptance; never replaces Pin Test.
    public static let isolatedPhoneBundleID="app.pin.freshintaketest"
    public static var requiresLimitedPhotoAccess:Bool {
        requiresLimitedPhotoAccess(bundleID:Bundle.main.bundleIdentifier)
    }
    static func requiresLimitedPhotoAccess(bundleID:String?)->Bool {
        #if DEBUG
        return bundleID == isolatedPhoneBundleID || bundleID == PinSavedContentPhoneProfile.bundleID
        #else
        return false
        #endif
    }
    public static let selectedUnitContinuationSDKProfile="ibrain-r3-v51-selected-unit-continuation-v1-opt-in"
    public static let selectedUnitContinuationSDKIdentitySHA256="192ad3a79dabbbf77945d22071249b77192c7a6b73dd3e37c95fcb00388e90b8"
    public static let savedLocationExtentSDKProfile="ibrain-r3-v50-saved-location-extent-v1-opt-in"
    public static let savedLocationExtentSDKIdentitySHA256="74f3dc03a4e74998442df25f6944f68dfe6b04169dfec42a422b72a367fdb016"
    public static let documentIdentitySDKProfile="ibrain-r3-v49-inventory-document-identity-v1-opt-in"
    public static let documentIdentitySDKIdentitySHA256="360d8494a1dd225bcc5fbb503b7d3488e240ddc97af472ada0142fa153701341"
    public static let photoCalendarDefaultsSDKProfile="ibrain-r3-v48-photo-calendar-composition-v1-opt-in"
    public static let photoCalendarDefaultsSDKIdentitySHA256="ab404c8966b39f74b5ea94bf97a25f35098ddf8d0ccfc5a6141a15f1cd7237e8"
    public static let calendarDefaultsSDKProfile="ibrain-r3-v47-calendar-product-defaults-v1-opt-in"
    public static let calendarDefaultsSDKIdentitySHA256="998d07e978c6493f9e73b428b4218834d10dce0cd707d767c3bfb941a6e81015"
    public static let sourceDocumentListSDKProfile="ibrain-r3-v46-source-document-list-assessment-v1-opt-in"
    public static let sourceDocumentListSDKIdentitySHA256="fd430c3c7d06e1c7b0011d19ce49cb944d2c701d49e854a08b81df7a38fb463b"
    public static let currentSourceScopeQueryVersion="photo-product-query-compact-v2.3-current-source-scope"
    public static let currentSourceScopeSDKProfile="ibrain-r3-v45-current-source-scope-v2.3-opt-in"
    public static let currentSourceScopeSDKIdentitySHA256="80e201b0f3dd5629178ae59927ee704ecc9f5285f74464ce52527ec7d8407d83"
    public static let photoScopeSDKProfile="ibrain-r3-v44-proven-nonmatch-unit-filter-v1"
    public static let photoScopeSDKIdentitySHA256="bbbefaf2d8c195181781908418f16b66adc02ac27d2ef4459fa6e6080f0c36f3"
    public static let selectedValuesSDKProfile="ibrain-r3-v42-selected-source-field-values-v1-opt-in"
    public static let selectedValuesSDKIdentitySHA256="e741d61b5e1a4d7fae37336386c8940079471ef7b73955655b053be8b0681539"
    public static let memberCompactQuerySDKProfile="ibrain-r3-v39-current-saved-inventory-v2.1-opt-in"
    public static let memberCompactQuerySDKIdentitySHA256="2bbda018014781b4c4c961e8ee8c6d458bd304d483c85bc75047e4c34f58ca78"
    public static let linkedCompactQuerySDKProfile="ibrain-r3-v36-compact-linked-unit-context-v2"
    public static let linkedCompactQuerySDKIdentitySHA256="03209be0357388c323b00216715ff95b34c8e3d800d697254dea18b9ebdf3ca1"
    public static let compactQuerySDKProfile="ibrain-r3-v31-compact-product-query-v1"
    public static let compactQuerySDKIdentitySHA256="820fb19c8ec0487f1befe24a0eae1c3e22c28420c238e0cda31be4f003145e48"
    public static let jointOccurrenceSDKProfile = "ibrain-r3-v30-joint-occurrence-proof-v1"
    public static let jointOccurrenceSDKIdentitySHA256 = "4e8a911888bfca36743679f7940c3460a1512fb33682b7b01315aafd457ee8c7"
    public static let unitRecoveryFactoryProfile = "native-product-units-v6-source-recovery"
    public static let unitRecoverySDKProfile = "ibrain-r3-v28-2-revised-ocr-grouping-legacy-v1"
    public static let unitRecoverySDKIdentitySHA256 = "4d5b86fc31b859da5542efb26965709220c694cc65622e3b0a13da6e7a68c07d"
    public static let unitFactoryProfile = "native-product-units-v5"
    public static let unitSDKProfile = "ibrain-r3-v27-unit-displayed-context-replica-v1"
    public static let unitSDKIdentitySHA256 = "20371e44c6f43cee87baf045698397be5c44f1fedbe5ccd1311e0569fb17f398"
    public static let profile = "public-photo-product-v1"
    public static let sdkProfile = "ibrain-r3-v13-product-plan-local-dense-v1"
    public static let sdkIdentitySHA256 = "8df5a43c747ba190bd8b62fbc299438592ba2635a720e2be3d45e36108a38234"
    public static let compactSDKProfile = "ibrain-r3-v14-product-plan-local-dense-compact-keys-v1"
    public static let compactSDKIdentitySHA256 = "66f8f44149d258a3284ed3acf7cefc43213cf05ff0383a3bc5ea9ff692500f12"
    public static let denseFieldsSDKProfile = "ibrain-r3-v15-product-plan-local-dense-compact-fields-v2"
    public static let denseFieldsSDKIdentitySHA256 = "ed561f5a3aed73363862331865629f010facdbccc8088dcc5274566f6707ca82"
    public static let retainedGroupingSDKProfile = "pin-r3-retained-ocr-dense-fields-v1"
    public static let retainedGroupingSDKIdentitySHA256 = "d97c8526165c37c99dfa2b6300a9a4d8d03574c75275b0ee7de6254024fe3ffa"
    public static let sharedCapacitySDKProfile = "ibrain-r3-v17-product-plan-local-dense-completion-v1"
    public static let sharedCapacitySDKIdentitySHA256 = "cd21f897776c3df4830fea2a5c29a0a874b947e6f8c2b5ea814c7744bd6f03dd"
    public static let combinedFieldsSDKProfile = "ibrain-r3-v23-temporal-pattern-reuse-v1"
    public static let combinedFieldsSDKIdentitySHA256 = "e7012b9ca9299d29cba79a127d3dab719005a6b2f31e7e50a0d7ef49473e5e51"
    public static let separatedDateSDKProfile = "ibrain-r3-v18-product-plan-local-dense-separated-date-v1"
    public static let separatedDateSDKIdentitySHA256 = "5cb1beef089e862d0891cfcc8e827bafe0043160aa92803f0081d3feb1ab9d69"
    public static let factoryProfile = "native-product-reread-v4-bounded-source"
    /// Explicit isolated Simulator consumer over already-indexed PhotoKit IDs.
    /// This does not import fixtures or narrow the native photo catalogue.
    public static var usesExistingPhotoIntake:Bool {
        #if DEBUG && targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier=="app.pin.intakecandidate" &&
            Bundle.main.object(forInfoDictionaryKey:"PinExistingPhotoIntake")as?Bool==true &&
            declaredFixtureManifestSHA256 != nil &&
            ProcessInfo.processInfo.arguments.contains("--fresh-product")
        #elseif DEBUG
        return isPhoneEnabled && Bundle.main.bundleIdentifier==isolatedPhoneBundleID &&
            Bundle.main.object(forInfoDictionaryKey:"PinExistingPhotoIntake")as?Bool==true &&
            declaredFixtureManifestSHA256 != nil
        #else
        return false
        #endif
    }
    public static var isPhoneEnabled:Bool {
        #if DEBUG && !targetEnvironment(simulator)
        return permitsPhoneProfile(bundleID:Bundle.main.bundleIdentifier,
            paired:Bundle.main.object(forInfoDictionaryKey:"PinPairedPhoneTest") as? Bool == true,
            profile:Bundle.main.object(forInfoDictionaryKey:"PinPublicProductProfile") as? String,
            sdkIdentity:Bundle.main.object(forInfoDictionaryKey:"PinProductSDKIdentitySHA256") as? String,
            factory:Bundle.main.object(forInfoDictionaryKey:"PinProductFactoryProfile") as? String)
        #else
        return false
        #endif
    }
    /// This exact metadata gate is shared with controls using the staged app's
    /// Info.plist, so a new SDK profile cannot silently fall into old storage.
    static func permitsPhoneProfile(bundleID:String?,paired:Bool,profile:String?,sdkIdentity:String?,factory:String?)->Bool {
        #if DEBUG
        if bundleID==isolatedPhoneBundleID {
            return [selectedUnitContinuationSDKIdentitySHA256,savedLocationExtentSDKIdentitySHA256,documentIdentitySDKIdentitySHA256,photoCalendarDefaultsSDKIdentitySHA256,calendarDefaultsSDKIdentitySHA256,sourceDocumentListSDKIdentitySHA256,selectedValuesSDKIdentitySHA256,photoScopeSDKIdentitySHA256,currentSourceScopeSDKIdentitySHA256].contains(sdkIdentity ?? "") && factory==unitRecoveryFactoryProfile &&
                permitsPhone(bundleID:bundleID,paired:paired,profile:profile)
        }
        return [currentSourceScopeSDKIdentitySHA256,photoScopeSDKIdentitySHA256,selectedValuesSDKIdentitySHA256,memberCompactQuerySDKIdentitySHA256,linkedCompactQuerySDKIdentitySHA256,compactQuerySDKIdentitySHA256,jointOccurrenceSDKIdentitySHA256,unitRecoverySDKIdentitySHA256,unitSDKIdentitySHA256,sdkIdentitySHA256,compactSDKIdentitySHA256,denseFieldsSDKIdentitySHA256,retainedGroupingSDKIdentitySHA256,sharedCapacitySDKIdentitySHA256,separatedDateSDKIdentitySHA256,combinedFieldsSDKIdentitySHA256].contains(sdkIdentity ?? "") && [factoryProfile,unitFactoryProfile,unitRecoveryFactoryProfile].contains(factory ?? "") && permitsPhone(bundleID:bundleID,paired:paired,profile:profile)
        #else
        return false
        #endif
    }
    static func permitsPhone(bundleID:String?,paired:Bool,profile:String?)->Bool {
        #if DEBUG
        return ["app.pin.phonetest",isolatedPhoneBundleID].contains(bundleID ?? "") && paired && profile==Self.profile
        #else
        return false
        #endif
    }
    /// A single native authority per active fixture scope. Keeping development
    /// fixtures in their own directory leaves existing phone records intact.
    public static var declaredFixtureManifestSHA256:String? {Bundle.main.object(forInfoDictionaryKey:"PinPublicFixtureManifestSHA256")as?String}
    public static func fixtureManifestIdentity(_ hashes:[String])->String {SHA256.hash(data:Data(hashes.sorted().joined(separator:"\n").utf8)).map{String(format:"%02x",$0)}.joined()}
    private static func safeFixtureKey(_ value:String)->String {(value.count==64 && value.allSatisfy(\.isHexDigit)) ? value:"invalid"}
    public static func configurationFileName(fixtureManifestSHA256:String?=declaredFixtureManifestSHA256)->String {
        fixtureManifestSHA256.map{"fresh-product-"+safeFixtureKey($0)+".json"} ?? "fresh-product.json"
    }
    public static func photoStateFileName(fixtureManifestSHA256:String?=declaredFixtureManifestSHA256)->String {
        fixtureManifestSHA256.map{"fresh-product-photo-state-"+safeFixtureKey($0)+".json"} ?? "fresh-product-photo-state.json"
    }
    public static func applicationDirectory(_ base:URL,publicPhoneFixture:Bool=isPhoneEnabled,fixtureManifestSHA256:String?=declaredFixtureManifestSHA256)->URL {
        let suffix=publicPhoneFixture ? fixtureManifestSHA256.map{"/"+safeFixtureKey($0)} ?? "":""
        return base.appendingPathComponent(publicPhoneFixture ? "Pin/public-photo-product-v1"+suffix:"Pin",isDirectory:true)
    }
}
