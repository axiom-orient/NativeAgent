import NativeAgentDomain
import Foundation

struct SkillDocumentInstallRequest: Sendable {
    let skill: ManagedSkill
    let sourceDirectory: URL
    let directoryName: String
    let replaceExistingImportedSkill: Bool
    let existingSkills: [ManagedSkill]
    let updatedAt: Date
}

enum SkillDocumentMutationAction: Sendable {
    case install(SkillDocumentInstallRequest)
    case remove(
        requestedName: String,
        resolvedSkill: ManagedSkill?,
        updatedAt: Date
    )
}

struct SkillDocumentMutationPlan: Sendable, Equatable {
    let workspaceMutation: SkillWorkspaceMutationPlan

    var previousState: SkillState { workspaceMutation.previousState }
    var updatedState: SkillState { workspaceMutation.updatedState }
    var directoryMutations: [SkillDirectoryMutation] { workspaceMutation.directoryMutations }
}

struct SkillDocumentMutationReducer: Sendable {
    func reduce(
        state: SkillState,
        action: SkillDocumentMutationAction
    ) throws -> SkillDocumentMutationPlan {
        switch action {
        case .install(let request):
            return try installPlan(state: state, request: request)
        case .remove(let requestedName, let resolvedSkill, let updatedAt):
            return try removalPlan(
                state: state,
                requestedName: requestedName,
                resolvedSkill: resolvedSkill,
                updatedAt: updatedAt
            )
        }
    }

    private func installPlan(
        state: SkillState,
        request: SkillDocumentInstallRequest
    ) throws -> SkillDocumentMutationPlan {
        guard request.skill.source.kind == .imported || request.skill.source.kind == .web else {
            throw AgentError.invariantViolation(
                "Document skill installation requires an imported or web skill source")
        }
        guard !request.skill.name.isEmpty, !request.directoryName.isEmpty else {
            throw AgentError.invariantViolation(
                "Document skill installation requires a skill name and directory name")
        }
        guard request.skill.source.location == request.directoryName else {
            throw AgentError.invariantViolation(
                "Document skill source location must match its destination directory")
        }

        let matchingSkills = request.existingSkills.filter { $0.name == request.skill.name }
        guard matchingSkills.count <= 1 else {
            throw AgentError.invariantViolation(
                "Skill library contains more than one skill named \(request.skill.name)")
        }
        if let existing = matchingSkills.first {
            guard request.replaceExistingImportedSkill else {
                throw AgentError.invariantViolation(
                    "A skill named \(request.skill.name) already exists.")
            }
            guard !existing.builtIn, existing.source.kind == .imported else {
                throw AgentError.invalidToolCall(
                    "Only imported custom skills can be updated in place. Import an evolved custom copy instead.")
            }
            guard existing.source.location == request.directoryName else {
                throw AgentError.invariantViolation(
                    "An imported skill update cannot change its workspace directory")
            }
        }

        var selectionOverrides = state.selectionOverrides
        selectionOverrides[request.skill.name] = request.skill.selected

        var remoteSkills = state.remoteSkills.filter { $0.name != request.skill.name }
        if request.skill.source.kind == .web {
            remoteSkills.insert(request.skill, at: 0)
        }

        let updatedState = state.applying(
            .contentsChanged(
                selectionOverrides: selectionOverrides,
                remoteSkills: remoteSkills,
                installedPlugins: state.installedPlugins,
                updatedAt: request.updatedAt
            )
        )
        return SkillDocumentMutationPlan(
            workspaceMutation: SkillWorkspaceMutationPlan(
                previousState: state,
                updatedState: updatedState,
                directoryMutations: [
                    SkillDirectoryMutation(
                        directoryName: request.directoryName,
                        contents: .copied(from: request.sourceDirectory.standardizedFileURL)
                    )
                ]
            )
        )
    }

    private func removalPlan(
        state: SkillState,
        requestedName: String,
        resolvedSkill: ManagedSkill?,
        updatedAt: Date
    ) throws -> SkillDocumentMutationPlan {
        if resolvedSkill?.source.kind == .plugin {
            throw AgentError.invariantViolation(
                "Plugin skill \(requestedName) must be removed by uninstalling its plugin.")
        }

        var selectionOverrides = state.selectionOverrides
        selectionOverrides.removeValue(forKey: requestedName)
        let updatedState = state.applying(
            .contentsChanged(
                selectionOverrides: selectionOverrides,
                remoteSkills: state.remoteSkills.filter { $0.name != requestedName },
                installedPlugins: state.installedPlugins,
                updatedAt: updatedAt
            )
        )

        let directoryMutations: [SkillDirectoryMutation]
        if let resolvedSkill,
              resolvedSkill.source.kind == .imported || resolvedSkill.source.kind == .web {
            guard !resolvedSkill.source.location.isEmpty else {
                throw AgentError.invariantViolation(
                    "A removable document skill must identify its workspace directory")
            }
            directoryMutations = [
                SkillDirectoryMutation(
                    directoryName: resolvedSkill.source.location,
                    contents: .absent
                )
            ]
        } else {
            directoryMutations = []
        }

        return SkillDocumentMutationPlan(
            workspaceMutation: SkillWorkspaceMutationPlan(
                previousState: state,
                updatedState: updatedState,
                directoryMutations: directoryMutations
            )
        )
    }
}
