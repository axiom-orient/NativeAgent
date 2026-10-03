import NativeAgentDomain
import Foundation

extension SkillLibrary {
    func loadBundledSkills(selectionOverrides: [String: Bool]) throws -> [ManagedSkill] {
        guard let resourceRoot = bundle.resourceURL else {
            throw AgentError.notFound("Missing NativeAgentSkills resource root")
        }
        let skillsRoot = resourceRoot.appendingPathComponent("skills", isDirectory: true)
        let groups = ["built-in", "featured"]
        var values: [ManagedSkill] = []

        for group in groups {
            let groupURL = skillsRoot.appendingPathComponent(group, isDirectory: true)
            guard fileManager.fileExists(atPath: groupURL.path) else { continue }
            for (skillName, markdown) in try skillMarkdownEntries(in: groupURL) {
                let defaultSelected = try SkillMarkdownParser.bundledDefaultSelected(in: markdown)
                let parsed = try SkillMarkdownParser.parse(
                    markdown,
                    builtIn: group == "built-in",
                    selected: selectionOverrides[skillName] ?? defaultSelected,
                    group: group,
                    relativePath: "skills/\(group)/\(skillName)/SKILL.md",
                    source: ManagedSkillSource(kind: .bundled, location: "skills/\(group)/\(skillName)"),
                    now: now()
                )
                try SkillMarkdownFrontmatterParser.validateDirectoryIdentity(
                    skillName: parsed.name,
                    directoryName: skillName
                )
                values.append(parsed)
            }
        }

        return values
    }

    func loadUserDocumentSkills(
        selectionOverrides: [String: Bool],
        installedPlugins: [SkillPluginInstallation],
        webSkills: [ManagedSkill]
    ) throws -> [ManagedSkill] {
        var pluginIndex:
            [String: (plugin: SkillPluginInstallation, skill: SkillPluginInstalledSkill)] = [:]
        for plugin in installedPlugins {
            for skill in plugin.installedSkills {
                if pluginIndex[skill.directoryName] == nil {
                    pluginIndex[skill.directoryName] = (plugin, skill)
                }
            }
        }
        var webIndex: [String: ManagedSkill] = [:]
        for skill in webSkills where webIndex[skill.source.location] == nil {
            webIndex[skill.source.location] = skill
        }

        return try skillMarkdownEntries(in: workspace.userSkillsRootURL).map {
            directoryName, markdown in
            var parsed: ManagedSkill
            if let pluginEntry = pluginIndex[directoryName] {
                parsed = try parsePluginManagedSkill(
                    markdown: markdown,
                    pluginID: pluginEntry.plugin.id,
                    directoryName: directoryName,
                    manifestPath: pluginEntry.skill.manifestPath,
                    selected: pluginEntry.skill.selected,
                    skillDirectoryURL: workspace.userSkillDirectoryURL(named: directoryName)
                )
            } else if let webSkill = webIndex[directoryName] {
                parsed = try parseUserManagedSkill(
                    markdown: markdown,
                    directoryName: directoryName,
                    selected: webSkill.selected,
                    group: "web",
                    sourceKind: .web,
                    relativePathPrefix: "web",
                    executionSupport: webSkill.executionSupport,
                    executionSupportReason: webSkill.executionSupportReason
                )
            } else {
                parsed = try parseUserManagedSkill(
                    markdown: markdown,
                    directoryName: directoryName,
                    selected: true
                )
            }
            return parsed.applying(.selectionChanged(selectionOverrides[parsed.name] ?? parsed.selected))
        }
    }

    private func skillMarkdownEntries(in rootURL: URL) throws -> [(
        directoryName: String, markdown: String
    )] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { directory in
            let resourceValues = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true else { return nil }
            let markdownURL = directory.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: markdownURL.path) else { return nil }
            let markdown = try SkillBoundedFileReader.readUTF8(
                from: markdownURL,
                maximumByteCount: SkillLocalFileLimits.maximumSkillFileBytes,
                label: "skill document \(markdownURL.path)"
            )
            return (directory.lastPathComponent, markdown)
        }
    }
}
