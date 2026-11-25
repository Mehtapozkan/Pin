import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// A bounded local-LAN reconstruction input for the exact fictional phone
/// profile. These native facts never become a Mac-owned store or model prompt.
public struct PinPhoneQuestionAuthority:Codable,Sendable {
    public let schema:Int
    public let fixtureManifestSHA256:String
    public let memories:[PhotoMemory]
    public let records:[AppointmentItem]
    public let sdkMemory:Data
    public var witnesses:[PinFixtureSourceWitness]? = nil
    struct SavedSDK:Decodable {
        let scope:MemoryScope
        let rows:[String:StoredMemory]
        let sourceChanges:[String:SourceRecordChange]?
    }
    public func validate(session:PinPhoneQuestionSession,sourceIDs:Set<String>,manifestSHA256:String)throws {
        try session.validate()
        if session.authorityPolicy=="native-sealed-fixture-envelope-v2" {
            guard let sealed=session.sealedSession,schema==2,fixtureManifestSHA256==manifestSHA256,manifestSHA256==sealed.fixtureManifestSHA256,
                  memories.count<=4,records.count<=3,sdkMemory.count<=262144,!sdkMemory.isEmpty,
                  Set(memories.map(\.id)).count==memories.count,Set(memories.map(\.id)).isSubset(of:sourceIDs),
                  let witnesses,witnesses.count==memories.count,Set(witnesses.map{$0.source.id}).count==memories.count else{throw PinDevelopmentError.sourceNotAllowed}
            for memory in memories{guard let w=witnesses.first(where:{$0.source.id==memory.id})else{throw PinDevelopmentError.sourceNotAllowed};try sealed.validate(w,memory:memory)}
            try validateNativeRows();return
        }
        guard session.authorityPolicy=="native-fixture-envelope-v1",let textHashes=session.allowedTextSHA256,
              schema==1,fixtureManifestSHA256==manifestSHA256,manifestSHA256.count==64,
              memories.count<=3,records.count<=3,sdkMemory.count<=262144,!sdkMemory.isEmpty,
              Set(memories.map(\.id)).count==memories.count,Set(memories.map(\.id)).isSubset(of:sourceIDs)else{throw PinDevelopmentError.sourceNotAllowed}
        for memory in memories {
            let request=try PinDevelopmentSourceReader.request(memory)
            guard textHashes.contains(try PinDevelopmentSourceReader.textDigest(request.lines.map(\.text)))else{throw PinDevelopmentError.sourceNotAllowed}
        }
        let scope=MemoryScope(ownerID:"local-photo-owner",namespace:"pin-appointments-v1")
        for record in records {
            let p=try PinCanonicalMapping.projection(record,scope:scope),object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p.appointment))
            guard session.allowedAppointmentSHA256.contains(try PinPhoneQuestionSession.digest(object))else{throw PinDevelopmentError.sourceNotAllowed}
            if let old=PinCapturedAppointmentRevision.previousRow(of:record){let previous=try PinCanonicalMapping.projection(old,scope:scope),value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(previous.appointment));guard session.allowedAppointmentSHA256.contains(try PinPhoneQuestionSession.digest(value))else{throw PinDevelopmentError.sourceNotAllowed}}
        }
        try validateNativeRows()
    }
    private func validateNativeRows()throws {
        let scope=MemoryScope(ownerID:"local-photo-owner",namespace:"pin-appointments-v1")
        var expected:[String:MemoryProjection]=[:]
        for record in records {
            guard let id=record.canonicalRecordID,!record.dismissed,expected[id]==nil,
                  Set((record.allSources+(record.previousEvidence?.sources ?? [])).map(\.id)).isSubset(of:Set(memories.map(\.id)))else{throw PinDevelopmentError.sourceNotAllowed}
            let projection=try PinCanonicalMapping.projection(record,scope:scope)
            expected[id]=projection
        }
        let file=try JSONDecoder().decode(SavedSDK.self,from:sdkMemory)
        guard file.scope==scope,Set(file.rows.keys)==Set(expected.keys),file.rows.allSatisfy({expected[$0.key]==$0.value.projection})else{throw PinDevelopmentError.sourceNotAllowed}
        for change in (file.sourceChanges ?? [:]).values {
            guard let record=records.first(where:{$0.canonicalRecordID==change.recordID}),let previous=PinCapturedAppointmentRevision.previousRow(of:record),
                  change.current==expected[change.recordID],change.previous == (try PinCanonicalMapping.projection(previous,scope:scope))else{throw PinDevelopmentError.sourceNotAllowed}
        }
    }
}
