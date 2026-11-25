import PinCore
import Foundation

/// Exact-source fictional ingestion rehearsal in separate Debug Simulator apps.
/// Recorded mode reads a frozen proposal. Live mode sends only one allowlisted
/// fictional OCR transcript to a one-shot localhost interpreter on this Mac.
/// Neither mode exports image pixels or a PhotoKit source identifier.
enum SemanticSourceReplay {
    private struct File: Decodable {
        let schema: Int
        let entries: [Entry]
    }
    struct Entry: Decodable {
        let source: AppointmentSource
        let textDigest: String
        let choices: [String: String]?
        let quotedProposal: QuotedAppointmentDocument?
        let liveCaseID: String?
    }
    static var isLive: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier == "app.pin.appointmentslivecandidate" &&
            ProcessInfo.processInfo.arguments.contains("--test-live-quote")
        #else
        return false
        #endif
    }
    static var enabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--test-source-replay") &&
            (Bundle.main.bundleIdentifier == "app.pin.appointmentscandidate" || isLive)
        #else
        return false
        #endif
    }
    /// An app-owned opt-in for authored recorded fixtures only. It cannot be
    /// supplied by a model, enabled in a live replay, or used on a phone/Release.
    static var sourceAnchorIdentities: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return enabled && !isLive && ProcessInfo.processInfo.arguments.contains("--test-source-anchors")
        #else
        return false
        #endif
    }
    /// Freeze the local manifest for this process. A changed replay requires
    /// a relaunch, so one indexing pass cannot silently switch decisions.
    private static let manifest: File? = {
        guard enabled else { return nil }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("semantic-source-replay.json")
        guard let data = try? Data(contentsOf: url), data.count <= 65_536,
              let file = try? JSONDecoder().decode(File.self, from: data), file.schema == 1,
              file.entries.count <= 32,
              file.entries.allSatisfy({ entry in
                  [entry.choices != nil, entry.quotedProposal != nil, entry.liveCaseID != nil]
                      .filter { $0 }.count == 1 &&
                  (entry.liveCaseID == nil || (isLive && entry.liveCaseID == "F11" &&
                      entry.textDigest == "7ea98047485e521d54163f1c0176ab54a37d5de225e34dfe4782c1b3d4fe284d"))
              }),
              Set(file.entries.map { $0.source.id }).count == file.entries.count else { return nil }
        return file
    }()
    static func entry(for memory: PhotoMemory) -> Entry? {
        guard enabled, let lines = memory.textEvidence, !lines.isEmpty, lines.count <= 256,
              let file = manifest else { return nil }
        return file.entries.first {
            $0.source == AppointmentSource(memory) && $0.textDigest == AppointmentSourceDigest.text(lines)
        }
    }
    static func read(_ memory: PhotoMemory) -> AppointmentSourceRead? {
        guard let lines = memory.textEvidence, !lines.isEmpty, lines.count <= 256 else { return nil }
        return AppointmentSourceRead(source: AppointmentSource(memory), observations:
            lines.enumerated().map { offset, line in
                AppointmentFieldObservation(id: String(format: "ocr-%03d", offset), line: line)
            })
    }

    private struct LivePacket: Encodable {
        struct Line: Encodable { let id: String; let text: String }
        let caseID: String
        let textDigest: String
        let observations: [Line]
    }
    private struct LiveResponse: Decodable {
        let schema: Int
        let caseID: String
        let proposal: QuotedAppointmentDocument
    }
    static func liveProposal(caseID: String, digest: String,
                             read: AppointmentSourceRead) async throws -> QuotedAppointmentDocument {
        guard isLive, caseID == "F11",
              digest == "7ea98047485e521d54163f1c0176ab54a37d5de225e34dfe4782c1b3d4fe284d",
              AppointmentSourceDigest.text(read.observations.map(\.line)) == digest,
              let rawURL = ProcessInfo.processInfo.environment["PIN_SOURCE_LAB_URL"],
              let url = URL(string: rawURL), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.path.isEmpty,
              let token = ProcessInfo.processInfo.environment["PIN_SOURCE_LAB_TOKEN"],
              token.utf8.count >= 32 else { throw URLError(.badURL) }
        let packet = LivePacket(caseID: caseID, textDigest: digest,
            observations: read.observations.map { LivePacket.Line(id: $0.id, text: $0.line.text) })
        var request = URLRequest(url: url.appendingPathComponent("quote"))
        request.httpMethod = "POST"
        request.timeoutInterval = 85
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Pin-Lab-Token")
        request.httpBody = try JSONEncoder().encode(packet)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count < 32_000 else { throw URLError(.badServerResponse) }
        let value = try JSONDecoder().decode(LiveResponse.self, from: data)
        guard value.schema == 1, value.caseID == caseID else { throw URLError(.cannotParseResponse) }
        return value.proposal
    }
}
