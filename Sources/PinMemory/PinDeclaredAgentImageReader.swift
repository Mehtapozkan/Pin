import Foundation
import IBrainVision

/// Local peer envelope. Native identity/binding data is never model prompt text.
public struct PinDeclaredImageInput:Sendable {
    public let requestData:Data
    public let frameData:Data
    public let requestSHA256:String
    public let frameSHA256:String
    public let originalSHA256:String
    public let profileSHA256:String
}

/// Opt-in transport adapter only. No dispatch implementation or app route is
/// installed here. The caller retains current-source/image/read authority.
public struct PinDeclaredAgentImageReader:VisualEvidenceReader {
    public static let profileSHA256="d6c8c89501b2fddbc94df5aed43901ca5887559aaa51008afeb226afd527d26a"
    public static let runtimeProfileSHA256="9568409edbdb94964bbdb2a273908ec90904746083d3a6d309a66d11a37a1753"
    public static let pixelBoundProfileSHA256="a7d5ea707192b180f1e13b8f9ae9d552196920ad54b144523159f0a12ffafd82"
    public static let gateVersion="declared-image-trace-v2"
    public typealias Transport=@Sendable(PinDeclaredImageInput)async throws->Data
    private let allowed:Set<String>
    private let transport:Transport
    private let selectedProfile:String
    public init(authorizedPublicOriginals:Set<String>,profileSHA256:String=Self.profileSHA256,transport:@escaping Transport)throws {
        guard !authorizedPublicOriginals.isEmpty,authorizedPublicOriginals.count<=2,
              authorizedPublicOriginals.allSatisfy({$0.count==64 && $0.allSatisfy{"0123456789abcdef".contains($0)}}) else{throw PinDevelopmentError.configuration}
        guard [Self.profileSHA256,Self.runtimeProfileSHA256,Self.pixelBoundProfileSHA256].contains(profileSHA256)else{throw PinDevelopmentError.configuration}
        self.allowed=authorizedPublicOriginals;self.transport=transport;self.selectedProfile=profileSHA256
    }
    public func read(_ request:VisualEvidenceRequest)async throws->VisualEvidenceReceipt {
        try Task.checkCancellation();try request.validate()
        guard request.readingPolicy == .verbatimFieldsV2,request.sourceImageBinding != nil else{throw PinDevelopmentError.sourceNotAllowed}
        let original=VisualEvidenceRequest.hash(request.imageData)
        guard allowed.contains(original)else{throw PinDevelopmentError.sourceNotAllowed}
        let expectedFrame=selectedProfile==Self.pixelBoundProfileSHA256 ? VisualEvidenceRequest.frameVersionV2:VisualEvidenceRequest.frameVersion
        let logical=try request.requestData(),frame=try request.modelImageData()
        struct FramePolicy:Decodable{let preprocessing:String}
        guard try JSONDecoder().decode(FramePolicy.self,from:logical).preprocessing==expectedFrame else{throw PinDevelopmentError.sourceNotAllowed}
        let input=PinDeclaredImageInput(requestData:logical,frameData:frame,requestSHA256:VisualEvidenceRequest.hash(logical),frameSHA256:VisualEvidenceRequest.hash(frame),originalSHA256:original,profileSHA256:selectedProfile)
        let bytes=try await transport(input)
        try Task.checkCancellation();try request.validate()
        guard bytes.count<=262144 else{throw PinDevelopmentError.oversized}
        struct Reading:Decodable {let coverage:VisualReadCoverage;let visibleDocumentCount:Int;let observations:[VisualReadObservation]}
        struct Response:Decodable {
            let gateVersion:String;let profileSHA256:String;let requestSHA256:String;let frameSHA256:String;let originalSHA256:String
            let traceSHA256:String;let elapsedSeconds:Double;let reading:Reading
        }
        let output=try JSONDecoder().decode(Response.self,from:bytes)
        guard output.gateVersion==Self.gateVersion,output.profileSHA256==input.profileSHA256,
              output.requestSHA256==input.requestSHA256,output.frameSHA256==input.frameSHA256,output.originalSHA256==input.originalSHA256,
              output.traceSHA256.count==64,output.traceSHA256.allSatisfy({"0123456789abcdef".contains($0)}),
              VisualEvidenceRequest.hash(try request.modelImageData())==input.frameSHA256 else{throw PinEvidenceError.invalidSupport}
        // Explicitly a declared agent profile, not an API wire-equivalence claim.
        let receipt=VisualEvidenceReceipt(provider:"Codex declared public-image agent / "+Self.gateVersion,model:"gpt-6.1-sol",requestSHA256:input.requestSHA256,coverage:output.reading.coverage,visibleDocumentCount:output.reading.visibleDocumentCount,observations:output.reading.observations,elapsedSeconds:output.elapsedSeconds)
        try receipt.validate(for:request)
        return receipt
    }
}
