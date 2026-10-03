import Foundation
import NativeAgentDomain

struct PromptInstructionWorkspaceScanner: Sendable {
    let fileAccess: PromptInstructionFileAccess
    let catalog: InstructionDocumentCatalog

    func loadDocuments(context: PromptInstructionAssemblyContext) throws -> [PromptInstructionDocument] {
        var documents: [PromptInstructionDocument] = []

        if let projectRootURL = context.projectRootURL {
            documents.append(contentsOf: try loadProjectInstructionChain(
                projectRootURL: projectRootURL,
                workingDirectoryURL: context.workingDirectoryURL
            ))

            if let localInstructions = try loadLocalInstructions(
                workingDirectoryURL: context.workingDirectoryURL ?? projectRootURL,
                projectRootURL: projectRootURL
            ) {
                documents.append(localInstructions)
            }
        } else if let workingDirectoryURL = context.workingDirectoryURL,
                  let localInstructions = try loadLocalInstructions(
                    workingDirectoryURL: workingDirectoryURL,
                    projectRootURL: nil
                  ) {
            documents.append(localInstructions)
        }

        if let globalInstructionsURL = context.globalInstructionsURL,
           let globalInstructions = try loadDocument(
            at: globalInstructionsURL,
            heading: "Global instructions (\(globalInstructionsURL.path))",
            kind: .global
           ) {
            documents.append(globalInstructions)
        }

        return PromptInstructionDocumentMerger().merge(documents)
    }

    func loadProjectInstructionChain(
        projectRootURL: URL,
        workingDirectoryURL: URL?
    ) throws -> [PromptInstructionDocument] {
        var documents: [PromptInstructionDocument] = []
        for directoryURL in projectInstructionDirectories(
            projectRootURL: projectRootURL,
            workingDirectoryURL: workingDirectoryURL
        ) {
            guard let (descriptor, url, rawText) = try firstProjectInstruction(in: directoryURL) else {
                continue
            }
            if let document = loadDocument(
                rawText: rawText,
                url: url,
                heading: heading(
                    for: url,
                    descriptor: descriptor,
                    projectRootURL: projectRootURL
                ),
                kind: .project
            ) {
                documents.append(document)
            }
        }
        return documents
    }

    func firstProjectInstruction(in directoryURL: URL) throws -> (InstructionDocumentDescriptor, URL, String)? {
        for descriptor in catalog.projectDocuments {
            let candidate = directoryURL.appendingPathComponent(descriptor.relativePath, isDirectory: false)
            guard let text = try fileAccess.readText(candidate) else {
                continue
            }
            return (descriptor, candidate, text)
        }
        return nil
    }

    func loadLocalInstructions(
        workingDirectoryURL: URL,
        projectRootURL: URL?
    ) throws -> PromptInstructionDocument? {
        let url = workingDirectoryURL.appendingPathComponent(catalog.localDocument.relativePath, isDirectory: false)
        return try loadDocument(
            at: url,
            heading: heading(
                for: url,
                descriptor: catalog.localDocument,
                projectRootURL: projectRootURL
            ),
            kind: .local
        )
    }

    func loadDocument(
        at url: URL,
        heading: String,
        kind: PromptInstructionDocumentKind
    ) throws -> PromptInstructionDocument? {
        guard let rawText = try fileAccess.readText(url) else {
            return nil
        }
        return loadDocument(rawText: rawText, url: url, heading: heading, kind: kind)
    }

    func loadDocument(
        rawText: String,
        url: URL,
        heading: String,
        kind: PromptInstructionDocumentKind
    ) -> PromptInstructionDocument? {
        let parsed = PromptInstructionDocumentParser().parse(rawText)
        guard !parsed.content.isEmpty else {
            return nil
        }

        return PromptInstructionDocument(
            heading: heading,
            content: parsed.content,
            canonicalPath: url.resolvingSymlinksInPath().standardizedFileURL.path,
            kind: kind,
            mergeMode: parsed.mergeMode
        )
    }

    func heading(
        for url: URL,
        descriptor: InstructionDocumentDescriptor,
        projectRootURL: URL?
    ) -> String {
        let displayPath = displayPath(for: url, projectRootURL: projectRootURL)
        switch descriptor.scope {
        case .project:
            if projectRootURL != nil,
               displayPath != descriptor.relativePath {
                return "Subdirectory instructions (\(displayPath))"
            }
            return "Project instructions (\(displayPath))"
        case .local:
            return "Local instructions (\(displayPath))"
        }
    }

    func displayPath(for url: URL, projectRootURL: URL?) -> String {
        guard let projectRootURL else {
            return url.lastPathComponent
        }
        let standardizedRoot = projectRootURL.standardizedFileURL.path
        let standardizedURL = url.standardizedFileURL.path
        if standardizedURL == standardizedRoot {
            return url.lastPathComponent
        }
        let prefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        if standardizedURL.hasPrefix(prefix) {
            return String(standardizedURL.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    func projectInstructionDirectories(
        projectRootURL: URL,
        workingDirectoryURL: URL?
    ) -> [URL] {
        let standardizedRoot = projectRootURL.standardizedFileURL
        guard let workingDirectoryURL else {
            return [standardizedRoot]
        }

        let standardizedWorkingDirectory = workingDirectoryURL.standardizedFileURL
        let rootComponents = standardizedRoot.pathComponents
        let workingComponents = standardizedWorkingDirectory.pathComponents
        guard workingComponents.starts(with: rootComponents) else {
            return [standardizedRoot]
        }
        guard standardizedWorkingDirectory != standardizedRoot else {
            return [standardizedRoot]
        }

        var directories: [URL] = [standardizedRoot]
        var current = standardizedRoot
        for component in workingComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            directories.append(current)
        }
        return directories
    }
}
