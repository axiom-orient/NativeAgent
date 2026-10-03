import Foundation
import NativeAgentDomain

public struct InstructionAssemblyPromptAugmentor: PromptAugmentor {
    private let fileAccess: PromptInstructionFileAccess
    private let configuration: PromptInstructionAssemblyConfiguration

    public init() {
        self.init(
            fileAccess: .live,
            configuration: .makiLike
        )
    }

    init(
        fileAccess: PromptInstructionFileAccess,
        configuration: PromptInstructionAssemblyConfiguration
    ) {
        self.fileAccess = fileAccess
        self.configuration = configuration
    }

    public func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
        let context = PromptInstructionAssemblyContext(metadata: request.metadata)
        let documents = try PromptInstructionWorkspaceScanner(
            fileAccess: fileAccess,
            catalog: configuration.catalog
        ).loadDocuments(context: context)

        return PromptInstructionAssemblyBuilder().build(
            basePrompt: request.normalizedBasePrompt,
            environment: context.environment,
            documents: documents
        )
    }
}

struct PromptInstructionAssemblyBuilder: Sendable {
    func build(
        basePrompt: String,
        environment: PromptInstructionEnvironment?,
        documents: [PromptInstructionDocument]
    ) -> String? {
        var sections: [String] = []

        if basePrompt.isEmpty == false {
            sections.append(basePrompt)
        }

        if let environmentSection = renderEnvironmentSection(environment) {
            sections.append(environmentSection)
        }

        sections.append(contentsOf: documents.map(renderDocumentSection(_:)))

        let prompt = sections
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private func renderEnvironmentSection(_ environment: PromptInstructionEnvironment?) -> String? {
        guard let environment,
              environment.isEmpty == false else {
            return nil
        }

        var lines: [String] = ["Environment:"]
        if let workingDirectory = environment.workingDirectory {
            lines.append("- Working directory: \(workingDirectory)")
        }
        if let platform = environment.platform {
            lines.append("- Platform: \(platform)")
        }
        if let date = environment.date {
            lines.append("- Date: \(date)")
        }
        return lines.joined(separator: "\n")
    }

    private func renderDocumentSection(_ document: PromptInstructionDocument) -> String {
        "\(document.heading):\n\(document.content)"
    }
}
