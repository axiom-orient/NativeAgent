import NativeAgentDomain
import Foundation

package enum SkillDocumentMutationPrecondition: Sendable, Equatable {
    case absent(name: String)
    case instructions(name: String, expected: String)
}

package struct SkillDocumentMutationConflict: Error, LocalizedError, Sendable, Equatable {
    package let message: String

    package init(_ message: String) {
        self.message = message
    }

    package var errorDescription: String? { message }
}

extension SkillLibrary {
    func commitDocumentSkill(
        _ skill: ManagedSkill,
        from sourceDirectory: URL,
        directoryName: String,
        replaceExistingImportedSkill: Bool,
        preconditions: [SkillDocumentMutationPrecondition] = []
    ) async throws -> ManagedSkill? {
        try await withLibraryAccess(kind: .customSkillMutation) {
            let state = try await stateStore.load()
            let existingSkills = try snapshotSkills(from: state)
            try validateDocumentMutationPreconditions(preconditions, against: existingSkills)
            let existing = existingSkills.first { $0.name == skill.name }
            let plan = try SkillDocumentMutationReducer().reduce(
                state: state,
                action: .install(
                    SkillDocumentInstallRequest(
                        skill: skill,
                        sourceDirectory: sourceDirectory,
                        directoryName: directoryName,
                        replaceExistingImportedSkill: replaceExistingImportedSkill,
                        existingSkills: existingSkills,
                        updatedAt: now()
                    )
                )
            )
            try await workspaceTransaction.perform(plan.workspaceMutation)
            return existing
        }
    }

    func planAndCommitDocumentSkillRemoval(
        named skillName: String
    ) async throws {
        try await withLibraryAccess(kind: .customSkillMutation) {
            let state = try await stateStore.load()
            let resolvedSkill = try snapshotSkills(from: state).first { $0.name == skillName }
            let plan = try SkillDocumentMutationReducer().reduce(
                state: state,
                action: .remove(
                    requestedName: skillName,
                    resolvedSkill: resolvedSkill,
                    updatedAt: now()
                )
            )
            try await workspaceTransaction.perform(plan.workspaceMutation)
        }
    }

    private func validateDocumentMutationPreconditions(
        _ preconditions: [SkillDocumentMutationPrecondition],
        against existingSkills: [ManagedSkill]
    ) throws {
        for precondition in preconditions {
            switch precondition {
            case .absent(let name):
                guard !existingSkills.contains(where: { $0.name == name }) else {
                    throw SkillDocumentMutationConflict(
                        "skill mutation expected \(name) to be absent, but it exists"
                    )
                }
            case .instructions(let name, let expected):
                guard let current = existingSkills.first(where: { $0.name == name }) else {
                    throw SkillDocumentMutationConflict(
                        "skill mutation expected \(name) to exist, but it is absent"
                    )
                }
                guard current.instructions == expected else {
                    throw SkillDocumentMutationConflict(
                        "skill mutation base changed for \(name)"
                    )
                }
            }
        }
    }

    func customTextPackage(
        name: String,
        description: String,
        instructions: String,
        requiresSecret: Bool,
        requiresSecretDescription: String,
        homepage: String,
        capabilityRequirements: SkillCapabilityRequirements = .none,
        defaultSelected: Bool? = nil,
        scripts: [String: String],
        assets: [String: String],
        binaryAssets: [String: Data]
    ) -> SkillCustomTextPackage {
        SkillCustomTextPackage(
            name: name,
            description: description,
            instructions: instructions,
            requiresSecret: requiresSecret,
            requiresSecretDescription: requiresSecretDescription,
            homepage: homepage,
            capabilityRequirements: capabilityRequirements,
            defaultSelected: defaultSelected,
            scripts: scripts,
            assets: assets,
            binaryAssets: binaryAssets
        )
    }

    func temporaryCustomSkillDirectory(named normalizedName: String) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            "native-agent-custom-skill-\(normalizedName)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func finishTemporarySkillWorkspace(
        _ temporaryRoot: URL,
        operation: String,
        operationFailure: (any Error)?,
        operationCommitted: Bool
    ) throws {
        try SkillTemporaryWorkspaceCleanup(fileManager: fileManager).finish(
            temporaryRoot,
            operation: operation,
            operationFailure: operationFailure,
            operationCommitted: operationCommitted
                || operationFailure is SkillWorkspaceTransactionCommittedCleanupFailure
        )
    }
}
