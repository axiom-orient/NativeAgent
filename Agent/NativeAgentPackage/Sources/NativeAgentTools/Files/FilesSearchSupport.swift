import Foundation
import NativeAgentDomain

struct FilesSearchRequest: Sendable, Equatable {
    static let maximumCursorBytes = 16_384

    let path: String
    let query: String
    let limit: Int
    let includeInstructionFiles: Bool
    let cursor: String?

    init(arguments: JSONValue, maximumSearchResults: Int) throws {
        let object = try requiredObject(arguments, toolName: "files.search")
        try rejectUnknownKeys(
            object,
            allowed: ["path", "query", "limit", "includeInstructionFiles", "cursor"],
            toolName: "files.search"
        )
        if let value = object["path"] {
            guard let path = value.stringValue else {
                throw AgentError.invalidToolCall("files.search path must be a string.")
            }
            self.path = path
        } else {
            self.path = ""
        }
        self.query = try arguments.stringField("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            throw AgentError.invalidToolCall("files.search query must not be empty.")
        }
        let requestedLimit = try optionalBoundedInt(
            object["limit"],
            field: "limit",
            defaultValue: maximumSearchResults,
            range: 1...maximumSearchResults,
            toolName: "files.search"
        )
        self.limit = requestedLimit
        if let value = object["includeInstructionFiles"] {
            guard let include = value.boolValue else {
                throw AgentError.invalidToolCall("files.search includeInstructionFiles must be a boolean.")
            }
            self.includeInstructionFiles = include
        } else {
            self.includeInstructionFiles = false
        }
        if let value = object["cursor"] {
            guard let cursor = value.stringValue,
                  cursor.isEmpty == false,
                  cursor.utf8.count <= Self.maximumCursorBytes else {
                throw AgentError.invalidToolCall("files.search cursor is invalid.")
            }
            self.cursor = cursor
        } else {
            self.cursor = nil
        }
    }
}

struct FilesSearchPage: Sendable, Equatable {
    let matches: [JSONValue]
    let nextCursor: String?
}

struct FilesSearcher: Sendable {
    let pathResolver: FilesSandboxPathResolver
    let maxVisitedNodes: Int
    let instructionCatalog: InstructionDocumentCatalog

    func search(
        request: FilesSearchRequest,
        fileManager: FileManager = .default
    ) throws -> FilesSearchPage {
        let absoluteURL = try pathResolver.resolve(path: request.path, fileManager: fileManager)

        if fileManager.fileExists(atPath: absoluteURL.path) == false, request.path.isEmpty {
            return FilesSearchPage(matches: [], nextCursor: nil)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: absoluteURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentError.notFound("Directory not found: \(request.path)")
        }

        return try FilesSearchTraversal(
            resolver: pathResolver,
            maxVisitedNodes: maxVisitedNodes,
            instructionCatalog: instructionCatalog
        ).collectMatches(
            in: absoluteURL,
            query: request.query.lowercased(),
            limit: request.limit,
            cursor: request.cursor,
            includeInstructionFiles: request.includeInstructionFiles,
            fileManager: fileManager
        )
    }
}
