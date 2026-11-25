import Foundation
import Vision
import ImageIO
import IBrainVision
import IBrainSemantics

/// Local full-frame OCR, not a visual-language model or a guarantee that all
/// printed facts were recognized. Reads the exact prepared bytes in its receipt.
public struct PinLocalVisionReader:VisualEvidenceReader {
    public init(){}
    public func read(_ request:VisualEvidenceRequest)async throws->VisualEvidenceReceipt {
        guard [.verbatimFieldsV2,.localOCRDenseV1].contains(request.readingPolicy) else{throw PinDevelopmentError.sourceNotAllowed}
        try Task.checkCancellation()
        let bytes=try request.modelImageData(),digest=VisualEvidenceRequest.hash(try request.requestData())
        return try await Task.detached(priority:.userInitiated){
            let start=Date()
            let read=VNRecognizeTextRequest();read.revision=VNRecognizeTextRequestRevision3
            read.recognitionLevel = .accurate;read.usesLanguageCorrection=false
            read.recognitionLanguages=["en-US","ja-JP"];read.automaticallyDetectsLanguage=true
            try VNImageRequestHandler(data:bytes,orientation:.up).perform([read])
            let raw=read.results ?? []
            guard raw.count<=request.readingPolicy.maximumObservations else{throw PinDevelopmentError.oversized}
            let lines=try raw.map { observation -> VisualReadObservation in
                guard let text=observation.topCandidates(1).first?.string,!text.isEmpty else{throw PinEvidenceError.staleRecord}
                let b=observation.boundingBox.intersection(CGRect(x:0,y:0,width:1,height:1))
                guard !b.isNull,!b.isEmpty else{throw PinEvidenceError.staleRecord}
                // The receipt's declared coordinate grid requires conservative
                // integer bounds. No text correction or candidate substitution.
                return VisualReadObservation(kind:.text,value:text,box:[max(0,Int(floor(b.minX*1000))),max(0,Int(floor((1-b.maxY)*1000))),min(1000,Int(ceil(b.maxX*1000))),min(1000,Int(ceil((1-b.minY)*1000)))])
            }
            let receipt=VisualEvidenceReceipt(provider:"Apple Vision local OCR",model:"VNRecognizeTextRequest-revision3-full-frame",requestSHA256:digest,coverage:lines.isEmpty ? .noReadableDetails:.readable,visibleDocumentCount:0,observations:lines,elapsedSeconds:Date().timeIntervalSince(start))
            try receipt.validate(for:request)
            return receipt
        }.value
    }
}
