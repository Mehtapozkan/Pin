import Foundation
import PinCore

/// Candidate imported IDs for an OS photo-access check. This is neither a
/// provider configuration nor permission to import, read pixels or dispatch.
public struct PinLocalFixtureAccess: Sendable {
    private struct Manifest:Decodable {let photos:[Photo]}
    private struct Photo:Decodable,Sendable {let id:String;let file:String;let sha256:String;let sourceID:String?}
    private struct State:Decodable {let importing:Bool;let ids:[String:String]}
    private let photos:[Photo]

    public init(configurationData:Data,signedManifestSHA256:String)throws {
        guard configurationData.count<=16384,signedManifestSHA256.count==64,signedManifestSHA256.allSatisfy(\.isHexDigit)else{throw PinDevelopmentError.configuration}
        let value=try JSONDecoder().decode(Manifest.self,from:configurationData)
        guard (1...4).contains(value.photos.count),Set(value.photos.map(\.sha256)).count==value.photos.count,
              value.photos.allSatisfy({!$0.id.isEmpty && $0.id.allSatisfy({$0.isLetter || $0.isNumber}) && $0.file=="photos/"+$0.id+".jpg" && $0.sha256.count==64 && $0.sha256.allSatisfy(\.isHexDigit)}),
              PinPublicProductScope.fixtureManifestIdentity(value.photos.map(\.sha256))==signedManifestSHA256 else{throw PinDevelopmentError.sourceNotAllowed}
        photos=value.photos
    }

    public func existingProcessingScope()throws->PinNativePhotoProcessingScope {
        let ids=photos.compactMap(\.sourceID)
        guard ids.count==photos.count,Set(ids).count==ids.count else{throw PinDevelopmentError.sourceNotAllowed}
        return try PinNativePhotoProcessingScope(sourceIDs:Set(ids))
    }

    public func importedIDs(stateData:Data)throws->Set<String> {
        guard stateData.count<=16384 else{throw PinDevelopmentError.oversized}
        let state=try JSONDecoder().decode(State.self,from:stateData)
        guard !state.importing,Set(state.ids.keys)==Set(photos.map(\.sha256)),
              Set(state.ids.values).count==photos.count,
              state.ids.values.allSatisfy({!$0.isEmpty && $0.utf8.count<=256})else{throw PinDevelopmentError.sourceNotAllowed}
        return Set(state.ids.values)
    }
}

public enum PinPhotoAccessReconciliation {
    public static func canReuseScan(force:Bool,sameSources:Bool,indexing:Bool,scanCompleted:Bool,fullyReconciled:Bool,protectedDataAvailable:Bool,accessReady:Bool)->Bool {
        !force && sameSources && (fullyReconciled || !protectedDataAvailable) &&
        (indexing || (scanCompleted && (accessReady || !protectedDataAvailable)))
    }
}


/// Local processing consent, separate from PhotoKit access and native indexing.
/// IDs choose existing current observations; they never establish access,
/// fingerprints, revisions, source facts, or permission for different pixels.
public struct PinNativePhotoProcessingScope:Sendable {
    public let sourceIDs:Set<String>
    public init(sourceIDs:Set<String>)throws {
        guard !sourceIDs.isEmpty,sourceIDs.count<=4,
              sourceIDs.allSatisfy({!$0.isEmpty && $0.utf8.count<=256})else{throw PinDevelopmentError.sourceNotAllowed}
        self.sourceIDs=sourceIDs
    }
    public func memories(_ values:[PhotoMemory])->[PhotoMemory] {values.filter{sourceIDs.contains($0.id)}}
    public func records(_ values:[AppointmentItem])->[AppointmentItem] {
        values.filter{row in
            let sources=row.allSources+(row.previousEvidence?.sources ?? [])
            return !sources.isEmpty && sources.allSatisfy{sourceIDs.contains($0.id)}
        }
    }
}
