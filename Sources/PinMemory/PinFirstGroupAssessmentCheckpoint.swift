import Foundation
import IBrainSemantics

/// A completed transport result, never authority to restart its model task.
/// Imported checkpoints must come from the preserved terminal host journal.
public struct PinFirstGroupAssessmentCheckpoint: Codable, Sendable {
    public enum Failure: Error { case changedEnvelope, changedTask, invalidProvider }
    public let schema: Int
    public let originalEnvelope: Data
    public let receipt: DecisionReceipt

    public init(originalEnvelope: Data, receipt: DecisionReceipt) {
        self.schema = 1; self.originalEnvelope = originalEnvelope; self.receipt = receipt
    }

    /// Reconstructing the whole normal envelope binds every source, group,
    /// task and policy field. Only the new transport session and UI nonce vary.
    public func validatedReceipt(currentEnvelope: Data, task: ChoiceTask) throws -> DecisionReceipt {
        guard schema == 1, originalEnvelope.count <= 1_048_576, currentEnvelope.count <= 1_048_576,
              var saved = try JSONSerialization.jsonObject(with: originalEnvelope) as? [String: Any],
              var current = try JSONSerialization.jsonObject(with: currentEnvelope) as? [String: Any] else {
            throw PinDevelopmentError.invalidReceipt
        }
        for envelope in [saved, current] {
            guard let session = envelope["session"] as? String, UUID(uuidString: session) != nil,
                  let nonce = envelope["questionRequestID"] as? String, UUID(uuidString: nonce) != nil,
                  let memory = envelope["memory"] as? [String: Any], memory["revision"] as? Int == 1,
                  memory["visualReading"] == nil,
                  let group = envelope["groupContext"] as? [String: Any], group["schema"] as? Int == 2,
                  group["ordinal"] as? Int == 1, envelope["retainedOCRGrouping"] as? Bool == true,
                  envelope["unitSourceRecovery"] as? Bool == true,
                  let encodedTask = envelope["task"] as? [String: Any],
                  encodedTask["version"] as? String == "appointment-visual-observations-v8/temporal-v9",
                  ["recordID", "recordRevision", "clockRepair", "authority", "parentPublication", "retainedGroupingInitialReceipt"].allSatisfy({ envelope[$0] == nil }) else {
                throw PinDevelopmentError.sourceNotAllowed
            }
        }
        for key in ["session", "questionRequestID"] { saved.removeValue(forKey: key); current.removeValue(forKey: key) }
        guard NSDictionary(dictionary: saved).isEqual(to: current) else{throw Failure.changedEnvelope}
        guard let taskObject = current["task"] else{throw Failure.changedTask}
        let savedTask=try JSONDecoder().decode(ChoiceTask.self,from:JSONSerialization.data(withJSONObject:taskObject))
        guard savedTask.id==task.id,savedTask.version==task.version,try savedTask.digest()==task.digest() else{throw Failure.changedTask}
        guard receipt.provider == "pin-native-subscription", receipt.model == "gpt-6.1-sol",
              receipt.answers.values.allSatisfy({ $0.confidence == nil && $0.probabilities == nil }) else{throw Failure.invalidProvider}
        try receipt.validate(for: task)
        return receipt
    }
}
