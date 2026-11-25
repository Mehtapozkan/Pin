import Foundation
import PinCore
@main struct Run {
    struct Case: Decodable { let question: String; let name: String; let docs: [String:[String]] }
    struct Output: Encodable { let name: String; let called: Bool; let summary: String?; let rows: [Row] }
    struct Row: Encodable { let kind: String; let detail: String; let id: String? }
    static func main() async throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        for item in cases {
            let photos = item.docs.map { PhotoMemory(id: $0.key, fingerprint: "fictional", text: $0.value) }
            var answer = RailItinerary.answer(item.question, photos: photos)
            let called = answer?.needsModel == true
            if called {
                let decision = try await NativItinerary.interpret(item.question)
                answer = RailItinerary.answer(item.question, photos: photos, decision: decision)
            }
            let out = Output(name:item.name,called:called,summary:answer?.summary,rows:(answer?.rows ?? []).map { Row(kind:$0.kind.rawValue,detail:$0.detail,id:$0.photo?.id) })
            print(String(decoding:try JSONEncoder().encode(out),as:UTF8.self))
        }
    }
}
