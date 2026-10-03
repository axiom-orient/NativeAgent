import Foundation
import Testing

@testable import NativeAgentSkills

@Test
func pluginMutationBatchPreservesEstablishedFrontInsertionOrder() throws {
    let retained = pluginInstallation(id: "retained", skillName: "retained-skill")
    let replaced = pluginInstallation(id: "two", skillName: "old-two-skill")
    let state = SkillState(installedPlugins: [retained, replaced])
    let requests = [
        pluginInstallRequest(id: "one", skillName: "one-skill", timestamp: 1),
        pluginInstallRequest(id: "two", skillName: "new-two-skill", timestamp: 2),
        pluginInstallRequest(id: "three", skillName: "three-skill", timestamp: 3),
    ]

    let plan = try SkillPluginMutationReducer().reduce(
        state: state,
        action: .install(requests: requests, occupiedSkillNames: ["retained-skill", "old-two-skill"])
    )

    #expect(plan.installations.map(\.id) == ["one", "two", "three"])
    #expect(plan.updatedState.installedPlugins.map(\.id) == ["three", "two", "one", "retained"])
}

private func pluginInstallation(id: String, skillName: String) -> SkillPluginInstallation {
    SkillPluginInstallation(
        id: id,
        name: id,
        pluginVersion: "1.0.0",
        description: id,
        homepage: "",
        sourceLocation: "/\(id)",
        installedSkills: [
            SkillPluginInstalledSkill(
                name: skillName,
                directoryName: "\(id)--\(skillName)",
                manifestPath: "skills/\(skillName)",
                selected: true
            )
        ],
        installedAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func pluginInstallRequest(
    id: String,
    skillName: String,
    timestamp: TimeInterval
) -> SkillPluginInstallRequest {
    let updatedAt = Date(timeIntervalSince1970: timestamp)
    let skill = ManagedSkill(
        name: skillName,
        description: skillName,
        instructions: "Use \(skillName)",
        builtIn: false,
        selected: true,
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: "",
        group: "plugins",
        relativePath: "plugins/\(id)/skills/\(skillName)/SKILL.md",
        excerpt: "Use \(skillName)",
        source: ManagedSkillSource(kind: .plugin, location: "\(id)--\(skillName)"),
        createdAt: updatedAt,
        updatedAt: updatedAt
    )
    return SkillPluginInstallRequest(
        manifest: SkillPluginManifest(
            id: id,
            name: id,
            version: "2.0.0",
            description: id,
            skills: [.init(path: "skills/\(skillName)")]
        ),
        sourceLocation: "/\(id)",
        preparedSkills: [
            SkillPluginPreparedSkill(
                manifestPath: "skills/\(skillName)",
                sourceDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(id, isDirectory: true),
                destinationDirectoryName: "\(id)--\(skillName)",
                skill: skill
            )
        ],
        installedAt: nil,
        updatedAt: updatedAt
    )
}
