import Foundation
import CryptoKit
import PinCore
import IBrainSemantics

/// Durable transport completion, never canonical facts or permission to retry.
/// A replay-only journal cannot invoke transport, even when a stage is missing.
public actor PinSourceStageJournal {
    private struct Binding: Codable, Equatable {
        let schema: Int
        let transaction: UUID
        let memory: PhotoMemory
        let originalSHA256: String
    }
    private struct Stage: Codable {
        let envelope: Data
        let receipt: DecisionReceipt
    }
    public nonisolated let replayOnly: Bool
    public nonisolated let transactionID: UUID
    private let directory: URL
    private let binding: Binding
    private var preparing: Set<String> = []

    public static func directory(in root: URL, transaction: UUID) -> URL {
        root.appendingPathComponent("stages-" + transaction.uuidString)
    }

    public init(directory: URL, transaction: UUID, memory: PhotoMemory, originalSHA256: String, replayOnly: Bool, resuming: Bool = false) throws {
        guard memory.revision >= 1, originalSHA256.count == 64, originalSHA256.allSatisfy(\.isHexDigit) else { throw PinDevelopmentError.sourceNotAllowed }
        self.directory = directory; self.replayOnly = replayOnly; transactionID = transaction
        binding = Binding(schema: 1, transaction: transaction, memory: memory, originalSHA256: originalSHA256)
        let file = directory.appendingPathComponent("binding.json")
        if replayOnly || (resuming && FileManager.default.fileExists(atPath:file.path)) {
            guard try Self.read(Binding.self, file: file) == binding else { throw PinEvidenceError.staleRecord }
        } else {
            if resuming,FileManager.default.fileExists(atPath:directory.path) {
                guard try FileManager.default.contentsOfDirectory(atPath:directory.path).isEmpty else{throw PinEvidenceError.staleRecord}
            }
            try PinPrivatePayloadWithdrawal.withWriteAccess {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.encode(binding).write(to: file, options: .withoutOverwriting)
            }
        }
    }

    public nonisolated func validateBinding(memory: PhotoMemory, originalSHA256: String, transaction: UUID) throws {
        guard binding.memory == memory, binding.originalSHA256 == originalSHA256, transactionID == transaction else { throw PinEvidenceError.staleRecord }
    }

    public func receipt(envelope: Data, task: ChoiceTask, beforeSend: @Sendable () async throws -> Void = {}, send: @Sendable () async throws -> DecisionReceipt) async throws -> DecisionReceipt {
        try Task.checkCancellation()
        guard try Self.read(Binding.self, file: directory.appendingPathComponent("binding.json")) == binding else { throw PinEvidenceError.staleRecord }
        let normalized = try normalizedEnvelope(envelope, task: task)
        let key = SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
        let completed = directory.appendingPathComponent(key + ".receipt.json")
        if FileManager.default.fileExists(atPath: completed.path) {
            let stage = try Self.read(Stage.self, file: completed)
            guard try normalizedEnvelope(stage.envelope, task: task) == normalized else { throw PinDevelopmentError.invalidReceipt }
            try Self.validate(stage.receipt, task: task)
            return stage.receipt
        }
        guard !replayOnly else { throw PinFreshProductFailure.unfinishedSourceRead }
        guard !FileManager.default.fileExists(atPath:directory.appendingPathComponent(key + ".started").path) else { throw PinFreshProductFailure.unfinishedSourceRead }
        // Readiness belongs only to new dispatch. A failed preflight must not
        // consume a stage; a completed response above needs no connection.
        guard preparing.insert(key).inserted else { throw PinFreshProductFailure.unfinishedSourceRead }
        defer { preparing.remove(key) }
        try await beforeSend()
        try Task.checkCancellation()
        guard try Self.read(Binding.self, file: directory.appendingPathComponent("binding.json")) == binding else { throw PinEvidenceError.staleRecord }
        // Recheck after suspension: another journal instance may have finished
        // or claimed this stage while readiness was being checked.
        if FileManager.default.fileExists(atPath: completed.path) {
            let stage = try Self.read(Stage.self, file: completed)
            guard try normalizedEnvelope(stage.envelope, task: task) == normalized else { throw PinDevelopmentError.invalidReceipt }
            try Self.validate(stage.receipt, task: task)
            return stage.receipt
        }
        guard !FileManager.default.fileExists(atPath:directory.appendingPathComponent(key + ".started").path) else { throw PinFreshProductFailure.unfinishedSourceRead }
        // Exclusive durable marker before transport prevents duplicate sends.
        // Once transport starts, unknown completion stays occupied.
        try PinPrivatePayloadWithdrawal.write(Data(key.utf8), to: directory.appendingPathComponent(key + ".started"), options: .withoutOverwriting)
        let received = try await send()
        try Self.validate(received, task: task)
        guard try Self.read(Binding.self, file: directory.appendingPathComponent("binding.json")) == binding else { throw PinEvidenceError.staleRecord }
        // A completed, validated transport response survives UI cancellation.
        // Withdrawal and source binding still gate persistence; cancellation
        // below prevents this operation from returning success or publishing.
        try PinPrivatePayloadWithdrawal.write(Self.encode(Stage(envelope: envelope, receipt: received)), to: completed, options: .withoutOverwriting)
        try Task.checkCancellation()
        return received
    }

    /// Withdrawal is based on the entire native memory, including revision and
    /// pixels/proof. No surviving receipt authorizes an old-source replay.
    public static func prune(in root: URL, memories: [PhotoMemory]) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where child.lastPathComponent.hasPrefix("stages-") {
            let binding = try read(Binding.self, file: child.appendingPathComponent("binding.json"))
            if !memories.contains(binding.memory) { try FileManager.default.removeItem(at: child) }
        }
    }

    private func normalizedEnvelope(_ data: Data, task: ChoiceTask) throws -> Data {
        guard data.count <= 2_097_152,
              var value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = value["session"] as? String, UUID(uuidString: session) != nil,
              let nonce = value["questionRequestID"] as? String, UUID(uuidString: nonce) != nil,
              value["unitSourceRecovery"] as? Bool == true,
              value["originalSHA256"] as? String == binding.originalSHA256,
              let memory = value["memory"], let encodedTask = value["task"] else { throw PinDevelopmentError.sourceNotAllowed }
        guard try JSONDecoder().decode(PhotoMemory.self, from: JSONSerialization.data(withJSONObject: memory)) == binding.memory else { throw PinEvidenceError.staleRecord }
        let actualTask = try JSONDecoder().decode(ChoiceTask.self, from: JSONSerialization.data(withJSONObject: encodedTask))
        guard try Self.encode(actualTask) == Self.encode(task) else { throw PinDevelopmentError.invalidReceipt }
        for key in ["session", "questionRequestID"] { value.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func validate(_ receipt: DecisionReceipt, task: ChoiceTask) throws {
        guard receipt.provider == "pin-native-subscription", receipt.model == "gpt-6.1-sol",
              receipt.elapsedSeconds.isFinite, receipt.elapsedSeconds >= 0,
              receipt.answers.values.allSatisfy({ $0.confidence == nil && $0.probabilities == nil }) else { throw PinDevelopmentError.invalidReceipt }
        try receipt.validate(for: task)
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func read<T: Decodable>(_ type: T.Type, file: URL) throws -> T {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4_194_304 else { throw PinDevelopmentError.oversized }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
}
