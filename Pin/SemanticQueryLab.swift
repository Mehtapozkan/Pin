import PinCore
import Foundation

/// Explicitly enabled, simulator-only fictional question lab. No image, OCR,
/// source identifier or appointment field is represented by this transport.
enum SemanticQueryLab {
    static var endpoint: URL? { nil }
    static var replaysRetainedResponses: Bool { false }
    static var consentTitle: String { "Local interpretation" }
    static var consentAction: String { "Continue" }
    static var privacyDescription: String { "Itinerary interpretation uses the local Nativ runtime." }
    struct Context: Codable { var previousIntent:String?;var previousPeriod:String?;var previousQuestion:String?;var resultCount:Int;var selectedOrdinal:Int?;var previousSelection:String? = nil }
    struct Clock: Codable { var now:String;var timezone:String;var calendar:String;var firstWeekday:Int }
    struct Packet: Codable { var requestID:String;var question:String;var context:Context;var clock:Clock }
    struct Response: Decodable { var schema:Int;var requestID:String;var model:String?;var accepted:Bool?;var confidence:Double?;var meaning:MemoryQueryMeaning?;var scope:AppointmentScopeEvidence?;var proposal:MemoryQueryProposal?;var error:String? }
    enum Failure: Error { case unavailable, unlistedQuestion, uncertain, invalid }
    struct Interpretation { let meaning:MemoryQueryMeaning; let scope:AppointmentScopeEvidence?;let proposal:MemoryQueryProposal? }
    static func interpret(_ question:String,id:UUID,context:Context,now:Date,calendar:Calendar) async throws -> Interpretation {
        throw Failure.unavailable
    }
}
