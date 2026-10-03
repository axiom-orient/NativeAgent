import Foundation
import NativeAgentDomain

package struct SkillSupportingFileSummary: Sendable, Hashable {
    var relativePath: String
    var byteCount: Int
    var preview: String?
    var truncated: Bool

    var jsonValue: JSONValue {
        .object([
            "relativePath": .string(relativePath),
            "byteCount": .integer(Int64(byteCount)),
            "preview": preview.map(JSONValue.string) ?? .null,
            "truncated": .bool(truncated)
        ])
    }

    var renderedContext: String {
        guard let preview, preview.isEmpty == false else {
            return "- `\(relativePath)` (\(byteCount) bytes)"
        }
        return """
        - `\(relativePath)` (\(byteCount) bytes\(truncated ? ", preview truncated" : ""))

        ```text
        \(preview)
        ```
        """
    }
}

extension SkillLibrary {
    public func makeSystemPrompt(basePrompt: String) async throws -> String {
        let selected = try await selectedSkills()
        try SkillPromptLimits.validate(selected)
        return SkillSystemPromptBuilder().build(basePrompt: basePrompt, selectedSkills: selected)
    }

    public func skillDirectoryURL(for skill: ManagedSkill) throws -> URL {
        switch skill.source.kind {
        case .bundled:
            guard let resourceRoot = bundle.resourceURL else {
                throw AgentError.notFound("Missing bundle resource root for skills")
            }
            return try bundledSkillDirectoryURL(
                for: skill.source.location,
                resourceRoot: resourceRoot
            )

        case .imported, .plugin, .web:
            let location = skill.source.location.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = workspace.userSkillsRootURL
                .appendingPathComponent(location, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            try validateWorkspaceURL(url)
            return url

        case .remote:
            return try normalizeRemoteSkillBaseURL(skill.source.location)
        }
    }

    public func resolveScriptURL(for skill: ManagedSkill, scriptName: String) throws -> URL {
        let script = try sanitizeRelativeSkillPath(
            scriptName.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("index.html"),
            kind: "script"
        )
        switch skill.source.kind {
        case .bundled, .imported, .plugin, .web:
            return try resolveLocalSkillFile(for: skill, subdirectory: "scripts", named: script, kind: "script")
        case .remote:
            return try remoteURL(baseURL: skill.source.location, pathComponent: "scripts/\(script)")
        }
    }

    public func resolveWebViewURL(for skill: ManagedSkill, urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentError.invalidToolCall("Web view url must not be empty")
        }

        if let url = URL(string: trimmed), url.scheme?.isEmpty == false {
            let validated: URL
            if skill.source.kind == .remote {
                validated = try pathPolicy.validateRemoteAbsoluteWebViewURL(url)
            } else {
                validated = try validateAbsoluteWebViewURL(url, for: skill)
            }
            if validated.isFileURL {
                guard fileManager.fileExists(atPath: validated.path) else {
                    throw AgentError.notFound("Missing skill asset: \(validated.lastPathComponent)")
                }
            }
            return validated
        }

        let relativePath = try sanitizeRelativeSkillPath(trimmed, kind: "asset")
        switch skill.source.kind {
        case .bundled, .imported, .plugin, .web:
            return try resolveLocalSkillFile(for: skill, subdirectory: "assets", named: relativePath, kind: "asset")
        case .remote:
            return try remoteURL(baseURL: skill.source.location, pathComponent: "assets/\(relativePath)")
        }
    }

    func readSupportingFile(
        for skill: ManagedSkill,
        relativePath: String,
        characterOffset: Int,
        maxCharacters: Int
    ) throws -> SkillSupportingFileRead {
        guard skill.source.kind != .remote else {
            throw AgentError.unsupportedSurface(
                "Remote Skill supporting files must be imported before deterministic reading."
            )
        }
        let safePath = try sanitizeRelativeSkillPath(relativePath, kind: "supporting file")
        guard safePath != "SKILL.md" else {
            throw AgentError.invalidToolCall("Use load_skill to read SKILL.md instructions.")
        }
        let root = try skillDirectoryURL(for: skill).standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = try validatedChildURL(named: safePath, within: root)
        if skill.source.kind == .imported || skill.source.kind == .plugin || skill.source.kind == .web {
            try validateWorkspaceURL(fileURL)
        }
        guard isPreviewableSupportingFile(fileURL) else {
            throw AgentError.unsupportedSurface(
                "read_skill_file supports text resources only: \(safePath)"
            )
        }
        let data = try SkillBoundedFileReader.read(
            from: fileURL,
            maximumByteCount: SkillLocalFileLimits.maximumSkillFileBytes,
            label: "Skill supporting file"
        )
        return try SkillSupportingFileRead.make(
            relativePath: safePath,
            data: data,
            characterOffset: characterOffset,
            maxCharacters: maxCharacters
        )
    }

