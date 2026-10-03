import NativeAgentDomain
import Foundation

enum SkillLibraryAccessKind: String, Sendable, Equatable {
    case read
    case workspaceRecovery
    case selectionMutation
    case secretMutation
    case customSkillMutation
    case pluginMutation
}

struct SkillLibraryAccessClaim: Sendable, Equatable {
    let id: UUID
    let kind: SkillLibraryAccessKind
}

enum SkillLibraryAccessState: Sendable, Equatable {
    case idle
    case active(owner: SkillLibraryAccessClaim, waiting: [SkillLibraryAccessClaim])
}

enum SkillLibraryAccessAction: Sendable {
    case request(SkillLibraryAccessClaim)
    case cancel(UUID)
    case release(UUID)
}

enum SkillLibraryAccessEffect: Sendable, Equatable {
    case grant(SkillLibraryAccessClaim)
    case suspend(SkillLibraryAccessClaim)
    case cancel(UUID)
}

struct SkillLibraryAccessTransition: Sendable, Equatable {
    let state: SkillLibraryAccessState
    let effects: [SkillLibraryAccessEffect]
}

struct SkillLibraryAccessReducer: Sendable {
    func reduce(
        state: SkillLibraryAccessState,
        action: SkillLibraryAccessAction
    ) throws -> SkillLibraryAccessTransition {
        switch (state, action) {
        case (.idle, .request(let claim)):
            return SkillLibraryAccessTransition(
                state: .active(owner: claim, waiting: []),
                effects: [.grant(claim)]
            )

        case (.active(let owner, let waiting), .request(let claim)):
            guard owner.id != claim.id, !waiting.contains(where: { $0.id == claim.id }) else {
                throw AgentError.invariantViolation(
                    "A skill library access claim cannot be requested more than once")
            }
            return SkillLibraryAccessTransition(
                state: .active(owner: owner, waiting: waiting + [claim]),
                effects: [.suspend(claim)]
            )

        case (.idle, .cancel):
            return SkillLibraryAccessTransition(state: .idle, effects: [])

        case (.active(let owner, let waiting), .cancel(let claimID)):
            if owner.id == claimID {
                guard let next = waiting.first else {
                    return SkillLibraryAccessTransition(
                        state: .idle,
                        effects: [.cancel(claimID)]
                    )
                }
                return SkillLibraryAccessTransition(
                    state: .active(owner: next, waiting: Array(waiting.dropFirst())),
                    effects: [.cancel(claimID), .grant(next)]
                )
            }
            guard waiting.contains(where: { $0.id == claimID }) else {
                return SkillLibraryAccessTransition(state: state, effects: [])
            }
            return SkillLibraryAccessTransition(
                state: .active(
                    owner: owner,
                    waiting: waiting.filter { $0.id != claimID }
                ),
                effects: [.cancel(claimID)]
            )

        case (.idle, .release(let claimID)):
            throw AgentError.invariantViolation(
                "Cannot release inactive skill library access claim: \(claimID.uuidString)")

        case (.active(let owner, let waiting), .release(let claimID)):
            guard owner.id == claimID else {
                throw AgentError.invariantViolation(
                    "Cannot release a skill library access claim that does not own the boundary")
            }
            guard let next = waiting.first else {
                return SkillLibraryAccessTransition(state: .idle, effects: [])
            }
            return SkillLibraryAccessTransition(
                state: .active(owner: next, waiting: Array(waiting.dropFirst())),
                effects: [.grant(next)]
            )
        }
    }
}
