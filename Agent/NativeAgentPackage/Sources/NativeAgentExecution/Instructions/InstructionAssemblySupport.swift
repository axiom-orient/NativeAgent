import Foundation
import NativeAgentDomain

struct PromptInstructionAssemblyConfiguration: Sendable {
    let catalog: InstructionDocumentCatalog

    static let makiLike = PromptInstructionAssemblyConfiguration(
        catalog: .makiLike
    )
}

struct PromptInstructionFileAccess: Sendable {
    private static let maximumInstructionFileBytes = 1 * 1_024 * 1_024

    let readText: @Sendable (URL) throws -> String?

    static let live = PromptInstructionFileAccess(
        readText: { url in
            try readLiveText(at: url)
        }
    )

    private static func readLiveText(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            return nil
        }
        let handle = try FileHandle(forReadingFrom: url)
        let operation: Result<String, any Error>
        do {
            let data = try handle.read(
                upToCount: maximumInstructionFileBytes + 1
            ) ?? Data()
            guard data.count <= maximumInstructionFileBytes else {
                throw AgentError.budgetExceeded(
                    "Instruction file \(url.path) exceeds \(maximumInstructionFileBytes) bytes."
                )
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw AgentError.invariantViolation(
                    "Instruction file \(url.path) is not valid UTF-8."
                )
            }
            operation = .success(text)
        } catch {
            operation = .failure(error)
        }
        let closeError: (any Error)?
        do {
            try handle.close()
            closeError = nil
        } catch {
            closeError = error
        }
        return try OperationCleanupCompletionPolicy.resolve(
            operation: operation,
            cleanupError: closeError
        )
    }
}

struct PromptInstructionAssemblyContext: Sendable, Equatable {
    let environment: PromptInstructionEnvironment?
    let workingDirectoryURL: URL?
    let projectRootURL: URL?
    let globalInstructionsURL: URL?

    init(metadata: [String: JSONValue]) {
        let workingDirectory = metadata[PromptInstructionMetadataKeys.workingDirectory]?.stringValue
            .flatMap(Self.normalizedString)
        let platform = metadata[PromptInstructionMetadataKeys.platform]?.stringValue
            .flatMap(Self.normalizedString)
        let date = metadata[PromptInstructionMetadataKeys.date]?.stringValue
            .flatMap(Self.normalizedString)
        let explicitProjectRoot = metadata[PromptInstructionMetadataKeys.projectRootPath]?.stringValue
            .flatMap(Self.normalizedString)
        let globalInstructionsPath = metadata[PromptInstructionMetadataKeys.globalInstructionsPath]?.stringValue
            .flatMap(Self.normalizedString)

        self.environment = PromptInstructionEnvironment(
            workingDirectory: workingDirectory,
            platform: platform,
            date: date
        )

        self.workingDirectoryURL = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let projectRootPath = explicitProjectRoot ?? workingDirectory
        self.projectRootURL = projectRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.globalInstructionsURL = globalInstructionsPath.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    private static func normalizedString(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct PromptInstructionEnvironment: Sendable, Equatable {
    let workingDirectory: String?
    let platform: String?
    let date: String?

    var isEmpty: Bool {
        workingDirectory == nil && platform == nil && date == nil
    }
}

enum PromptInstructionDocumentKind: Sendable, Equatable {
    case project
    case local
    case global
}

struct PromptInstructionDocument: Sendable, Equatable {
    let heading: String
    let content: String
    let canonicalPath: String
    let kind: PromptInstructionDocumentKind
    let mergeMode: InstructionDocumentMergeMode
}

enum PromptInstructionMetadataKeys {
    static let workingDirectory = "workingDirectory"
    static let platform = "platform"
    static let date = "date"
    static let projectRootPath = "projectRootPath"
    static let globalInstructionsPath = "globalInstructionsPath"
}
