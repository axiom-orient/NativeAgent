import NativeAgentDomain
import Foundation

extension SkillLibrary {
    func parseUserManagedSkill(
        markdown: String,
        directoryName: String,
        selected: Bool,
        group: String = "custom",
        sourceKind: ManagedSkillSource.Kind = .imported,
        relativePathPrefix: String = "documents",
        executionSupport: SkillExecutionSupport = .available,
        executionSupportReason: String = ""
    ) throws -> ManagedSkill {
        let parsed = try SkillMarkdownParser.parse(
            markdown,
            builtIn: false,
            selected: selected,
            group: group,
            relativePath: "\(relativePathPrefix)/\(directoryName)/SKILL.md",
            source: ManagedSkillSource(kind: sourceKind, location: directoryName),
            now: now()
        )
        try SkillMarkdownFrontmatterParser.validateDirectoryIdentity(
            skillName: parsed.name,
            directoryName: directoryName
        )
        return parsed.applying(
            .executionSupportChanged(
                executionSupport,
                reason: executionSupportReason,
                updatedAt: now()
            )
        )
    }
}
