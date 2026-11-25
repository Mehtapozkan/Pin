import Foundation

/// A short-lived permission to contact one paired Mac for fictional test tasks.
/// This is a development pairing, never subscription authentication or consent
/// to process the owner's private library. Source/task allowlists remain mandatory.
public struct PinPhoneTestBinding:Codable,Sendable {
    public let purpose:String
    public let bundleID:String
    public let issuedAt:Double
    public let expiresAt:Double
}

enum PinDevelopmentDestination {
    static func isPrivateIPv4(_ host:String)->Bool {
        let parts=host.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==4 else{return false}
        let bytes=parts.compactMap{part->Int? in
            guard let n=Int(part),(0...255).contains(n),String(n)==part else{return nil};return n
        }
        guard bytes.count==4,bytes[3]>0,bytes[3]<255 else{return false}
        return bytes[0]==10 || (bytes[0]==172 && (16...31).contains(bytes[1])) || (bytes[0]==192 && bytes[1]==168)
    }
    /// Host identity is injected only for pure validation tests. The network
    /// providers always use the running application's real bundle and opt-in.
    static func validate(_ endpoint:URL,path:String,phoneTest:PinPhoneTestBinding?,now:Date=Date(),bundleID:String?=Bundle.main.bundleIdentifier,optIn:Bool=Bundle.main.object(forInfoDictionaryKey:"PinPairedPhoneTest") as? Bool == true)throws {
        guard endpoint.scheme=="https",let host=endpoint.host,let port=endpoint.port,(1...65535).contains(port),endpoint.path==path,
              endpoint.user==nil,endpoint.password==nil,endpoint.query==nil,endpoint.fragment==nil else{throw PinDevelopmentError.configuration}
        guard let phoneTest else {
            guard host=="127.0.0.1" else{throw PinDevelopmentError.configuration};return
        }
        #if DEBUG
        let t=now.timeIntervalSince1970
        guard optIn,["app.pin.phonetest",PinPublicProductScope.isolatedPhoneBundleID].contains(bundleID ?? ""),phoneTest.bundleID==bundleID,phoneTest.purpose=="fictional-appointments-v1",
              phoneTest.issuedAt.isFinite,phoneTest.expiresAt.isFinite,phoneTest.issuedAt<=t+60,
              phoneTest.expiresAt>t,phoneTest.expiresAt>phoneTest.issuedAt,phoneTest.expiresAt-phoneTest.issuedAt<=86400,
              isPrivateIPv4(host) else{throw PinDevelopmentError.configuration}
        #else
        throw PinDevelopmentError.disabled
        #endif
    }
}
