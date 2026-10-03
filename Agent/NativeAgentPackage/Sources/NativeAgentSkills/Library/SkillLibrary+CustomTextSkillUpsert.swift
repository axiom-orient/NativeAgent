import NativeAgentDomain
import Foundation

public enum CustomTextSkillUpsertOperation: String, Codable, Sendable, Equatable {
    case created
    case updated
}

public struct CustomTextSkillUpsertResult: Codable, Sendable, Equatable {
    public let operation: CustomTextSkillUpsertOperation
    public let skill: ManagedSkill

    public init(operation: CustomTextSkillUpsertOperation, skill: ManagedSkill) {
        self.operation = operation
        self.skill = skill
    }
}

extension SkillLibrary {
    @discardableResult
    public func upsertCustomTextSkill(
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
    ) async throws -> CustomTextSkillUpsertResult {
        try await upsertCustomTextSkill(
            name: name,
            description: description,
            instructions: instructions,
            requiresSecret: requiresSecret,
            requiresSecretDescription: requiresSecretDescription,
            homepage: homepage,
            capabilityRequirements: capabilityRequirements,
            defaultSelected: defaultSelected,
            selected: selected,
            scripts: scripts,
            assets: assets,
            binaryAssets: binaryAssets,
            mutationPreconditions: []
        )
    }

    @discardableResult
    package func upsertCustomTextSkill(
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
        binaryAssets: [String: Data] = [:],
        mutationPreconditions: [SkillDocumentMutationPrecondition]
    ) async throws -> CustomTextSkillUpsertResult {
        try await prepare()
        let normalizedName = normalizeSkillName(name)
        guard !normalizedName.isEmpty else {
            throw AgentError.invalidToolCall(
                "Skill name must contain at least one alphanumeric character.")
        }

        let temporaryRoot = temporaryCustomSkillDirectory(named: normalizedName)
        var result: CustomTextSkillUpsertResult?
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
            let existing = try await commitDocumentSkill(
                parsed,
                from: temporaryRoot,
                directoryName: normalizedName,
                replaceExistingImportedSkill: true,
                preconditions: mutationPreconditions
            )
            result = CustomTextSkillUpsertResult(
                operation: existing == nil ? .created : .updated,
                skill: parsed
            )
        } catch {
            operationFailure = error
        }

        try finishTemporarySkillWorkspace(
            temporaryRoot,
            operation: "Custom skill upsert",
            operationFailure: operationFailure,
            operationCommitted: result != nil
        )
        guard let result else {
            throw AgentError.invariantViolation(
                "Custom skill upsert completed without a result or an error")
        }
        return result
    }
}
