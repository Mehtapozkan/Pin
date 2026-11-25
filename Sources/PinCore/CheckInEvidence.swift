import Foundation
import CryptoKit

/// A locally decoded check-in QR is source evidence, not a booking decision or
/// permission to call its URL. Only digests are retained; the bearer key is not.
public struct CheckInCodeEvidence: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case guest, individualTicket, unclassified }

    public let source: EvidenceSource
    public let provider: String
    public let eventDigest: String
    public let keyDigest: String
    public let role: Role
    public let extractorVersion: String

    private init(source: EvidenceSource, provider: String, eventDigest: String,
                 keyDigest: String, role: Role) {
        self.source = source
        self.provider = provider
        self.eventDigest = eventDigest
        self.keyDigest = keyDigest
        self.role = role
        self.extractorVersion = "check-in-local-v1"
    }

    /// Luma documents guest-key QR codes as one guest's event registration,
    /// possibly covering several ticket types. This parser never loads the URL.
    public static func luma(_ payload: String, source: EvidenceSource) -> Self? {
        guard let url = URLComponents(string: payload),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "luma.com",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let query = url.queryItems, query.count == 1, query[0].name == "pk",
              let key = query[0].value, !key.isEmpty else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "check-in", !parts[1].isEmpty else { return nil }
        let event = String(parts[1])
        let role: Role
        if key.hasPrefix("g-") && key.count > 2 { role = .guest }
        else if key.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil { role = .individualTicket }
        else { role = .unclassified }
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return Self(source: source, provider: "luma", eventDigest: digest(event),
                    keyDigest: digest(key), role: role)
    }

    /// Both local detectors inspect the same image. A partial Vision result
    /// must not hide a second QR found by Core Image, or vice versa.
    public static func uniquePayload(vision: [String?], coreImage: [String?]) -> String? {
        guard vision.count <= 1, coreImage.count <= 1 else { return nil }
        let features = vision + coreImage
        guard !features.isEmpty, features.allSatisfy({ $0 != nil }) else { return nil }
        let payloads = features.compactMap { $0 }
        guard payloads.allSatisfy({ $0 == payloads[0] }) else { return nil }
        return payloads[0]
    }
}

/// Keeps multiple current photo sources linked to one documented Luma guest
/// registration. A guest key can cover multiple tickets: this never supplies
/// a ticket count or collapses AppointmentAnswer rows.
public struct RegistrationEvidenceGroup: Sendable {
    public let members: [AppointmentItem]
    public let printedDetailsAgree: Bool
    public var ticketCountKnown: Bool { false }
    fileprivate let identity: [String]

    public func isCurrent(items: [AppointmentItem], originals: [PhotoMemory], codes: [CheckInCodeEvidence]) -> Bool {
        guard let live = RegistrationEvidenceGroups.make(items: items, originals: originals, codes: codes)
            .first(where: { $0.identity == identity }),
              live.printedDetailsAgree == printedDetailsAgree,
              live.members.count == members.count else { return false }
        return zip(members, live.members).allSatisfy { $0.hasSameEvidence(as: $1) }
    }
}

public enum RegistrationEvidenceGroups {
    public static func make(items: [AppointmentItem], originals: [PhotoMemory],
                            codes: [CheckInCodeEvidence]) -> [RegistrationEvidenceGroup] {
        let current = AppointmentAnswerEngine.currentRecords(items, originals: originals, includingCancelled: true)
        let memories = Dictionary(grouping: originals, by: \.id)
        let codeBySource = Dictionary(grouping: codes, by: { $0.source.id })
        let ticketsBySource = Dictionary(grouping: current.filter { $0.observation.eventTicket == true }, by: \.sourceID)
        var grouped: [[String]: [AppointmentItem]] = [:]
        for item in current where item.observation.eventTicket == true {
            guard let sourceCopies = memories[item.sourceID], sourceCopies.count == 1,
                  let memory = sourceCopies.first,
                  ticketsBySource[item.sourceID]?.count == 1,
                  AppointmentCardReader.sourceDisposition(memory.text) == .notExcluded,
                  let matches = codeBySource[item.sourceID], matches.count == 1,
                  let code = matches.first, code.role == .guest,
                  code.source == EvidenceSource(memory),
                  item.source == AppointmentSource(memory) else { continue }
            grouped[[code.provider, code.eventDigest, code.keyDigest], default: []].append(item)
        }
        func normalized(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value.precomposedStringWithCanonicalMapping.lowercased()
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return grouped.map { identity, members in
            let sorted = members.sorted { $0.id < $1.id }
            let signatures = sorted.map { item -> [String]? in
                let card = item.observation
                guard let title = normalized(card.title), title != "event ticket",
                      let date = normalized(card.printedDate),
                      let time = normalized(card.printedTime),
                      let venue = normalized(card.venue) else { return nil }
                return [title, date, time, venue, card.cancelled == true ? "cancelled" : "active"]
            }
            let agree = signatures.allSatisfy { $0 != nil } &&
                signatures.allSatisfy { $0 == signatures.first! }
            return RegistrationEvidenceGroup(members: sorted, printedDetailsAgree: agree,
                                             identity: identity)
        }.sorted { $0.members[0].id < $1.members[0].id }
    }
}
