import NativeAgentDomain
import Foundation

extension SkillLibrary {
    @discardableResult
    public func importSkill(
        fromRemoteBaseURL remoteURLString: String,
        selected: Bool = true
    ) async throws -> ManagedSkill {
        try await prepare()
        let normalizedBaseURL = try normalizeRemoteSkillBaseURL(remoteURLString)
        let package = try await remoteFetcher.fetchSkillPackage(baseURL: normalizedBaseURL)
        guard let markdown = package.skillMarkdown else {
            throw AgentError.notFound("Remote skill package does not contain SKILL.md")
        }
        let provisional = try SkillMarkdownParser.parse(
            markdown,
            builtIn: false,
            selected: selected,
            group: "web",
            relativePath: "",
            source: ManagedSkillSource(kind: .web, location: ""),
            now: now()
        )
        let directoryName = normalizeSkillName(provisional.name)
        guard !directoryName.isEmpty else {
            throw AgentError.invalidToolCall(
                "Remote skill name must contain at least one alphanumeric character.")
        }

        let temporaryRoot = temporaryCustomSkillDirectory(named: directoryName)
        var importedSkill: ManagedSkill?
        var operationFailure: (any Error)?
        do {
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            try writeRemoteSkillPackage(package, to: temporaryRoot)

            let execution = remoteExecutionSupport(for: package, markdown: markdown)
            let parsed = try parseUserManagedSkill(
                markdown: markdown,
                directoryName: directoryName,
                selected: selected,
                group: "web",
                sourceKind: .web,
                relativePathPrefix: "web",
                executionSupport: execution.support,
                executionSupportReason: execution.reason
            )
            _ = try await commitDocumentSkill(
                parsed,
                from: temporaryRoot,
                directoryName: directoryName,
                replaceExistingImportedSkill: false
            )
            importedSkill = parsed
        } catch {
            operationFailure = error
        }

        try finishTemporarySkillWorkspace(
            temporaryRoot,
            operation: "Remote skill import",
            operationFailure: operationFailure,
            operationCommitted: importedSkill != nil
        )
        guard let importedSkill else {
            throw AgentError.invariantViolation(
                "Remote skill import completed without a result or an error")
        }
        return importedSkill
    }

    @discardableResult
    public func importSkill(
        fromDirectoryURL sourceDirectoryURL: URL,
        selected: Bool = true
    ) async throws -> ManagedSkill {
        try await prepare()
        let normalizedSource = sourceDirectoryURL.standardizedFileURL
        let markdownURL = normalizedSource.appendingPathComponent("SKILL.md", isDirectory: false)
        guard fileManager.fileExists(atPath: markdownURL.path) else {
            throw AgentError.notFound("SKILL.md not found in the selected directory")
        }
        let markdown = try SkillBoundedFileReader.readUTF8(
            from: markdownURL,
            maximumByteCount: SkillLocalFileLimits.maximumSkillFileBytes,
            label: "imported SKILL.md"
        )
        let provisional = try SkillMarkdownParser.parse(
            markdown,
            builtIn: false,
            selected: selected,
            group: "custom",
            relativePath: "",
            source: ManagedSkillSource(kind: .imported, location: ""),
            now: now()
        )
        let directoryName = normalizeSkillName(provisional.name)
        guard !directoryName.isEmpty else {
            throw AgentError.invalidToolCall(
                "Imported skill name must contain at least one alphanumeric character.")
        }
        let parsed = try parseUserManagedSkill(
            markdown: markdown,
            directoryName: directoryName,
            selected: selected
        )
        _ = try await commitDocumentSkill(
            parsed,
            from: normalizedSource,
            directoryName: directoryName,
            replaceExistingImportedSkill: false
        )
        return parsed
    }

    public func removeCustomSkill(named skillName: String) async throws {
        try await prepare()
        try await planAndCommitDocumentSkillRemoval(named: skillName)
        do {
            try await deleteSecret(for: skillName)
        } catch {
            throw SkillDocumentPostCommitFailure(
                skillName: skillName,
                effect: "secret cleanup",
                failure: error.localizedDescription
            )
        }
    }
}

extension SkillLibrary {
    fileprivate func writeRemoteSkillPackage(
        _ package: RemoteSkillPackage,
        to destinationURL: URL
    ) throws {
        for file in package.files {
            let relativePath = try sanitizeRelativeSkillPath(
                file.relativePath,
                kind: "remote skill file"
            )
            let fileURL = try validatedChildURL(named: relativePath, within: destinationURL)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.data.write(to: fileURL, options: .atomic)
        }
    }

    fileprivate func remoteExecutionSupport(
        for package: RemoteSkillPackage,
        markdown: String
    ) -> (support: SkillExecutionSupport, reason: String) {
        let hasScriptDirectory = package.files.contains { file in
            file.relativePath.split(separator: "/").contains("scripts")
        }
        let hasExecutableFile = package.files.contains { file in
            let path = file.relativePath.lowercased()
            return path.hasSuffix(".sh")
                || path.hasSuffix(".py")
                || path.hasSuffix(".js")
                || path.hasSuffix(".ts")
                || path.hasSuffix(".rb")
                || path.hasSuffix(".pl")
                || path.hasSuffix(".php")
        }
        let mentionsToolExecution =
            markdown.localizedCaseInsensitiveContains("run_js")
            || markdown.localizedCaseInsensitiveContains("run_intent")

        if hasScriptDirectory || hasExecutableFile || mentionsToolExecution {
            return (
                .unavailableOnMobile,
                "Installed with reference files, but script or external-tool execution is unavailable on iOS."
            )
        }
        return (.available, "")
    }
}
