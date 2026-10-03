import Foundation
import NativeAgentDomain

extension FilesToolPack {
    func executeList(
        _ call: ToolCall,
        fileManager: FileManager = .default
    ) throws -> ToolResult {
        let request = FilesListRequest(arguments: call.arguments)
        let listing = try FilesDirectoryLister(
            pathResolver: pathResolver,
            instructionCatalog: instructionCatalog
        ).list(
            request: request,
            fileManager: fileManager
        )

        return ToolResult(
            callID: call.id,
            toolName: call.name,
            output: .object([
                "entries": .array(listing.entries),
                "instructionDocuments": try JSONValue.encode(listing.instructionDocuments)
            ])
        )
    }

    func executeSearch(
        _ call: ToolCall,
        fileManager: FileManager = .default
    ) throws -> ToolResult {
        let request = try FilesSearchRequest(
            arguments: call.arguments,
            maximumSearchResults: configuration.maximumSearchResults
        )
        let page = try FilesSearcher(
            pathResolver: pathResolver,
            maxVisitedNodes: configuration.maxVisitedNodes,
            instructionCatalog: instructionCatalog
        ).search(
            request: request,
            fileManager: fileManager
        )

        return ToolResult(
            callID: call.id,
            toolName: call.name,
            output: .object([
                "matches": .array(page.matches),
                "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null,
                "hasMore": .bool(page.nextCursor != nil),
            ])
        )
    }

    func executeReadText(
        _ call: ToolCall,
        fileManager: FileManager = .default
    ) throws -> ToolResult {
        let request = try FilesReadTextRequest(arguments: call.arguments)
        let result = try FilesTextReader(
            pathResolver: pathResolver,
            maximumReadBytes: configuration.maximumReadBytes,
            instructionCatalog: instructionCatalog
        ).readText(
            request: request,
            fileManager: fileManager
        )

        return ToolResult(
            callID: call.id,
            toolName: call.name,
            output: .object([
                "content": .string(result.text),
                "sha256": .string(result.sha256),
                "instructionDocuments": try JSONValue.encode(result.instructionDocuments),
                "isInstructionDocument": .bool(result.isInstructionDocument),
                "instructionScope": result.instructionScope.map { .string($0.rawValue) } ?? .null
            ]),
            metadata: [
                "byteCount": .integer(Int64(result.byteCount)),
                "sha256": .string(result.sha256)
            ]
        )
    }

    func executeWriteText(_ call: ToolCall) async throws -> ToolResult {
        let request = try filesPreflight(operation: "files.writeText.preflight", path: "<request>") {
            try FilesWriteTextRequest(arguments: call.arguments)
        }
        let result = try await mutationCoordinator.writeText(
            request: request,
            pathResolver: pathResolver,
            maximumWriteBytes: configuration.maximumWriteBytes,
            requireExpectedSHA256ForOverwrite: configuration.requireExpectedSHA256ForOverwrite
        )

        let content: String
        switch result.action {
        case .written:
            content = "Wrote \(result.byteCount) bytes to \(request.path)."
        case .skippedIdentical:
            content = "Skipped \(request.path); existing content is identical."
        }

        return .text(
            callID: call.id,
            toolName: call.name,
            content: content,
            metadata: [
                "byteCount": .integer(Int64(result.byteCount)),
                "action": .string(result.action.metadataValue),
                "sha256": .string(result.sha256),
                "previousSHA256": result.previousSHA256.map(JSONValue.string) ?? .null
            ]
        )
    }

    func executeReplaceText(_ call: ToolCall) async throws -> ToolResult {
        let request = try filesPreflight(operation: "files.replaceText.preflight", path: "<request>") {
            try FilesReplaceTextRequest(arguments: call.arguments)
        }
        let result = try await mutationCoordinator.replaceText(
            request: request,
            pathResolver: pathResolver,
            maximumMutationBytes: configuration.maximumWriteBytes
        )

        return .text(
            callID: call.id,
            toolName: call.name,
            content: "Replaced one occurrence in \(request.path).",
            metadata: [
                "byteCount": .integer(Int64(result.byteCount)),
                "action": .string("replaced"),
                "sha256": .string(result.sha256),
                "previousSHA256": .string(result.previousSHA256)
            ]
        )
    }

    func executeDelete(_ call: ToolCall) async throws -> ToolResult {
        let request = try filesPreflight(operation: "files.delete.preflight", path: "<request>") {
            try FilesDeleteRequest(arguments: call.arguments)
        }
        let result = try await mutationCoordinator.delete(
            request: request,
            pathResolver: pathResolver,
            maximumReadBytes: configuration.maximumReadBytes
        )
        return .text(
            callID: call.id,
            toolName: call.name,
            content: "Deleted \(request.path).",
            metadata: [
                "action": .string(result.deleted ? "deleted" : "already_absent"),
                "previousSHA256": result.previousSHA256.map(JSONValue.string) ?? .null,
                "verifiedAbsent": .bool(true)
            ]
        )
    }

    func executeInitInstruction(_ call: ToolCall) async throws -> ToolResult {
        let request = try filesPreflight(operation: "files.initInstruction.preflight", path: "<request>") {
            try FilesInstructionInitRequest(arguments: call.arguments)
        }
        let initialized = try await mutationCoordinator.initializeInstruction(
            request: request,
            pathResolver: pathResolver,
            catalog: instructionCatalog
        )

        return ToolResult(
            callID: call.id,
            toolName: call.name,
            output: .object([
                "content": .string("Created \(initialized.summary.relativePath)."),
                "instructionDocument": try JSONValue.encode(initialized.summary),
                "template": .string(initialized.content)
            ])
        )
    }
}

private extension FilesWriteTextAction {
    var metadataValue: String {
        switch self {
        case .written:
            return "written"
        case .skippedIdentical:
            return "skipped_identical"
        }
    }
}
