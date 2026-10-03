import Foundation
import NativeAgentDomain

enum SkillPluginManifestPaths {
    static let primary = "native-agent-skill-plugin.json"
    static let relativePaths = [primary]
}

extension SkillLibrary {

    @discardableResult
    public func installSkillPlugin(
        fromDirectoryURL pluginDirectoryURL: URL,
        selectedByDefault: Bool = true
    ) async throws -> SkillPluginInstallation {
        try await installSkillPlugin(
            fromDirectoryURL: pluginDirectoryURL,
            selectedByDefault: selectedByDefault,
            sourceLocationOverride: nil
        )
    }

    @discardableResult
    private func installSkillPlugin(
        fromDirectoryURL pluginDirectoryURL: URL,
        selectedByDefault: Bool,
        sourceLocationOverride: String?
    ) async throws -> SkillPluginInstallation {
        try await prepare()
        return try await withLibraryAccess(kind: .pluginMutation) {
        let state = try await stateStore.load()
        let request = try preparePluginInstallRequest(
            fromDirectoryURL: pluginDirectoryURL,
            selectedByDefault: selectedByDefault,
            sourceLocation: sourceLocationOverride ?? pluginDirectoryURL.standardizedFileURL.path,
            state: state,
            updatedAt: now()
        )
        let occupiedSkillNames = Set(try snapshotSkills(from: state).map(\.name))
        let plan = try SkillPluginMutationReducer().reduce(
            state: state,
            action: .install(
                requests: [request],
                occupiedSkillNames: occupiedSkillNames
            )
        )
        try await workspaceTransaction.perform(plan.workspaceMutation)
        guard let installation = plan.installations.first else {
            throw AgentError.invariantViolation("Skill plugin installation plan produced no installation")
        }
        return installation
        }
    }

    func preparePluginInstallRequest(
        fromDirectoryURL pluginDirectoryURL: URL,
        selectedByDefault: Bool,
        sourceLocation: String,
        state: SkillState,
        updatedAt: Date
    ) throws -> SkillPluginInstallRequest {
        let sourceRoot = pluginDirectoryURL.standardizedFileURL
        let manifest = try loadPluginManifest(from: sourceRoot)
        try validatePluginManifest(manifest)
        let skillSpecs = try discoverPluginSkillSpecs(manifest: manifest, sourceRoot: sourceRoot)
        guard !skillSpecs.isEmpty else {
            throw AgentError.invalidToolCall(
                "Skill plugin \(manifest.id) does not declare or contain any skills")
        }

        var preparedSkills: [SkillPluginPreparedSkill] = []
        for spec in skillSpecs {
            let sourceDirectory = try validatedPluginSkillDirectory(
                relativePath: spec.path,
                within: sourceRoot
            )
            let markdownURL = sourceDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: markdownURL.path) else {
                throw AgentError.notFound("SKILL.md not found for plugin skill at \(spec.path)")
            }

            let markdown = try SkillBoundedFileReader.readUTF8(
                from: markdownURL,
                maximumByteCount: SkillLocalFileLimits.maximumSkillFileBytes,
                label: "plugin SKILL.md at \(spec.path)"
            )
            let provisional = try SkillMarkdownParser.parse(
                markdown,
                builtIn: false,
                selected: spec.selected ?? selectedByDefault,
                group: "plugins",
                relativePath: "",
                source: ManagedSkillSource(kind: .plugin, location: ""),
                now: now()
            )
            let destinationDirectoryName = pluginSkillDirectoryName(
                pluginID: manifest.id,
                skillName: provisional.name
            )
            preparedSkills.append(
                SkillPluginPreparedSkill(
                    manifestPath: spec.path,
                    sourceDirectory: sourceDirectory,
                    destinationDirectoryName: destinationDirectoryName,
                    skill: try parsePluginManagedSkill(
                        markdown: markdown,
                        pluginID: manifest.id,
                        directoryName: destinationDirectoryName,
                        manifestPath: spec.path,
                        selected: spec.selected ?? selectedByDefault,
                        skillDirectoryURL: sourceDirectory
                    )
                )
            )
        }

