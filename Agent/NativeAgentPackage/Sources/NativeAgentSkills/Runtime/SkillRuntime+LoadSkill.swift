import Foundation
import NativeAgentDomain

extension SkillRuntime {
    public func selectedSkills() async throws -> [ManagedSkill] {
        try await selectedSkillsLoader()
    }

    public func loadSkill(named skillName: String, callID: String) async throws -> ToolResult {
        guard let skill = try await selectedSkill(named: skillName) else {
            return resultBuilder.missingSkillResult(
                callID: callID,
                toolName: "load_skill",
                skillName: skillName
            )
        }

        let supportingFiles = try await supportingFileLoader(skill)
        return resultBuilder.loadSkillResult(skill: skill, supportingFiles: supportingFiles, callID: callID)
    }


    public func readSkillFile(
        skillName: String,
        relativePath: String,
        characterOffset: Int,
        maxCharacters: Int,
        callID: String
    ) async throws -> ToolResult {
        guard let skill = try await selectedSkill(named: skillName) else {
            return resultBuilder.missingSkillResult(
                callID: callID,
                toolName: "read_skill_file",
                skillName: skillName
            )
        }
        let read = try await supportingFileReader(
            skill,
            relativePath,
            characterOffset,
            maxCharacters
        )
        return ToolResult(
            callID: callID,
            toolName: "read_skill_file",
            output: read.jsonValue,
            metadata: [
                "skillName": .string(skill.name),
                "relativePath": .string(read.relativePath),
                "contentSHA256": .string(read.contentSHA256),
            ]
        )
    }

    func selectedSkill(named skillName: String) async throws -> ManagedSkill? {
        try await selectedSkillLoader(skillName)
    }


}
