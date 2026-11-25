import Foundation
import CryptoKit

/// Native persisted observation provenance, not a source/dispatch permit or
/// semantic result. Original pixels remain in Photos; no second source store.
public struct PhotoVisualReading:Codable,Equatable,Sendable {
    public let version:Int
    public let sourceBeforeRead:EvidenceSource
    public let originalSHA256:String
    public let frameSHA256:String
    public let requestData:Data
    public let receiptData:Data
    public init(sourceBeforeRead:EvidenceSource,originalSHA256:String,frameSHA256:String,requestData:Data,receiptData:Data)throws {
        self.version=1;self.sourceBeforeRead=sourceBeforeRead;self.originalSHA256=originalSHA256;self.frameSHA256=frameSHA256;self.requestData=requestData;self.receiptData=receiptData
        _=try validatedReceipt()
    }
    public struct Observation:Codable,Equatable,Sendable {public let kind:String;public let value:String;public let box:[Int]}
    public struct Receipt:Codable,Equatable,Sendable {
        public let provider:String;public let model:String;public let requestSHA256:String
        public let coverage:String;public let visibleDocumentCount:Int;public let observations:[Observation];public let elapsedSeconds:Double
    }
    public static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    public var receiptSHA256:String {Self.hash(receiptData)}
    public func validatedReceipt()throws->Receipt {
        struct Source:Decodable {let id:String;let revision:Int;let fingerprint:String}
        struct Binding:Decodable {let imageSHA256:String;let source:Source;let acquisitionID:String}
        struct Request:Decodable {let contract:String;let taskID:String;let source:Source;let modelFrameSHA256:String;let readingPolicy:String;let sourceImageBinding:Binding}
        func validSHA(_ s:String)->Bool{s.count==64 && s.allSatisfy{"0123456789abcdef".contains($0)}}
        guard version==1,requestData.count<=32768,receiptData.count<=262144,validSHA(originalSHA256),validSHA(frameSHA256),!sourceBeforeRead.id.isEmpty,!sourceBeforeRead.fingerprint.isEmpty,sourceBeforeRead.revision>0 else{throw PinStoreError.staleImport}
        let q=try JSONDecoder().decode(Request.self,from:requestData),r=try JSONDecoder().decode(Receipt.self,from:receiptData)
        for s in [q.source,q.sourceImageBinding.source] {
            guard s.id==sourceBeforeRead.id,s.fingerprint==sourceBeforeRead.fingerprint,s.revision==sourceBeforeRead.revision else{throw PinStoreError.staleImport}
        }
        guard q.contract=="visual-source-evidence-v2-host-image-binding-v1",q.readingPolicy=="verbatimFieldsV2",UUID(uuidString:q.taskID) != nil,q.taskID==q.sourceImageBinding.acquisitionID,
              q.modelFrameSHA256==frameSHA256,q.sourceImageBinding.imageSHA256==originalSHA256,
              r.requestSHA256==Self.hash(requestData),!r.provider.isEmpty,r.provider.utf8.count<=512,!r.model.isEmpty,r.model.utf8.count<=256,
              ["readable","partial","noReadableDetails"].contains(r.coverage),(0...8).contains(r.visibleDocumentCount),r.elapsedSeconds.isFinite,r.elapsedSeconds>=0,
              r.observations.count<=64,r.observations.reduce(0,{$0+$1.value.utf8.count})<=16384,
              r.observations.filter({$0.kind=="visualLabel"}).count<=8,
              r.coverage != "noReadableDetails" || r.observations.isEmpty else{throw PinStoreError.staleImport}
        let labels:Set<String>=["printed-ticket-body","machine-readable-barcode","perforated-ticket-edge","poster-or-purchase-invitation","physical-machine-or-counter","overlapping-documents","other-visible-document-feature"]
        for o in r.observations {
            guard ["text","visualLabel"].contains(o.kind),!o.value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,o.value.utf8.count<=512,!o.value.contains("\0"),
                  o.box.count==4,o.box.allSatisfy({(0...1000).contains($0)}),o.box[0]<o.box[2],o.box[1]<o.box[3],o.kind=="text" || labels.contains(o.value) else{throw PinStoreError.staleImport}
        }
        return r
    }
    public func visualSupports()throws->[VisualFactSupport] {
        let receipt=try validatedReceipt()
        return receipt.observations.enumerated().compactMap { i,o in
            guard o.kind=="visualLabel" else{return nil}
            return VisualFactSupport(observationID:"pin-visual-v1:\(i):\(receiptSHA256)",kind:o.kind,value:o.value,region:Self.region(o.box),receiptSHA256:receiptSHA256,requestSHA256:receipt.requestSHA256,originalSHA256:originalSHA256,frameSHA256:frameSHA256,provider:receipt.provider,model:receipt.model)
        }
    }
    public func textLines()throws->[CardLine] {
        try validatedReceipt().observations.filter{$0.kind=="text"}.map { o in
            CardLine(o.value,confidence:0,region:Self.region(o.box))
        }
    }
    public static func region(_ box:[Int])->EvidenceRegion {
        EvidenceRegion(x:Double(box[0])/1000,y:Double(1000-box[3])/1000,width:Double(box[2]-box[0])/1000,height:Double(box[3]-box[1])/1000)
    }
    public func validate(for memory:PhotoMemory)throws {
        guard sourceBeforeRead.id==memory.id,sourceBeforeRead.fingerprint==memory.fingerprint,sourceBeforeRead.revision<Int.max,
              memory.revision==sourceBeforeRead.revision+1 else{throw PinStoreError.staleImport}
        let lines=try textLines()
        guard memory.textEvidence==lines,memory.text==lines.map(\.text)else{throw PinStoreError.staleImport}
    }
}
