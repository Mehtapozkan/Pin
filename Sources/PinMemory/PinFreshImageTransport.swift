import Foundation
import CryptoKit
import PinCore

/// Existing pinned local peer only; native source/frame/read authority stays in
/// PinAppointmentProjectionCache and the PhotoLibrary CAS before and after it.
public enum PinFreshImageTransport {
    public static func send(_ input:PinDeclaredImageInput,config:PinFreshProductConfiguration,check:@Sendable()async throws->Void)async throws->Data {
        guard config.retainedEvidenceOnly != true,config.retainedClockRepair != true,PinFreshProductConfiguration.enabled,config.declaredImageProfileSHA256==config.selectedImageProfileSHA256,input.profileSHA256==config.declaredImageProfileSHA256,
              config.photos.contains(where:{$0.sha256==input.originalSHA256}) else{throw PinDevelopmentError.disabled}
        try config.validate();try Task.checkCancellation();try await check()
        struct Envelope:Encodable {
            let kind:String;let session:UUID;let profileSHA256:String;let originalSHA256:String
            let requestSHA256:String;let frameSHA256:String;let requestData:Data;let frameData:Data
        }
        let envelope=Envelope(kind:"declaredImage",session:config.session,profileSHA256:input.profileSHA256,originalSHA256:input.originalSHA256,requestSHA256:input.requestSHA256,frameSHA256:input.frameSHA256,requestData:input.requestData,frameData:input.frameData)
        var request=URLRequest(url:config.endpoint);request.httpMethod="POST";request.timeoutInterval=125
        request.setValue(input.profileSHA256,forHTTPHeaderField:"X-Pin-Image-Profile")
        request.setValue("Bearer "+config.token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONEncoder().encode(envelope)
        guard request.httpBody!.count<=2_097_152 else{throw PinDevelopmentError.oversized}
        let tls=PinPinnedTLS(config.certificateSHA256),session=URLSession(configuration:PinDevelopmentTransport.configuration(phoneTest:false,maximumDuration:125),delegate:tls,delegateQueue:nil)
        defer{session.invalidateAndCancel()}
        let started=Date()
        let bytes:URLSession.AsyncBytes,response:URLResponse
        do{(bytes,response)=try await session.bytes(for:request,delegate:tls)}
        catch {
            let e=error as NSError
            PinFreshProductAudit.recordTransport(requestData:request.httpBody ?? Data(),channel:"declared-image",elapsed:Date().timeIntervalSince(started),status:nil,mime:nil,urlMatches:false,errorDomain:e.domain,errorCode:e.code)
            throw error
        }
        let observed=response as?HTTPURLResponse
        PinFreshProductAudit.recordTransport(requestData:request.httpBody ?? Data(),channel:"declared-image",elapsed:Date().timeIntervalSince(started),status:observed?.statusCode,mime:observed?.mimeType,urlMatches:observed?.url==config.endpoint,errorDomain:nil,errorCode:nil)
        guard let http=response as?HTTPURLResponse,http.statusCode==200,http.url==config.endpoint,http.mimeType=="application/json"else{throw PinDevelopmentError.transport}
        var data=Data();for try await byte in bytes{try Task.checkCancellation();guard data.count<262144 else{throw PinDevelopmentError.oversized};data.append(byte)}
        try config.validate();try Task.checkCancellation();try await check();return data
    }
}
