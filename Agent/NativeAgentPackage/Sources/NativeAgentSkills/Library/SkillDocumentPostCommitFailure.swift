import Foundation

struct SkillDocumentPostCommitFailure: Error, LocalizedError, Sendable {
    let skillName: String
    let effect: String
    let failure: String

    var errorDescription: String? {
        "Skill \(skillName) was removed from the library, but \(effect) failed: \(failure)"
    }
}
