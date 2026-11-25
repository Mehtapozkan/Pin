import PinCore
import Foundation
import CoreGraphics
import Vision
struct CardOCRRead: Codable {
    var lines: [CardLine]
    var focusedReads: [String]
}
enum CardOCR {
    static func read(_ image: CGImage) throws -> CardOCRRead {
        func request(_ region: CGRect? = nil) throws -> [VNRecognizedTextObservation] {
            let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate
            r.recognitionLanguages = ["en-US","ja-JP"]; r.automaticallyDetectsLanguage=true; r.usesLanguageCorrection = true
            if let region { r.regionOfInterest = region }
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([r])
            return r.results ?? []
        }
        func match(_ pattern: String, _ text: String) -> String? {
            guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return String(text[range])
        }
        let observations = try request()
        var lines: [CardLine] = [], focused: [String] = []
        for obs in observations {
            guard let raw = obs.topCandidates(1).first else { continue }
            let box=obs.boundingBox
            let support=EvidenceRegion(x:box.minX,y:box.minY,width:box.width,height:box.height)
            var line = CardLine(raw.string, confidence: raw.confidence,region:support)
            // Retry only an observed time-like region whose AM/PM was unreadable.
            // Never rewrite PV/PN to PM or inject a known fixture value.
            if let digits = match("\\b[0-9]{1,2}:[0-9]{2}\\b", raw.string), match("\\b(?:AM|PM)\\b", raw.string) == nil {
                let region = obs.boundingBox.insetBy(dx: -0.06, dy: -0.06).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let candidates = try request(region).compactMap { $0.topCandidates(1).first }
                    .filter { match("\\b[0-9]{1,2}:[0-9]{2}\\b", $0.string) == digits && match("\\b(?:AM|PM)\\b", $0.string) != nil }
                if candidates.count == 1, let candidate = candidates.first {
                    line = CardLine(candidate.string, confidence: candidate.confidence,region:EvidenceRegion(x:region.minX,y:region.minY,width:region.width,height:region.height))
                    focused.append("\(raw.string) → \(candidate.string) (re-read the same image region)")
                }
            }
            lines.append(line)
        }
        return CardOCRRead(lines: lines, focusedReads: focused)
    }
}
