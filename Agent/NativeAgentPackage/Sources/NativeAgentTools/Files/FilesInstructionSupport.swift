import Foundation
import NativeAgentDomain

struct FilesInstructionDocumentSummary: Codable, Sendable, Equatable {
    let relativePath: String
    let filename: String
    let scope: InstructionDocumentScope
}

struct FilesInstructionClassifier: Sendable {
    let resolver: FilesSandboxPathResolver
    let catalog: InstructionDocumentCatalog

    func descriptor(for url: URL) -> InstructionDocumentDescriptor? {
        let relativePath = resolver.relativePath(for: url)
        return catalog.descriptor(matchingRelativePath: relativePath)
    }

    func descriptor(forRelativePath relativePath: String) -> InstructionDocumentDescriptor? {
        catalog.descriptor(matchingRelativePath: relativePath)
    }
}

struct FilesInstructionDocumentDiscovery: Sendable {
    let resolver: FilesSandboxPathResolver
    let catalog: InstructionDocumentCatalog

    func relevantInstructionDocuments(
        for directoryURL: URL,
        fileManager: FileManager = .default
    ) -> [FilesInstructionDocumentSummary] {
        let standardizedDirectory = directoryURL.standardizedFileURL
        var summaries: [FilesInstructionDocumentSummary] = []
        var seenPaths: Set<String> = []

        for currentDirectory in directoriesFromRoot(to: standardizedDirectory) {
            if let summary = firstProjectInstruction(in: currentDirectory, fileManager: fileManager),
               seenPaths.insert(summary.relativePath).inserted {
                summaries.append(summary)
            }
        }

        if let localSummary = localInstruction(in: standardizedDirectory, fileManager: fileManager),
           seenPaths.insert(localSummary.relativePath).inserted {
            summaries.append(localSummary)
        }

        return summaries
    }

    private func firstProjectInstruction(
        in directoryURL: URL,
        fileManager: FileManager
    ) -> FilesInstructionDocumentSummary? {
        for descriptor in catalog.projectDocuments {
            let candidate = directoryURL.appendingPathComponent(descriptor.relativePath, isDirectory: false)
            guard fileManager.fileExists(atPath: candidate.path) else {
                continue
            }
            return makeSummary(url: candidate, scope: descriptor.scope)
        }
        return nil
    }

    private func localInstruction(
        in directoryURL: URL,
        fileManager: FileManager
    ) -> FilesInstructionDocumentSummary? {
        let candidate = directoryURL.appendingPathComponent(catalog.localDocument.relativePath, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return nil
        }
        return makeSummary(url: candidate, scope: catalog.localDocument.scope)
    }

    private func makeSummary(url: URL, scope: InstructionDocumentScope) -> FilesInstructionDocumentSummary {
        FilesInstructionDocumentSummary(
            relativePath: resolver.relativePath(for: url),
            filename: url.lastPathComponent,
            scope: scope
        )
    }

    private func directoriesFromRoot(to targetDirectoryURL: URL) -> [URL] {
        let standardizedRoot = resolver.rootURL.standardizedFileURL
        let standardizedTarget = targetDirectoryURL.standardizedFileURL
        let rootComponents = standardizedRoot.pathComponents
        let targetComponents = standardizedTarget.pathComponents

        guard targetComponents.starts(with: rootComponents) else {
            return [standardizedRoot]
        }
        guard standardizedTarget != standardizedRoot else {
            return [standardizedRoot]
        }

        var directories: [URL] = [standardizedRoot]
        var current = standardizedRoot
        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            directories.append(current)
        }
        return directories
    }
}

struct FilesInstructionInitRequest: Sendable, Equatable {
    let directoryPath: String
    let scope: InstructionDocumentScope
    let overwrite: Bool

    init(arguments: JSONValue) throws {
        self.directoryPath = arguments.optionalStringField("directoryPath") ?? ""

        let scopeString = try arguments.stringField("scope")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let scope = InstructionDocumentScope(rawValue: scopeString) else {
            throw AgentError.invalidToolCall("Unsupported instruction scope: \(scopeString)")
        }
        self.scope = scope
        self.overwrite = arguments.objectValue?["overwrite"]?.boolValue ?? false
    }
}