    func supportingFiles(
        for skill: ManagedSkill,
        maxPreviewFiles: Int = 8,
        maxPreviewBytes: Int = 4_096
    ) throws -> [SkillSupportingFileSummary] {
        guard skill.source.kind != .remote else { return [] }
        let root = try skillDirectoryURL(for: skill).standardizedFileURL.resolvingSymlinksInPath()
        let files = try supportingFileURLs(in: root, root: root)

        var previewsRemaining = maxPreviewFiles
        return try files.sorted { $0.path < $1.path }.map { fileURL in
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let relativePath = fileURL.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            guard let byteCount = values.fileSize else {
                throw AgentError.persistenceFailure(
                    "Unable to determine supporting file size at \(fileURL.path)."
                )
            }
            let canPreview = previewsRemaining > 0 && isPreviewableSupportingFile(fileURL)
            let preview: String?
            let truncated: Bool
            if canPreview {
                let data = try readPrefix(of: fileURL, upTo: maxPreviewBytes)
                preview = String(data: data, encoding: .utf8)
                truncated = byteCount > data.count
                if preview != nil {
                    previewsRemaining -= 1
                }
            } else {
                preview = nil
                truncated = false
            }
            return SkillSupportingFileSummary(
                relativePath: relativePath,
                byteCount: byteCount,
                preview: preview,
                truncated: truncated
            )
        }
    }

    private func resolveLocalSkillFile(
        for skill: ManagedSkill,
        subdirectory: String,
        named name: String,
        kind: String
    ) throws -> URL {
        let base = try skillDirectoryURL(for: skill)
        let root = base.appendingPathComponent(subdirectory, isDirectory: true)
        let url = try validatedChildURL(named: name, within: root)
        if skill.source.kind == .imported || skill.source.kind == .plugin || skill.source.kind == .web {
            try validateWorkspaceURL(url)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw AgentError.notFound("Missing skill \(kind): \(name)")
        }
        return url
    }

    private func supportingFileURLs(in directoryURL: URL, root: URL) throws -> [URL] {
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var files: [URL] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let candidate = entry.standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.pathComponents.starts(with: root.pathComponents) else { continue }

            if values.isRegularFile == true {
                let relativePath = candidate.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                guard relativePath != "SKILL.md" else { continue }
                files.append(candidate)
            } else if values.isDirectory == true {
                files.append(contentsOf: try supportingFileURLs(in: candidate, root: root))
            }
        }
        return files
    }

    private func isPreviewableSupportingFile(_ fileURL: URL) -> Bool {
        let previewableExtensions: Set<String> = [
            "md", "markdown", "txt", "json", "yaml", "yml", "csv", "tsv", "xml", "html", "htm"
        ]
        return previewableExtensions.contains(fileURL.pathExtension.lowercased())
    }

    private func readPrefix(of fileURL: URL, upTo maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        let operation: Result<Data, any Error>
        do {
            operation = .success((try handle.read(upToCount: maxBytes)) ?? Data())
        } catch {
            operation = .failure(error)
        }
        let cleanupError: (any Error)?
        do {
            try handle.close()
            cleanupError = nil
        } catch {
            cleanupError = error
        }
        return try OperationCleanupCompletionPolicy.resolve(
            operation: operation,
            cleanupError: cleanupError
        )
    }


    private func bundledSkillDirectoryURL(
        for location: String,
        resourceRoot: URL
    ) throws -> URL {
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = resourceRoot.appendingPathComponent(trimmedLocation, isDirectory: true)
        if fileManager.fileExists(atPath: primary.path) {
            return primary.standardizedFileURL
        }
        throw AgentError.notFound("Missing bundled skill directory: \(trimmedLocation)")
    }
}
