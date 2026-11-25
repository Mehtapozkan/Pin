/// Owns the foreground idle-timer change for one active user request.
/// Backgrounding/manual locking releases it; this grants no background work.
public struct PinForegroundRequestLease {
    private var previousValue: Bool?
    public init() {}

    /// Returns an idle-timer value to apply, or nil when no change is owned.
    public mutating func update(working: Bool, active: Bool, currentValue: Bool) -> Bool? {
        if working && active {
            guard previousValue == nil else { return nil }
            previousValue = currentValue
            return true
        }
        guard let previousValue else { return nil }
        self.previousValue = nil
        return previousValue
    }
}

public enum PinQuestionWorkPhase {
    case preparingPhotos, interpretingQuestion, checkingEvidence

    public var title: String {
        switch self {
        case .preparingPhotos: "Reading details from your photos…"
        case .interpretingQuestion: "Understanding your question…"
        case .checkingEvidence: "Checking the photo evidence…"
        }
    }
}