extension FilesMutationCoordinator {
    func initializeInstruction(
        request: FilesInstructionInitRequest,
        pathResolver: FilesSandboxPathResolver,
        catalog: InstructionDocumentCatalog
    ) throws -> (summary: FilesInstructionDocumentSummary, content: String) {
        let operation = "files.initInstruction.preflight"
        let directoryURL = try filesPreflight(operation: operation, path: request.directoryPath) {
            try pathResolver.resolve(path: request.directoryPath, fileManager: fileManager)
        }

        let descriptor: InstructionDocumentDescriptor = {
            switch request.scope {
            case .project:
                return catalog.canonicalProjectDocument
            case .local:
                return catalog.localDocument
            }
        }()

        let targetURL = directoryURL.appendingPathComponent(descriptor.relativePath, isDirectory: false)
        let relativePath = pathResolver.relativePath(for: targetURL)
        if fileManager.fileExists(atPath: targetURL.path), request.overwrite == false {
            throw ToolPreflightFailure(
                code: .conflict,
                operation: operation,
                cause: "Instruction document already exists.",
                context: ["path": relativePath]
            )
        }

        let content = renderTemplate(
            scope: request.scope,
            relativeDirectoryPath: normalizedDirectoryPath(request.directoryPath)
        )
        do {
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: targetURL, atomically: true, encoding: .utf8)
        } catch {
            throw EffectFailure.outcomeUnknown(
                operation: "files.initInstruction.commit",
                cause: error.localizedDescription,
                context: ["path": relativePath]
            )
        }

        let observed: String
        do {
            observed = try String(contentsOf: targetURL, encoding: .utf8)
        } catch {
            throw EffectFailure.outcomeUnknown(
                operation: "files.initInstruction.verify",
                cause: error.localizedDescription,
                context: ["path": relativePath]
            )
        }
        guard observed == content else {
            throw EffectFailure.outcomeUnknown(
                operation: "files.initInstruction.verify",
                cause: "Read-back content differs from the committed template.",
                context: ["path": relativePath]
            )
        }

        return (
            summary: FilesInstructionDocumentSummary(
                relativePath: relativePath,
                filename: targetURL.lastPathComponent,
                scope: request.scope
            ),
            content: content
        )
    }

    private func normalizedDirectoryPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "." : trimmed
    }

    private func renderTemplate(
        scope: InstructionDocumentScope,
        relativeDirectoryPath: String
    ) -> String {
        switch scope {
        case .project:
            return """
            ---
            native-agent-merge: append
            ---
            # Project Instructions

            ## Scope
            - Applies to: \(relativeDirectoryPath)

            ## Purpose
            - Describe what this directory or project owns.

            ## Rules
            - Keep rules specific, stable, and testable.
            - Add only directory-specific deltas here.
            - Do not restate parent instructions unless you intentionally override them.

            ## Override Policy
            - Default is `native-agent-merge: append`.
            - Use `native-agent-merge: replace-parent` to replace the nearest inherited instruction document.
            - Use `native-agent-merge: replace-project-chain` to replace all inherited project instruction documents.

            ## Constraints
            - Note platform, API, or boundary constraints.

            ## Verification
            - List the checks that must pass after changes.
            """
        case .local:
            return """
            ---
            native-agent-merge: append
            ---
            # Local Instructions

            ## Scope
            - Applies to: \(relativeDirectoryPath)

            ## Temporary Notes
            - Put short-lived or personal working notes here.
            - Remove stale notes when they stop being useful.

            ## Current Focus
            - Record the current task-specific constraints.

            ## Override Policy
            - Default is `native-agent-merge: append`.
            - Use `native-agent-merge: replace-parent` to replace the nearest inherited instruction document for this area.
            - Use `native-agent-merge: replace-project-chain` only when you intentionally want local rules to replace all project rules.

            ## Verification
            - List the checks to run while working in this area.
            """
        }
    }
}
