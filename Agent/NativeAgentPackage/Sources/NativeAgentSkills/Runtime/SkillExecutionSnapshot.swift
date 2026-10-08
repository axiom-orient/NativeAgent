import Foundation
import NativeAgentDomain
import LanguageModelCore

/// Immutable, content-addressed projection of the exact selected Skill bytes used for execution.
///
/// The digest, parsed Skill metadata, prompt/tool inputs, and local presentation URLs originate from
/// the same captured bytes. Local snapshot files live under the Skill support root so durable tool
/// output never points at an operation-scoped temporary directory. Secrets remain outside the
/// snapshot by design and are resolved through the host-owned secret store.
package enum SkillExecutionSnapshotError: Error, Equatable, Sendable {
    case unpinnedRemoteSkill(String)
}

package final class SkillExecutionSnapshot: Sendable, SkillPromptSource {
    private static let digestDomain = "native-agent.skill-execution/1\n"

    package static var emptyDigest: String {
        SHA256HexDigest.digest(digestDomain)
    }

    package let selectedSkills: [ManagedSkill]
    package let digest: String

    private let rootURL: URL
    private let rootsBySkillName: [String: URL]
    private let pathPolicy: SkillPathPolicy

    private init(
        selectedSkills: [ManagedSkill],
        digest: String,
        rootURL: URL,
        rootsBySkillName: [String: URL]
    ) {
        self.selectedSkills = selectedSkills
        self.digest = digest
        self.rootURL = rootURL
        self.rootsBySkillName = rootsBySkillName
        self.pathPolicy = SkillPathPolicy(
            workspace: SkillWorkspace(supportRootURL: rootURL, userSkillsRootURL: rootURL)
        )
    }

    package static func capture(library: SkillLibrary) async throws -> SkillExecutionSnapshot {
        try await library.captureExecutionSnapshot()
    }

    static func captureSelectedSkills(
        _ selected: [ManagedSkill],
        sourceRoots: [String: URL],
        cacheRoot: URL,
        fileManager: FileManager
    ) throws -> SkillExecutionSnapshot {
        let stagingRoot = cacheRoot
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        do {
            var accumulator = SHA256Accumulator()
            accumulator.update(Data(digestDomain.utf8))
            var capturedSkills: [ManagedSkill] = []
            capturedSkills.reserveCapacity(selected.count)

            for (index, originalSkill) in selected.enumerated() {
                if originalSkill.source.kind == .remote {
                    throw SkillExecutionSnapshotError.unpinnedRemoteSkill(originalSkill.name)
                }

                guard let sourceRoot = sourceRoots[originalSkill.name] else {
                    throw AgentError.invariantViolation(
                        "Missing source root while capturing Skill execution snapshot: \(originalSkill.name)"
                    )
                }
                let destinationRoot = stagingRoot
                    .appendingPathComponent(String(format: "%04d", index), isDirectory: true)
                try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
                try copyTree(
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot,
                    fileManager: fileManager
                )

                let capturedSkill = try capturedSkill(
                    from: originalSkill,
                    snapshotRoot: destinationRoot
                )
                capturedSkills.append(capturedSkill)
                updateMetadataDigest(for: capturedSkill, accumulator: &accumulator)
                try hashTree(
                    root: destinationRoot.standardizedFileURL.resolvingSymlinksInPath(),
                    accumulator: &accumulator,
                    fileManager: fileManager
                )
            }

            let digest = accumulator.finalizeHex()
            let finalRoot = cacheRoot.appendingPathComponent(digest, isDirectory: true)
            try promoteSnapshot(
                stagingRoot: stagingRoot,
                finalRoot: finalRoot,
                capturedSkills: capturedSkills,
                digest: digest,
                fileManager: fileManager
            )
            let roots = Dictionary(uniqueKeysWithValues: capturedSkills.enumerated().map { index, skill in
                (skill.name, finalRoot.appendingPathComponent(String(format: "%04d", index), isDirectory: true))
            })
            return SkillExecutionSnapshot(
                selectedSkills: capturedSkills,
                digest: digest,
                rootURL: finalRoot,
                rootsBySkillName: roots
            )
        } catch {
            let captureError = error
            if fileManager.fileExists(atPath: stagingRoot.path) {
                do {
                    try fileManager.removeItem(at: stagingRoot)
                } catch {
                    throw SkillTemporaryWorkspaceFailure(
                        operation: "Skill execution snapshot capture",
                        operationCommitted: false,
                        operationFailure: captureError.localizedDescription,
                        cleanupFailure: error.localizedDescription
                    )
                }
            }
            throw captureError
        }
    }

    private static func capturedSkill(
        from original: ManagedSkill,
        snapshotRoot: URL
    ) throws -> ManagedSkill {
        let markdownURL = snapshotRoot.appendingPathComponent("SKILL.md", isDirectory: false)
        let markdown = try SkillBoundedFileReader.readUTF8(
            from: markdownURL,
            maximumByteCount: SkillLocalFileLimits.maximumSkillFileBytes,
            label: "snapshotted skill document \(markdownURL.path)"
        )
        let parsed = try SkillMarkdownParser.parse(
            markdown,
            builtIn: original.builtIn,
            selected: original.selected,
            group: original.group,
            relativePath: original.relativePath,
            source: original.source,
            now: original.updatedAt
        )
        guard parsed.name == original.name else {
            throw AgentError.invalidToolCall(
                "Skill identity changed during execution snapshot capture: \(original.name) -> \(parsed.name)"
            )
        }
        return ManagedSkill(
            version: original.version,
            name: parsed.name,
            description: parsed.description,
            instructions: parsed.instructions,
            builtIn: parsed.builtIn,
            selected: parsed.selected,
            requiresSecret: parsed.requiresSecret,
            requiresSecretDescription: parsed.requiresSecretDescription,
            homepage: parsed.homepage,
            capabilityRequirements: parsed.capabilityRequirements,
            defaultSelected: parsed.defaultSelected,
            group: parsed.group,
            relativePath: parsed.relativePath,
            excerpt: parsed.excerpt,
            source: parsed.source,
            executionSupport: original.executionSupport,
            executionSupportReason: original.executionSupportReason,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
    }

    private static func updateMetadataDigest(
        for skill: ManagedSkill,
        accumulator: inout SHA256Accumulator
    ) {
        let metadata = [
            skill.name,
            skill.description,
            skill.version,
            skill.instructions,
            skill.source.kind.rawValue,
            skill.source.location,
            skill.executionSupport.rawValue,
            skill.executionSupportReason,
            skill.capabilityRequirements.summary,
        ].joined(separator: "\u{0}")
        accumulator.update(Data(metadata.utf8))
        accumulator.update(Data([0]))
    }

    private static func promoteSnapshot(
        stagingRoot: URL,
        finalRoot: URL,
        capturedSkills: [ManagedSkill],
        digest: String,
        fileManager: FileManager
    ) throws {
        let manifestName = ".snapshot.sha256"
        let manifestURL = stagingRoot.appendingPathComponent(manifestName, isDirectory: false)
        try Data((digest + "\n").utf8).write(to: manifestURL, options: .atomic)

        if fileManager.fileExists(atPath: finalRoot.path) {
            try validateCachedSnapshot(
                at: finalRoot,
                capturedSkills: capturedSkills,
                digest: digest,
                fileManager: fileManager
            )
            try fileManager.removeItem(at: stagingRoot)
            return
        }

        do {
            try fileManager.moveItem(at: stagingRoot, to: finalRoot)
        } catch {
            let promotionError = error
            if fileManager.fileExists(atPath: finalRoot.path) {
                try validateCachedSnapshot(
                    at: finalRoot,
                    capturedSkills: capturedSkills,
                    digest: digest,
                    fileManager: fileManager
                )
                if fileManager.fileExists(atPath: stagingRoot.path) {
                    do {
                        try fileManager.removeItem(at: stagingRoot)
                    } catch {
                        throw SkillTemporaryWorkspaceFailure(
                            operation: "Skill execution snapshot promotion",
                            operationCommitted: true,
                            operationFailure: promotionError.localizedDescription,
                            cleanupFailure: error.localizedDescription
                        )
                    }
                }
                return
            }
            throw promotionError
        }
    }

    private static func validateCachedSnapshot(
        at root: URL,
        capturedSkills: [ManagedSkill],
        digest: String,
        fileManager: FileManager
    ) throws {
        let manifestURL = root.appendingPathComponent(".snapshot.sha256", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw AgentError.persistenceFailure(
                "Skill execution snapshot cache is missing its integrity manifest for \(digest)."
            )
        }
        let recorded = try String(contentsOf: manifestURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard recorded == digest else {
            throw AgentError.persistenceFailure(
                "Skill execution snapshot cache integrity mismatch for \(digest)."
            )
        }

        var accumulator = SHA256Accumulator()
        accumulator.update(Data(digestDomain.utf8))
        for (index, skill) in capturedSkills.enumerated() {
            updateMetadataDigest(for: skill, accumulator: &accumulator)
            let skillRoot = root.appendingPathComponent(
                String(format: "%04d", index),
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: skillRoot.path) else {
                throw AgentError.persistenceFailure(
                    "Skill execution snapshot cache is missing skill bytes for \(skill.name)."
                )
            }
            try hashTree(
                root: skillRoot.standardizedFileURL.resolvingSymlinksInPath(),
                accumulator: &accumulator,
                fileManager: fileManager
            )
        }
        guard accumulator.finalizeHex() == digest else {
            throw AgentError.persistenceFailure(
                "Skill execution snapshot cache content does not match digest \(digest)."
            )
        }
    }

    package func makeSystemPrompt(basePrompt: String) async throws -> String {
        try SkillPromptLimits.validate(selectedSkills)
        return SkillSystemPromptBuilder().build(basePrompt: basePrompt, selectedSkills: selectedSkills)
    }

    package func selectedSkill(named name: String) -> ManagedSkill? {
        selectedSkills.first { $0.name == name && $0.selected }
    }

    package func supportingFiles(
        for skill: ManagedSkill,
        maxPreviewFiles: Int = 8,
        maxPreviewBytes: Int = 4_096
    ) throws -> [SkillSupportingFileSummary] {
        let root = try root(for: skill)
        let files = try supportingFileURLs(in: root, root: root)
        var previewsRemaining = maxPreviewFiles

        return try files.sorted { $0.path < $1.path }.map { fileURL in
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let relativePath = fileURL.pathComponents
                .dropFirst(root.pathComponents.count)
                .joined(separator: "/")
            guard let byteCount = values.fileSize else {
                throw AgentError.persistenceFailure(
                    "Unable to determine snapshotted skill file size at \(fileURL.path)."
                )
            }
            let canPreview = previewsRemaining > 0 && Self.isPreviewable(fileURL)
            let preview: String?
            let truncated: Bool
            if canPreview {
                let data = try Self.readPrefix(fileURL, maxBytes: maxPreviewBytes)
                preview = String(data: data, encoding: .utf8)
                truncated = byteCount > data.count
                if preview != nil { previewsRemaining -= 1 }
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

    package func readSupportingFile(
        for skill: ManagedSkill,
        relativePath: String,
        characterOffset: Int,
        maxCharacters: Int
    ) throws -> SkillSupportingFileRead {
        let safePath = try pathPolicy.sanitizeRelativeSkillPath(relativePath, kind: "supporting file")
        guard safePath != "SKILL.md" else {
            throw AgentError.invalidToolCall("Use load_skill to read SKILL.md instructions.")
        }
        let skillRoot = try root(for: skill)
        let fileURL = try pathPolicy.validatedChildURL(named: safePath, within: skillRoot)
        guard Self.isPreviewable(fileURL) else {
            throw AgentError.unsupportedSurface(
                "read_skill_file supports text resources only: \(safePath)"
            )
        }
        let data = try SkillBoundedFileReader.read(
            from: fileURL,
            maximumByteCount: SkillLocalFileLimits.maximumSkillFileBytes,
            label: "Snapshotted Skill supporting file"
        )
        return try SkillSupportingFileRead.make(
            relativePath: safePath,
            data: data,
            characterOffset: characterOffset,
            maxCharacters: maxCharacters
        )
    }

    package func resolveScriptURL(for skill: ManagedSkill, scriptName: String) throws -> URL {
        let script = try pathPolicy.sanitizeRelativeSkillPath(
            scriptName.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("index.html"),
            kind: "script"
        )
        let scriptsRoot = try root(for: skill).appendingPathComponent("scripts", isDirectory: true)
        let url = try pathPolicy.validatedChildURL(named: script, within: scriptsRoot)
        guard FileManager().fileExists(atPath: url.path) else {
            throw AgentError.notFound("Missing snapshotted skill script: \(script)")
        }
        return url
    }

    package func readAccessURL(for skill: ManagedSkill) throws -> URL? {
        try root(for: skill)
    }

    package func resolveWebViewURL(for skill: ManagedSkill, urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentError.invalidToolCall("Web view url must not be empty")
        }
        let skillRoot = try root(for: skill)
        if let url = URL(string: trimmed), url.scheme?.isEmpty == false {
            if url.isFileURL {
                let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
                guard candidate.pathComponents.starts(with: skillRoot.pathComponents) else {
                    throw AgentError.invalidToolCall("Web view file url is outside the Skill execution snapshot")
                }
                guard FileManager().fileExists(atPath: candidate.path) else {
                    throw AgentError.notFound("Missing snapshotted skill asset: \(candidate.lastPathComponent)")
                }
                return candidate
            }
            let scheme = url.scheme?.lowercased() ?? ""
            guard ["https", "http", "data", "about"].contains(scheme) else {
                throw AgentError.invalidToolCall("Unsupported web view url scheme: \(scheme.ifEmpty("unknown"))")
            }
            return url
        }

        let relative = try pathPolicy.sanitizeRelativeSkillPath(trimmed, kind: "asset")
        let assetRoot = skillRoot.appendingPathComponent("assets", isDirectory: true)
        let url = try pathPolicy.validatedChildURL(named: relative, within: assetRoot)
        guard FileManager().fileExists(atPath: url.path) else {
            throw AgentError.notFound("Missing snapshotted skill asset: \(relative)")
        }
        return url
    }

    private func root(for skill: ManagedSkill) throws -> URL {
        guard let root = rootsBySkillName[skill.name] else {
            throw AgentError.notFound("Skill is not part of this execution snapshot: \(skill.name)")
        }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func supportingFileURLs(in directoryURL: URL, root: URL) throws -> [URL] {
        let entries = try FileManager().contentsOfDirectory(
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
                let relative = candidate.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                if relative != "SKILL.md" { files.append(candidate) }
            } else if values.isDirectory == true {
                files.append(contentsOf: try supportingFileURLs(in: candidate, root: root))
            }
        }
        return files
    }

    private static func copyTree(
        sourceRoot: URL,
        destinationRoot: URL,
        fileManager: FileManager
    ) throws {
        for file in try regularFiles(in: sourceRoot, fileManager: fileManager) {
            let relative = file.pathComponents
                .dropFirst(sourceRoot.pathComponents.count)
                .joined(separator: "/")
            let destination = destinationRoot.appendingPathComponent(relative, isDirectory: false)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw AgentError.persistenceFailure(
                    "Unable to create snapshotted skill file at \(destination.path)."
                )
            }

            let input = try FileHandle(forReadingFrom: file)
            let output: FileHandle
            do {
                output = try FileHandle(forWritingTo: destination)
            } catch {
                let outputOpenError = error
                do {
                    try input.close()
                } catch {
                    throw AgentError.persistenceFailure(
                        "Opening the Skill snapshot destination failed: \(outputOpenError); input descriptor cleanup failed: \(error)"
                    )
                }
                throw outputOpenError
            }
            var inputCloseAttempted = false
            var outputCloseAttempted = false
            do {
                while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
                inputCloseAttempted = true
                try input.close()
                outputCloseAttempted = true
                try output.close()
            } catch {
                let primary = error
                var cleanupFailures: [String] = []
                if !inputCloseAttempted {
                    inputCloseAttempted = true
                    do { try input.close() } catch { cleanupFailures.append("input: \(error)") }
                }
                if !outputCloseAttempted {
                    outputCloseAttempted = true
                    do { try output.close() } catch { cleanupFailures.append("output: \(error)") }
                }
                guard cleanupFailures.isEmpty else {
                    throw AgentError.persistenceFailure(
                        "Skill snapshot file copy failed: \(primary); descriptor cleanup failed: \(cleanupFailures.joined(separator: "; "))"
                    )
                }
                throw primary
            }
        }
    }

    private static func hashTree(
        root: URL,
        accumulator: inout SHA256Accumulator,
        fileManager: FileManager
    ) throws {
        for file in try regularFiles(in: root, fileManager: fileManager) {
            let relative = file.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            accumulator.update(Data(relative.utf8))
            accumulator.update(Data([0]))

            let input = try FileHandle(forReadingFrom: file)
            var closeAttempted = false
            do {
                while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    accumulator.update(chunk)
                }
                closeAttempted = true
                try input.close()
            } catch {
                let primary = error
                guard !closeAttempted else { throw primary }
                closeAttempted = true
                do {
                    try input.close()
                } catch {
                    throw AgentError.persistenceFailure(
                        "Skill snapshot hashing failed: \(primary); descriptor cleanup failed: \(error)"
                    )
                }
                throw primary
            }
            accumulator.update(Data([0]))
        }
    }

    private static func regularFiles(
        in root: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard root.isFileURL,
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
              ) else {
            throw AgentError.invalidConfiguration("Invalid local Skill snapshot root.")
        }

        var files: [URL] = []
        for case let candidate as URL in enumerator {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard normalized.pathComponents.starts(with: root.pathComponents) else {
                throw AgentError.invalidToolCall(
                    "Skill file escaped its source directory during snapshot capture."
                )
            }
            files.append(normalized)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func isPreviewable(_ fileURL: URL) -> Bool {
        ["md", "markdown", "txt", "json", "yaml", "yml", "csv", "tsv", "xml", "html", "htm"]
            .contains(fileURL.pathExtension.lowercased())
    }

    private static func readPrefix(_ fileURL: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        var closeAttempted = false
        do {
            let data = (try handle.read(upToCount: maxBytes)) ?? Data()
            closeAttempted = true
            try handle.close()
            return data
        } catch {
            let primary = error
            guard !closeAttempted else { throw primary }
            closeAttempted = true
            do {
                try handle.close()
            } catch {
                throw AgentError.persistenceFailure(
                    "Reading the Skill preview failed: \(primary); descriptor cleanup failed: \(error)"
                )
            }
            throw primary
        }
    }
}