        return SkillPluginInstallRequest(
            manifest: manifest,
            sourceLocation: sourceLocation,
            preparedSkills: preparedSkills,
            installedAt: state.installedPlugins.first { $0.id == manifest.id }?.installedAt,
            updatedAt: updatedAt
        )
    }

    public func uninstallSkillPlugin(id pluginID: String) async throws {
        try await prepare()
        let normalizedID = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw AgentError.invalidToolCall("Plugin id must not be empty")
        }
        try await withLibraryAccess(kind: .pluginMutation) {
            let state = try await stateStore.load()
            let plan = try SkillPluginMutationReducer().reduce(
                state: state,
                action: .uninstall(pluginIDs: [normalizedID], updatedAt: now())
            )
            try await workspaceTransaction.perform(plan.workspaceMutation)
        }
    }

    public func installedSkillPlugins() async throws -> [SkillPluginInstallation] {
        try await prepare()
        return try await withLibraryAccess(kind: .read) {
            try await stateStore.load().installedPlugins
        }
    }

    func parsePluginManagedSkill(
        markdown: String,
        pluginID: String,
        directoryName: String,
        manifestPath: String,
        selected: Bool,
        skillDirectoryURL: URL? = nil
    ) throws -> ManagedSkill {
        let parsed = try SkillMarkdownParser.parse(
            markdown,
            builtIn: false,
            selected: selected,
            group: "plugins",
            relativePath: "plugins/\(pluginID)/\(manifestPath)/SKILL.md",
            source: ManagedSkillSource(kind: .plugin, location: directoryName),
            now: now()
        )
        let logicalDirectoryName = try pluginSkillLogicalDirectoryName(manifestPath: manifestPath)
        try SkillMarkdownFrontmatterParser.validateDirectoryIdentity(
            skillName: parsed.name,
            directoryName: logicalDirectoryName
        )
        let supported: ManagedSkill
        if let skillDirectoryURL {
            let execution = try pluginExecutionSupport(forSkillDirectory: skillDirectoryURL, markdown: markdown)
            supported = parsed.applying(.executionSupportChanged(
                execution.support,
                reason: execution.reason,
                updatedAt: now()
            ))
        } else {
            supported = parsed
        }
        return supported
    }


    private func loadPluginManifest(from root: URL) throws -> SkillPluginManifest {
        for relativePath in SkillPluginManifestPaths.relativePaths {
            let manifestURL = root.appendingPathComponent(relativePath, isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            let data = try SkillBoundedFileReader.read(
                from: manifestURL,
                maximumByteCount: SkillLocalFileLimits.maximumManifestBytes,
                label: "Skill plugin manifest"
            )
            return try JSONDecoder.nativeAgent().decode(SkillPluginManifest.self, from: data)
        }
        throw AgentError.notFound("Skill plugin manifest not found")
    }

    private func validatePluginManifest(_ manifest: SkillPluginManifest) throws {
        guard manifest.schemaVersion == SkillPluginManifest.supportedSchemaVersion else {
            throw AgentError.invalidToolCall("Unsupported skill plugin schema: \(manifest.schemaVersion)")
        }
        for (label, value) in [
            ("id", manifest.id),
            ("name", manifest.name),
            ("version", manifest.version),
            ("description", manifest.description)
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AgentError.invalidToolCall("Skill plugin \(label) must not be empty")
        }
    }

    private func discoverPluginSkillSpecs(
        manifest: SkillPluginManifest,
        sourceRoot: URL
    ) throws -> [SkillPluginSkill] {
        if manifest.skills.isEmpty == false {
            return manifest.skills
        }

        let skillsRoot = sourceRoot.appendingPathComponent("skills", isDirectory: true)
        let discoveryRoot = fileManager.fileExists(atPath: skillsRoot.path) ? skillsRoot : sourceRoot
        return try fileManager.contentsOfDirectory(
            at: discoveryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { directory in
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            let markdownURL = directory.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: markdownURL.path) else { return nil }
            let relativePrefix = discoveryRoot == sourceRoot ? "" : "skills/"
            return SkillPluginSkill(path: "\(relativePrefix)\(directory.lastPathComponent)")
        }
    }

    private func validatedPluginSkillDirectory(
        relativePath: String,
        within root: URL
    ) throws -> URL {
        let sanitized = try sanitizeRelativeSkillPath(relativePath, kind: "plugin skill")
        let candidate = root.appendingPathComponent(sanitized, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.pathComponents.starts(with: normalizedRoot.pathComponents) else {
            throw AgentError.invalidToolCall("Plugin skill path escapes the plugin directory")
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentError.notFound("Plugin skill directory not found: \(relativePath)")
        }
        return candidate
    }

    private func pluginSkillLogicalDirectoryName(manifestPath: String) throws -> String {
        let sanitized = try sanitizeRelativeSkillPath(manifestPath, kind: "plugin skill")
        guard let directoryName = sanitized.split(separator: "/").last.map(String.init),
              !directoryName.isEmpty else {
            throw AgentError.invalidToolCall("Plugin skill path has no directory name")
        }
        return directoryName
    }

    private func pluginSkillDirectoryName(pluginID: String, skillName: String) -> String {
        let normalizedPluginID = normalizeSkillName(pluginID).ifEmpty("plugin")
        let normalizedSkillName = normalizeSkillName(skillName).ifEmpty("skill")
        return "\(normalizedPluginID)--\(normalizedSkillName)"
    }

    private func pluginExecutionSupport(
        forSkillDirectory skillDirectoryURL: URL,
        markdown: String
    ) throws -> (support: SkillExecutionSupport, reason: String) {
        if try pluginDirectoryContainsExternalExecutionFiles(skillDirectoryURL) {
            return (
                .unavailableOnMobile,
                "Installed with reference files, but script or external-tool execution is unavailable on iOS."
            )
        }

        if pluginMarkdownMentionsExternalExecution(markdown),
           pluginMarkdownDeclaresNativeMobileExecution(markdown) == false {
            return (
                .unavailableOnMobile,
                "Installed with reference files, but script or external-tool execution is unavailable on iOS."
            )
        }

        return (.available, "")
    }

    private func pluginDirectoryContainsExternalExecutionFiles(_ directoryURL: URL) throws -> Bool {
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isExecutableKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        )
        let externalExecutableExtensions: Set<String> = [
            "bat", "command", "js", "jl", "m", "php", "pl", "ps1", "py", "r", "rb", "sh", "swift", "ts"
        ]

        for fileURL in entries {
            let values = try fileURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isExecutableKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                return true
            }
            if values.isDirectory == true {
                if fileURL.lastPathComponent == "scripts" {
                    return true
                }
                if try pluginDirectoryContainsExternalExecutionFiles(fileURL) {
                    return true
                }
                continue
            }
            if externalExecutableExtensions.contains(fileURL.pathExtension.lowercased()) {
                return true
            }
            if values.isRegularFile == true, values.isExecutable == true {
                return true
            }
        }

        return false
    }

    private func pluginMarkdownMentionsExternalExecution(_ markdown: String) -> Bool {
        let lowered = markdown.lowercased()
        let markers = [
            "allowed-tools:",
            "run_js",
            "```bash",
            "```sh",
            "```shell",
            "```python",
            "```r",
            "```matlab",
            "python scripts/",
            "python3 scripts/",
            "bash scripts/",
            "sh scripts/",
            "pip install",
            "conda install",
            "npm install",
            "docker run",
            "rscript ",
            "matlab "
        ]
        return markers.contains { lowered.contains($0) }
    }

    private func pluginMarkdownDeclaresNativeMobileExecution(_ markdown: String) -> Bool {
        markdown.lowercased().contains("native-agent-mobile-native-execution: true")
    }
}
