import Foundation

/// Owns one on-device transcription, independently of audio/permission callbacks.
public struct VoiceCaptureSession: Sendable {
    public enum Phase: Equatable, Sendable { case idle, preparing, recording, finishing }
    public enum Final: Equatable, Sendable { case question(String), empty }
    public private(set) var phase: Phase = .idle
    public private(set) var id: UUID?
    public private(set) var latest = ""
    public init() {}

    public mutating func begin() -> UUID? {
        guard phase == .idle else { return nil }
        let next = UUID(); id = next; latest = ""; phase = .preparing
        return next
    }
    public func owns(_ candidate: UUID) -> Bool { id == candidate && phase != .idle }
    @discardableResult public mutating func startRecording(_ candidate: UUID) -> Bool {
        guard owns(candidate), phase == .preparing else { return false }
        phase = .recording; return true
    }
    @discardableResult public mutating func partial(_ text: String, from candidate: UUID) -> Bool {
        guard owns(candidate), phase == .recording || phase == .finishing else { return false }
        latest = text; return true
    }
    public mutating func requestFinish() -> UUID? {
        guard phase == .recording, let id else { return nil }
        phase = .finishing; return id
    }
    public mutating func final(_ text: String, from candidate: UUID) -> Final? {
        guard owns(candidate), phase == .recording || phase == .finishing else { return nil }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        return question.isEmpty ? .empty : .question(question)
    }
    /// Cancellation, permission interruption and timeout never submit partial text.
    public mutating func cancel() { id = nil; phase = .idle; latest = "" }
}
