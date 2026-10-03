import Foundation

enum SkillDirectoryContents: Sendable, Equatable {
    case absent
    case copied(from: URL)
}

struct SkillDirectoryMutation: Sendable, Equatable {
    let directoryName: String
    let contents: SkillDirectoryContents
}

struct SkillWorkspaceMutationPlan: Sendable, Equatable {
    let previousState: SkillState
    let updatedState: SkillState
    let directoryMutations: [SkillDirectoryMutation]
}
