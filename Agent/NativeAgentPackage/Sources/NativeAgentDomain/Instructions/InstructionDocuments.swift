import LanguageModelCore
import Foundation

package enum InstructionDocumentScope: String, Codable, Sendable, Equatable, Hashable {
    case project
    case local
}

private func normalizedInstructionRelativePath(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\", with: "/")
}

package struct InstructionDocumentDescriptor: Codable, Sendable, Equatable, Hashable {
    package var relativePath: String
    package var scope: InstructionDocumentScope

    package init(
        relativePath: String,
        scope: InstructionDocumentScope
    ) {
        self.relativePath = normalizedInstructionRelativePath(relativePath)
        self.scope = scope
    }

    package var filename: String {
        URL(fileURLWithPath: relativePath).lastPathComponent
    }

    package func matches(relativePath candidate: String) -> Bool {
        normalizedInstructionRelativePath(candidate) == relativePath
    }

    package func matches(filename candidate: String) -> Bool {
        filename == candidate
    }
}

package struct InstructionDocumentCatalog: Codable, Sendable, Equatable, Hashable {
    package var projectDocuments: [InstructionDocumentDescriptor]
    package var localDocument: InstructionDocumentDescriptor

    package init(
        projectDocuments: [InstructionDocumentDescriptor],
        localDocument: InstructionDocumentDescriptor
    ) {
        self.projectDocuments = projectDocuments
        self.localDocument = localDocument
    }

    package static let makiLike = InstructionDocumentCatalog(
        projectDocuments: [
            InstructionDocumentDescriptor(relativePath: "AGENTS.md", scope: .project),
            InstructionDocumentDescriptor(relativePath: "CLAUDE.md", scope: .project),
            InstructionDocumentDescriptor(relativePath: ".github/copilot-instructions.md", scope: .project),
            InstructionDocumentDescriptor(relativePath: "COPILOT.md", scope: .project),
            InstructionDocumentDescriptor(relativePath: ".cursorrules", scope: .project),
            InstructionDocumentDescriptor(relativePath: ".windsurfrules", scope: .project),
            InstructionDocumentDescriptor(relativePath: ".clinerules", scope: .project),
            InstructionDocumentDescriptor(relativePath: "CONVENTIONS.md", scope: .project),
            InstructionDocumentDescriptor(relativePath: "GEMINI.md", scope: .project),
            InstructionDocumentDescriptor(relativePath: "CODING_AGENT.md", scope: .project)
        ],
        localDocument: InstructionDocumentDescriptor(relativePath: "AGENTS.local.md", scope: .local)
    )

    package var canonicalProjectDocument: InstructionDocumentDescriptor {
        projectDocuments.first ?? InstructionDocumentDescriptor(relativePath: "AGENTS.md", scope: .project)
    }

    package func descriptor(matchingRelativePath candidate: String) -> InstructionDocumentDescriptor? {
        let normalized = normalizedInstructionRelativePath(candidate)
        if localDocument.matches(relativePath: normalized) {
            return localDocument
        }
        if let exact = projectDocuments.first(where: { $0.matches(relativePath: normalized) }) {
            return exact
        }
        let filename = URL(fileURLWithPath: normalized).lastPathComponent
        if localDocument.matches(filename: filename) {
            return localDocument
        }
        return projectDocuments.first(where: { $0.matches(filename: filename) })
    }

    package func descriptor(matchingFilename filename: String) -> InstructionDocumentDescriptor? {
        if localDocument.matches(filename: filename) {
            return localDocument
        }
        return projectDocuments.first(where: { $0.matches(filename: filename) })
    }

}
