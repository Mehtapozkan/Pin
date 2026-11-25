import Foundation

/// Input admission is separate from semantic interpretation and source access.
/// The opt-in interactive fixture route permits natural wording without rewriting
/// it; all source/authority/lease/budget checks remain at their existing owners.
public enum PinPublicQuestionAdmission {
    public static let naturalV1="naturalPublicFixtureV1"
    public static func permits(_ question:String,policy:String?,configured:[String])->Bool {
        guard !question.isEmpty,question.utf8.count<=4096 else{return false}
        let wrappers=CharacterSet(charactersIn:" \t\r\n\u{0B}\u{0C}\"'“”‘’")
        let body=question.trimmingCharacters(in:wrappers)
        guard !body.isEmpty else{return false}
        if policy==naturalV1{return true}
        guard policy==nil else{return false}
        return configured.contains{$0.trimmingCharacters(in:wrappers)==body}
    }
}
