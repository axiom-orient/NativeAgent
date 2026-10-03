import Foundation
import NativeAgentDomain

extension FilesToolPack {
    var listDefinition: ToolDefinition {
        ToolDefinition(
            name: "files.list",
            description: "List directory contents inside the app sandbox subtree. Canonical instruction files are hidden from generic entries by default and returned separately as instructionDocuments.",
            capabilityID: .files,
            inputSchema: ToolSchema.object(
                properties: [
                    "path": ToolSchema.string(description: "Relative directory path.", minLength: 0),
                    "includeInstructionFiles": ToolSchema.boolean(description: "Include canonical instruction files in generic entries. Defaults to false.")
                ]
            ),
            approvalPolicy: configuration.readApprovalPolicy,
            effect: .readOnly,
            metadata: ["sensitiveData": .bool(true)]
        )
    }

    var searchDefinition: ToolDefinition {
        ToolDefinition(
            name: "files.search",
            description: "Search file and directory names recursively in bounded pages inside the app sandbox subtree. Pass nextCursor with the same inputs to continue. Canonical instruction files are excluded by default unless includeInstructionFiles is true.",
            capabilityID: .files,
            inputSchema: ToolSchema.object(
                properties: [
                    "path": ToolSchema.string(description: "Relative directory path.", minLength: 0),
                    "query": ToolSchema.string(description: "Case-insensitive substring to match in relative paths.", minLength: 1),
                    "limit": ToolSchema.integer(description: "Maximum matches in this page.", minimum: 1, maximum: configuration.maximumSearchResults),
                    "cursor": ToolSchema.string(description: "Opaque nextCursor from the preceding page for the same path and query.", minLength: 1, maxLength: FilesSearchRequest.maximumCursorBytes),
                    "includeInstructionFiles": ToolSchema.boolean(description: "Include canonical instruction files in search results. Defaults to false.")
                ],
                required: ["query"]
            ),
            approvalPolicy: configuration.readApprovalPolicy,
            effect: .readOnly,
            metadata: ["sensitiveData": .bool(true)]
        )
    }

    var readDefinition: ToolDefinition {
        ToolDefinition(
            name: "files.readText",
            description: "Read a UTF-8 text file inside the app sandbox subtree. When reading a regular file, the result also includes relevant instructionDocuments for the surrounding directory chain.",
            capabilityID: .files,
            inputSchema: ToolSchema.object(
                properties: [
                    "path": ToolSchema.string(description: "Relative file path.", minLength: 1)
                ],
                required: ["path"]
            ),
            approvalPolicy: configuration.readApprovalPolicy,
            effect: .readOnly,
            metadata: ["sensitiveData": .bool(true)]
        )
    }

    var writeDefinition: ToolDefinition {
        ToolDefinition(
            name: "files.writeText",
            description: "Write a UTF-8 text file inside the app sandbox subtree.",
            capabilityID: .files,
            inputSchema: ToolSchema.object(
                properties: [
                    "path": ToolSchema.string(description: "Relative file path.", minLength: 1),
                    "content": ToolSchema.string(description: "UTF-8 text content."),
                    "overwrite": ToolSchema.boolean(description: "Overwrite an existing file only when content differs. Defaults to false; identical existing content is skipped."),
                    "expectedSHA256": ToolSchema.string(description: "Optional lowercase SHA-256 of the current file returned by files.readText. When supplied, the write fails unless it still matches.", minLength: 64, maxLength: 64)
                ],
                required: ["path", "content"]
            ),
            approvalPolicy: .requireApproval,
            metadata: ["sensitiveData": .bool(true)]
        )
    }


    var replaceDefinition: ToolDefinition {
        ToolDefinition(
            name: "files.replaceText",
            description: "Atomically replace exactly one literal occurrence in a UTF-8 file when its current SHA-256 matches.",
            capabilityID: .files,
            inputSchema: ToolSchema.object(
                properties: [
                    "path": ToolSchema.string(description: "Relative file path.", minLength: 1),
                    "expectedSHA256": ToolSchema.string(description: "Lowercase SHA-256 returned by files.readText.", minLength: 64, maxLength: 64),
                    "old": ToolSchema.string(description: "Non-empty literal text that must occur exactly once.", minLength: 1),
                    "new": ToolSchema.string(description: "Replacement text.")
                ],
                required: ["path", "expectedSHA256", "old", "new"]
            ),
            approvalPolicy: .requireApproval,
            metadata: ["sensitiveData": .bool(true)]
        )
    }

    var deleteDefinition: ToolDefinition {
        ToolDefinition(
            name: "files.delete",
            description: "Delete a file or directory inside the app sandbox subtree.",
            capabilityID: .files,
            inputSchema: ToolSchema.object(
                properties: [
                    "path": ToolSchema.string(description: "Relative path.", minLength: 1),
                    "expectedSHA256": ToolSchema.string(
                        description: "Optional lowercase SHA-256 returned by files.readText. When supplied, deletion fails unless the current file still matches.",
                        minLength: 64,
                        maxLength: 64
                    )
                ],
                required: ["path"]
            ),
            approvalPolicy: .requireApproval,
            metadata: ["sensitiveData": .bool(true)]
        )
    }

    var initInstructionDefinition: ToolDefinition {
        ToolDefinition(
            name: "files.initInstruction",
            description: "Create a canonical instruction document from a built-in template. Project scope creates AGENTS.md. Local scope creates AGENTS.local.md.",
            capabilityID: .files,
            inputSchema: ToolSchema.object(
                properties: [
                    "directoryPath": ToolSchema.string(description: "Relative directory path where the instruction document should be created.", minLength: 0),
                    "scope": ToolSchema.string(description: "Instruction scope.", enum: [InstructionDocumentScope.project.rawValue, InstructionDocumentScope.local.rawValue]),
                    "overwrite": ToolSchema.boolean(description: "Overwrite an existing instruction document. Defaults to false.")
                ],
                required: ["scope"]
            ),
            approvalPolicy: .requireApproval,
            metadata: ["sensitiveData": .bool(true)]
        )
    }
}
