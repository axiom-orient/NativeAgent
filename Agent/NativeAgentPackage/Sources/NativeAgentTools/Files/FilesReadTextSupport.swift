import Foundation
import NativeAgentDomain

struct FilesReadTextRequest: Sendable, Equatable {
    let path: String

    init(arguments: JSONValue) throws {
        self.path = try arguments.stringField("path")
    }
}

struct FilesReadTextResult: Sendable, Equatable {
    let text: String
    let byteCount: Int
    let sha256: String
    let instructionDocuments: [FilesInstructionDocumentSummary]
    let instructionScope: InstructionDocumentScope?

    var isInstructionDocument: Bool {
        instructionScope != nil
    }
}

struct FilesTextReader: Sendable {
    let pathResolver: FilesSandboxPathResolver
    let maximumReadBytes: Int
    let instructionCatalog: InstructionDocumentCatalog

    func readText(
        request: FilesReadTextRequest,
        fileManager: FileManager = .default
    ) throws -> FilesReadTextResult {
        let absoluteURL = try pathResolver.resolve(path: request.path, fileManager: fileManager)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: absoluteURL.path, isDirectory: &isDirectory), isDirectory.boolValue == false else {
            throw AgentError.notFound("File not found: \(request.path)")
        }

        let values = try absoluteURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumReadBytes {
            throw AgentError.budgetExceeded("File exceeds read budget of \(maximumReadBytes) bytes.")
        }

        let data = try ToolPackBoundedFileReader.read(
            from: absoluteURL,
            maximumByteCount: maximumReadBytes,
            label: "File"
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentError.accessDenied("File is not valid UTF-8 text.")
        }

        let classifier = FilesInstructionClassifier(
            resolver: pathResolver,
            catalog: instructionCatalog
        )
        let instructionDescriptor = classifier.descriptor(for: absoluteURL)
        let instructionDocuments: [FilesInstructionDocumentSummary]
        if instructionDescriptor == nil {
            instructionDocuments = FilesInstructionDocumentDiscovery(
                resolver: pathResolver,
                catalog: instructionCatalog
            ).relevantInstructionDocuments(
                for: absoluteURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
        } else {
            instructionDocuments = []
        }

        return FilesReadTextResult(
            text: text,
            byteCount: data.count,
            sha256: SHA256HexDigest.digest(data),
            instructionDocuments: instructionDocuments,
            instructionScope: instructionDescriptor?.scope
        )
    }
}
