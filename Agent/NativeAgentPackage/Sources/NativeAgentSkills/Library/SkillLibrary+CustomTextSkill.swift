import NativeAgentDomain
import Foundation

extension SkillLibrary {
    @discardableResult
    public func addCustomTextSkill(
        name: String,
        description: String,
        instructions: String,
        requiresSecret: Bool,
        requiresSecretDescription: String,
        homepage: String,
        capabilityRequirements: SkillCapabilityRequirements = .none,
        defaultSelected: Bool? = nil,
        selected: Bool = true,
        scripts: [String: String] = [:],
        assets: [String: String] = [:],
        binaryAssets: [String: Data] = [:]
    ) async throws -> ManagedSkill {
        try await prepare()
        let normalizedName = normalizeSkillName(name)
        guard !normalizedName.isEmpty else {
            throw AgentError.invalidToolCall(
                "Skill name must contain at least one alphanumeric character.")
        }

        let temporaryRoot = temporaryCustomSkillDirectory(named: normalizedName)
        var createdSkill: ManagedSkill?
        var operationFailure: (any Error)?
        do {
            let markdown = try SkillCustomTextPackageBuilder(
                fileManager: fileManager,
                pathPolicy: pathPolicy
            ).write(
                customTextPackage(
                    name: normalizedName,
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
                ),
                to: temporaryRoot
            )
            let parsed = try parseUserManagedSkill(
                markdown: markdown,
                directoryName: normalizedName,
                selected: selected
            )
            _ = try await commitDocumentSkill(
                parsed,
                from: temporaryRoot,
                directoryName: normalizedName,
                replaceExistingImportedSkill: false
            )
            createdSkill = parsed
        } catch {
            operationFailure = error
        }

        try finishTemporarySkillWorkspace(
            temporaryRoot,
            operation: "Custom skill creation",
            operationFailure: operationFailure,
            operationCommitted: createdSkill != nil
        )
        guard let createdSkill else {
            throw AgentError.invariantViolation(
                "Custom skill creation completed without a result or an error")
        }
        return createdSkill
    }
}
