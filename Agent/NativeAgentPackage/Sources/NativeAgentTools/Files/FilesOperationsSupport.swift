import Foundation
import NativeAgentDomain

struct FilesListRequest: Sendable, Equatable {
    let path: String
    let includeInstructionFiles: Bool

    init(arguments: JSONValue) {
        self.path = arguments.optionalStringField("path") ?? ""
        self.includeInstructionFiles = arguments.objectValue?["includeInstructionFiles"]?.boolValue ?? false
    }
}

struct FilesDirectoryListing: Sendable, Equatable {
    let entries: [JSONValue]
    let instructionDocuments: [FilesInstructionDocumentSummary]
}

struct FilesDirectoryLister: Sendable {
    let pathResolver: FilesSandboxPathResolver
    let instructionCatalog: InstructionDocumentCatalog

    func list(
        request: FilesListRequest,
        fileManager: FileManager = .default
    ) throws -> FilesDirectoryListing {
        let absoluteURL = try pathResolver.resolve(path: request.path, fileManager: fileManager)

        if fileManager.fileExists(atPath: absoluteURL.path) == false, request.path.isEmpty {
            return FilesDirectoryListing(entries: [], instructionDocuments: [])
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: absoluteURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentError.notFound("Directory not found: \(request.path)")
        }

        let classifier = FilesInstructionClassifier(
            resolver: pathResolver,
            catalog: instructionCatalog
        )
        let discovery = FilesInstructionDocumentDiscovery(
            resolver: pathResolver,
            catalog: instructionCatalog
        )

        let entries = try fileManager.contentsOfDirectory(
            at: absoluteURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.path < $1.path }

        let renderedEntries = try entries.compactMap { url in
            try makeDirectoryEntry(
                for: url,
                includeInstructionFiles: request.includeInstructionFiles,
                classifier: classifier
            )
        }

        return FilesDirectoryListing(
            entries: renderedEntries,
            instructionDocuments: discovery.relevantInstructionDocuments(
                for: absoluteURL,
                fileManager: fileManager
            )
        )
    }

    private func makeDirectoryEntry(
        for url: URL,
        includeInstructionFiles: Bool,
        classifier: FilesInstructionClassifier
    ) throws -> JSONValue? {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        let instructionDescriptor = classifier.descriptor(for: url)

        if instructionDescriptor != nil,
           includeInstructionFiles == false {
            return nil
        }

        var object: [String: JSONValue] = [
            "name": .string(url.lastPathComponent),
            "isDirectory": .bool(values.isDirectory ?? false),
            "isRegularFile": .bool(values.isRegularFile ?? false),
            "isSymbolicLink": .bool(values.isSymbolicLink ?? false),
            "isInstructionDocument": .bool(instructionDescriptor != nil),
            "byteCount": values.fileSize.map { .integer(Int64($0)) } ?? .null
        ]

        if let instructionDescriptor {
            object["instructionScope"] = .string(instructionDescriptor.scope.rawValue)
        }

        return .object(object)
    }
}

struct FilesWriteTextRequest: Sendable, Equatable {
    let path: String
    let content: String
    let overwrite: Bool
    let expectedSHA256: String?

    init(arguments: JSONValue) throws {
        self.path = try arguments.stringField("path")
        self.content = try arguments.stringField("content")
        self.overwrite = arguments.objectValue?["overwrite"]?.boolValue ?? false
        if let value = arguments.objectValue?["expectedSHA256"] {
            switch value {
            case .string(let raw):
                self.expectedSHA256 = try FilesSHA256.validate(raw)
            case .null:
                self.expectedSHA256 = nil
            default:
                throw AgentError.invalidToolCall(
                    "expectedSHA256 must be a lowercase SHA-256 string or null"
                )
            }
        } else {
            self.expectedSHA256 = nil
        }
    }
}

enum FilesWriteTextAction: Sendable, Equatable {
    case written
    case skippedIdentical
}

struct FilesWriteTextResult: Sendable, Equatable {
    let byteCount: Int
    let action: FilesWriteTextAction
    let sha256: String
    let previousSHA256: String?
}

struct FilesDeleteRequest: Sendable, Equatable {
    let path: String
    let expectedSHA256: String?

    init(arguments: JSONValue) throws {
        self.path = try arguments.stringField("path")
        if let value = arguments.objectValue?["expectedSHA256"] {
            switch value {
            case .string(let raw):
                self.expectedSHA256 = try FilesSHA256.validate(raw)
            case .null:
                self.expectedSHA256 = nil
            default:
                throw AgentError.invalidToolCall(
                    "expectedSHA256 must be a lowercase SHA-256 string or null"
                )
            }
        } else {
            self.expectedSHA256 = nil
        }
    }
}

struct FilesDeleteResult: Sendable, Equatable {
    let deleted: Bool
    let previousSHA256: String?
}

extension FilesMutationCoordinator {
    func delete(
        request: FilesDeleteRequest,
        pathResolver: FilesSandboxPathResolver,
        maximumReadBytes: Int
    ) throws -> FilesDeleteResult {
        let operation = "files.delete.preflight"
        let absoluteURL = try filesPreflight(operation: operation, path: request.path) {
            try pathResolver.resolve(path: request.path, fileManager: fileManager)
        }

        guard absoluteURL != pathResolver.rootURL else {
            throw ToolPreflightFailure(
                code: .permissionDenied,
                operation: operation,
                cause: "Refusing to delete the root directory.",
                context: ["path": request.path]
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: absoluteURL.path, isDirectory: &isDirectory) else {
            if let expectedSHA256 = request.expectedSHA256 {
                throw ToolPreflightFailure(
                    code: .conflict,
                    operation: operation,
                    cause: "Expected file no longer exists.",
                    context: ["path": request.path, "expectedSHA256": expectedSHA256]
                )
            }
            return FilesDeleteResult(deleted: false, previousSHA256: nil)
        }

        var previousSHA256: String?
        if let expectedSHA256 = request.expectedSHA256 {
            guard isDirectory.boolValue == false else {
                throw ToolPreflightFailure(
                    code: .invalidInput,
                    operation: operation,
                    cause: "expectedSHA256 can only guard deletion of a regular file.",
                    context: ["path": request.path]
                )
            }
            let existingData = try filesPreflight(operation: operation, path: request.path) {
                try ToolPackBoundedFileReader.read(
                    from: absoluteURL,
                    maximumByteCount: maximumReadBytes,
                    label: "File deletion precondition"
                )
            }
            let actualSHA256 = SHA256HexDigest.digest(existingData)
            guard actualSHA256 == expectedSHA256 else {
                throw filesDigestConflict(
                    operation: operation,
                    path: request.path,
                    expected: expectedSHA256,
                    actual: actualSHA256
                )
            }
            previousSHA256 = actualSHA256
        }

        do {
            try fileManager.removeItem(at: absoluteURL)
        } catch {
            throw EffectFailure.outcomeUnknown(
                operation: "files.delete.commit",
                cause: error.localizedDescription,
                context: ["path": request.path]
            )
        }
        guard fileManager.fileExists(atPath: absoluteURL.path) == false else {
            throw EffectFailure.outcomeUnknown(
                operation: "files.delete.verify",
                cause: "Target still exists after delete returned.",
                context: ["path": request.path]
            )
        }
        return FilesDeleteResult(deleted: true, previousSHA256: previousSHA256)
    }
}
