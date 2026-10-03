import NativeAgentDomain
import Foundation

struct SkillPluginPreparedSkill: Sendable {
    let manifestPath: String
    let sourceDirectory: URL
    let destinationDirectoryName: String
    let skill: ManagedSkill
}

struct SkillPluginInstallRequest: Sendable {
    let manifest: SkillPluginManifest
    let sourceLocation: String
    let preparedSkills: [SkillPluginPreparedSkill]
    let installedAt: Date?
    let updatedAt: Date
}

struct SkillPluginMutationPlan: Sendable, Equatable {
    let workspaceMutation: SkillWorkspaceMutationPlan
    let installations: [SkillPluginInstallation]

    init(
        previousState: SkillState,
        updatedState: SkillState,
        installations: [SkillPluginInstallation],
        directoryMutations: [SkillDirectoryMutation]
    ) {
        self.workspaceMutation = SkillWorkspaceMutationPlan(
            previousState: previousState,
            updatedState: updatedState,
            directoryMutations: directoryMutations
        )
        self.installations = installations
    }

    var previousState: SkillState { workspaceMutation.previousState }
    var updatedState: SkillState { workspaceMutation.updatedState }
    var directoryMutations: [SkillDirectoryMutation] { workspaceMutation.directoryMutations }
}

enum SkillPluginMutationAction: Sendable {
    case install(
        requests: [SkillPluginInstallRequest],
        occupiedSkillNames: Set<String>
    )
    case uninstall(pluginIDs: Set<String>, updatedAt: Date)
}

struct SkillPluginMutationReducer: Sendable {
    func reduce(
        state: SkillState,
        action: SkillPluginMutationAction
    ) throws -> SkillPluginMutationPlan {
        switch action {
        case .install(let requests, let occupiedSkillNames):
            return try installPlan(
                state: state,
                requests: requests,
                occupiedSkillNames: occupiedSkillNames
            )
        case .uninstall(let pluginIDs, let updatedAt):
            return try uninstallPlan(state: state, pluginIDs: pluginIDs, updatedAt: updatedAt)
        }
    }

    private func installPlan(
        state: SkillState,
        requests: [SkillPluginInstallRequest],
        occupiedSkillNames: Set<String>
    ) throws -> SkillPluginMutationPlan {
        guard !requests.isEmpty else {
            throw AgentError.invalidToolCall("At least one skill plugin installation is required")
        }

        let requestedIDs = requests.map(\.manifest.id)
        let requestedIDSet = Set(requestedIDs)
        guard requestedIDSet.count == requestedIDs.count else {
            throw AgentError.invariantViolation("A skill plugin installation batch contains duplicate plugin ids")
        }

        let replacedPlugins = state.installedPlugins.filter { requestedIDSet.contains($0.id) }
        let replacedSkillNames = Set(replacedPlugins.flatMap { $0.installedSkills.map(\.name) })
        let protectedSkillNames = occupiedSkillNames.subtracting(replacedSkillNames)

        var plannedSkillNames = Set<String>()
        for request in requests {
            guard !request.preparedSkills.isEmpty else {
                throw AgentError.invalidToolCall(
                    "Skill plugin \(request.manifest.id) does not declare or contain any skills")
            }
            for prepared in request.preparedSkills {
                guard plannedSkillNames.insert(prepared.skill.name).inserted else {
                    throw AgentError.invariantViolation(
                        "A skill named \(prepared.skill.name) is declared more than once in the installation batch.")
                }
                guard !protectedSkillNames.contains(prepared.skill.name) else {
                    throw AgentError.invariantViolation("A skill named \(prepared.skill.name) already exists.")
                }
            }
        }

        let installations = requests.map { request in
            let installedSkills = request.preparedSkills.map { prepared in
                SkillPluginInstalledSkill(
                    name: prepared.skill.name,
                    directoryName: prepared.destinationDirectoryName,
                    manifestPath: prepared.manifestPath,
                    selected: prepared.skill.selected
                )
            }
            return SkillPluginInstallation(
                id: request.manifest.id,
                name: request.manifest.name,
                pluginVersion: request.manifest.version,
                description: request.manifest.description,
                homepage: request.manifest.homepage,
                sourceLocation: request.sourceLocation,
                installedSkills: installedSkills,
                installedAt: request.installedAt ?? request.updatedAt,
                updatedAt: request.updatedAt
            )
        }

        let retainedPlugins = state.installedPlugins.filter { !requestedIDSet.contains($0.id) }
        let installedPlugins = Array(installations.reversed()) + retainedPlugins

        var selectionOverrides = state.selectionOverrides
        for plugin in replacedPlugins {
            for skill in plugin.installedSkills {
                selectionOverrides.removeValue(forKey: skill.name)
            }
        }
        for installation in installations {
            for skill in installation.installedSkills {
                selectionOverrides[skill.name] = skill.selected
            }
        }

        var desiredDirectories: [String: SkillDirectoryContents] = [:]
        for plugin in replacedPlugins {
            for skill in plugin.installedSkills {
                desiredDirectories[skill.directoryName] = .absent
            }
        }
        for request in requests {
            for prepared in request.preparedSkills {
                desiredDirectories[prepared.destinationDirectoryName] = .copied(
                    from: prepared.sourceDirectory.standardizedFileURL)
            }
        }

        let updatedAt = requests.map(\.updatedAt).max() ?? state.updatedAt
        let updatedState = state.applying(
            .contentsChanged(
                selectionOverrides: selectionOverrides,
                remoteSkills: state.remoteSkills,
                installedPlugins: installedPlugins,
                updatedAt: updatedAt
            )
        )
        let mutations = desiredDirectories.keys.sorted().map { directoryName in
            SkillDirectoryMutation(
                directoryName: directoryName,
                contents: desiredDirectories[directoryName] ?? .absent
            )
        }
        return SkillPluginMutationPlan(
            previousState: state,
            updatedState: updatedState,
            installations: installations,
            directoryMutations: mutations
        )
    }

    private func uninstallPlan(
        state: SkillState,
        pluginIDs: Set<String>,
        updatedAt: Date
    ) throws -> SkillPluginMutationPlan {
        guard !pluginIDs.isEmpty else {
            throw AgentError.invalidToolCall("At least one skill plugin id is required")
        }

        let installations = state.installedPlugins.filter { pluginIDs.contains($0.id) }
        let foundIDs = Set(installations.map(\.id))
        let missingIDs = pluginIDs.subtracting(foundIDs)
        guard missingIDs.isEmpty else {
            throw AgentError.notFound(
                "Installed skill plugin not found: \(missingIDs.sorted().joined(separator: ", "))")
        }

        var selectionOverrides = state.selectionOverrides
        for installation in installations {
            for skill in installation.installedSkills {
                selectionOverrides.removeValue(forKey: skill.name)
            }
        }
        let installedPlugins = state.installedPlugins.filter { !pluginIDs.contains($0.id) }
        let updatedState = state.applying(
            .contentsChanged(
                selectionOverrides: selectionOverrides,
                remoteSkills: state.remoteSkills,
                installedPlugins: installedPlugins,
                updatedAt: updatedAt
            )
        )
        let mutations = Set(installations.flatMap { $0.installedSkills.map(\.directoryName) })
            .sorted()
            .map { SkillDirectoryMutation(directoryName: $0, contents: .absent) }

        return SkillPluginMutationPlan(
            previousState: state,
            updatedState: updatedState,
            installations: [],
            directoryMutations: mutations
        )
    }
}
