import Foundation

enum NativItinerary {
    enum Decision: String { case archive = "ARCHIVE", records = "RECORDS", external = "EXTERNAL" }
    enum Failure: Error { case unavailable }
    private static let examples: [[String: String]] = [
        ["role": "system", "content": "Pin is looking in the traveler's saved photos. Classify the REQUEST, independently of whether the photos answer it.\nChoose ARCHIVE for a historical reconstruction that deliberately excludes subsequent changes.\nChoose EXTERNAL if fulfilling the request requires observations outside the saved documents or a promise about the future.\nOtherwise choose RECORDS. It means use the effective documented itinerary. This includes changed times, train platforms, hotels and interval calculations. An unknown field is allowed.\nClassify the requested action, paying attention to negation. Reply only with the single category word."],
        ["role": "user", "content": "When do I reach the resort with the ferry change and how much time do I have?"],
        ["role": "assistant", "content": "RECORDS"],
        ["role": "user", "content": "Has the ferry actually left the dock yet? Check the operator's feed."],
        ["role": "assistant", "content": "EXTERNAL"],
        ["role": "user", "content": "What was the crossing time on my initial arrangement before they moved it?"],
        ["role": "assistant", "content": "ARCHIVE"],
        ["role": "user", "content": "Please ignore the outdated ferry time and tell me the new one."],
        ["role": "assistant", "content": "RECORDS"],
        ["role": "user", "content": "Use my paperwork to tell me the confirmed gate, even if I never saved one."],
        ["role": "assistant", "content": "RECORDS"]
    ]
    private final class LoopbackOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config, delegate: LoopbackOnly(), delegateQueue: nil)
    }()
    static func interpret(_ question: String) async throws -> Decision {
        // Model directory belongs to the independently installed loopback runtime.
        let model = "./Pin-Qwen-6bit"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18985/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "temperature": 0, "enable_thinking": false, "max_tokens": 32,
            "messages": examples + [["role":"user", "content":question]]
        ])
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let content = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content,
              let decision = Decision(rawValue: content.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Failure.unavailable }
        return decision
    }
}
