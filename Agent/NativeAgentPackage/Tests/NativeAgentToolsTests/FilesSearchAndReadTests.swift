import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentTools


@Test
func filesToolPackIsExcludedFromMemoryRetentionByDefault() {
    let pack = FilesToolPack(rootURL: makeToolPackTempRoot())
    #expect(pack.executors().allSatisfy {
        $0.definition.metadata["sensitiveData"]?.boolValue == true
    })
}

@Test
func filesToolPackSearchFindsNestedRelativePaths() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let pack = FilesToolPack(rootURL: root)
    let executors = Dictionary(uniqueKeysWithValues: pack.executors().map { ($0.definition.name, $0) })
    let context = noopContext(root: root)

    _ = try await executors["files.writeText"]!.execute(
        call: ToolCall(name: "files.writeText", arguments: ["path": "notes/meeting.txt", "content": "agenda"]),
        context: context
    )

    let result = try await executors["files.search"]!.execute(
        call: ToolCall(name: "files.search", arguments: ["query": "meeting"]),
        context: context
    )

    let matches = try #require(result.output.objectValue?["matches"]?.arrayValue)
    #expect(matches.contains(where: { $0.objectValue?["relativePath"]?.stringValue == "notes/meeting.txt" }))
}

@Test
func filesToolPackSearchContinuesAfterVisitedNodeBudget() async throws {
    let root = makeToolPackTempRoot()
    let pack = FilesToolPack(
        rootURL: root,
        configuration: FilesToolPackConfiguration(maximumSearchResults: 20, maxVisitedNodes: 2)
    )
    let executors = Dictionary(uniqueKeysWithValues: pack.executors().map { ($0.definition.name, $0) })
    let context = noopContext(root: root)

    _ = try await executors["files.writeText"]!.execute(
        call: ToolCall(name: "files.writeText", arguments: ["path": "a.txt", "content": "a"]),
        context: context
    )
    _ = try await executors["files.writeText"]!.execute(
        call: ToolCall(name: "files.writeText", arguments: ["path": "b.txt", "content": "b"]),
        context: context
    )
    _ = try await executors["files.writeText"]!.execute(
        call: ToolCall(name: "files.writeText", arguments: ["path": "c.txt", "content": "c"]),
        context: context
    )

    let first = try await executors["files.search"]!.execute(
        call: ToolCall(name: "files.search", arguments: ["query": ".txt"]),
        context: context
    )
    let firstMatches = try #require(first.output.objectValue?["matches"]?.arrayValue)
    let cursor = try #require(first.output.objectValue?["nextCursor"]?.stringValue)
    #expect(firstMatches.count == 2)

    let second = try await executors["files.search"]!.execute(
        call: ToolCall(name: "files.search", arguments: ["query": ".txt", "cursor": .string(cursor)]),
        context: context
    )
    let secondMatches = try #require(second.output.objectValue?["matches"]?.arrayValue)
    #expect(secondMatches.count == 1)
    #expect(second.output.objectValue?["nextCursor"] == .null)
}

@Test
func filesSearchDoesNotAdvertiseAnEmptyTerminalPage() async throws {
    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "one".write(
        to: root.appendingPathComponent("one.txt"),
        atomically: true,
        encoding: .utf8
    )
    let executor = try #require(
        FilesToolPack(
            rootURL: root,
            configuration: FilesToolPackConfiguration(maximumSearchResults: 1, maxVisitedNodes: 1)
        ).executors().first { $0.definition.name == "files.search" }
    )

    let result = try await executor.execute(
        call: ToolCall(name: "files.search", arguments: ["query": ".txt", "limit": 1]),
        context: noopContext(root: root)
    )
    #expect(result.output.objectValue?["matches"]?.arrayValue?.count == 1)
    #expect(result.output.objectValue?["nextCursor"] == .null)
    #expect(result.output.objectValue?["hasMore"]?.boolValue == false)
}

@Test
func filesSearchRejectsCursorFramesOutsideRequestedSubtree() async throws {
    let root = makeToolPackTempRoot()
    let approved = root.appendingPathComponent("approved", isDirectory: true)
    try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
    let forged: [String: Any] = [
        "version": 1,
        "rootPath": "approved",
        "query": ".txt",
        "includeInstructionFiles": false,
        "stack": [["path": "", "nextIndex": 0]],
    ]
    let cursor = try JSONSerialization.data(withJSONObject: forged).base64EncodedString()
    let executor = try #require(
        FilesToolPack(rootURL: root).executors().first { $0.definition.name == "files.search" }
    )

    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(
                name: "files.search",
                arguments: [
                    "path": "approved",
                    "query": ".txt",
                    "cursor": .string(cursor),
                ]
            ),
            context: noopContext(root: root)
        )
    }
}

@Test
func filesToolPackRejectsOutOfRangePageSizeInsteadOfClamping() async throws {
    let root = makeToolPackTempRoot()
    let executor = try #require(FilesToolPack(rootURL: root).executors().first { $0.definition.name == "files.search" })
    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(name: "files.search", arguments: ["query": "txt", "limit": 999]),
            context: noopContext(root: root)
        )
    }
    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(name: "files.search", arguments: ["query": "txt", "limit": "10"]),
            context: noopContext(root: root)
        )
    }
}

@Test
func filesToolPackReadDefinitionsFollowApprovalPolicyConfiguration() throws {
    let automaticPack = FilesToolPack(rootURL: makeToolPackTempRoot())
    let protectedPack = FilesToolPack(
        rootURL: makeToolPackTempRoot(),
        configuration: FilesToolPackConfiguration(readApprovalPolicy: .requireApproval)
    )

    let automaticDefinitions = Dictionary(uniqueKeysWithValues: automaticPack.executors().map { ($0.definition.name, $0.definition) })
    let protectedDefinitions = Dictionary(uniqueKeysWithValues: protectedPack.executors().map { ($0.definition.name, $0.definition) })

    #expect(automaticDefinitions["files.list"]?.approvalPolicy == .automatic)
    #expect(automaticDefinitions["files.search"]?.approvalPolicy == .automatic)
    #expect(automaticDefinitions["files.readText"]?.approvalPolicy == .automatic)
    #expect(protectedDefinitions["files.list"]?.approvalPolicy == .requireApproval)
    #expect(protectedDefinitions["files.search"]?.approvalPolicy == .requireApproval)
    #expect(protectedDefinitions["files.readText"]?.approvalPolicy == .requireApproval)
}

@Test
func filesToolPackRejectsAbsolutePathsAfterResolverExtraction() async throws {
    let root = makeToolPackTempRoot()
    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.readText" })

    do {
        let absolutePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret.txt")
            .path
        _ = try await executor.execute(
            call: ToolCall(name: "files.readText", arguments: ["path": .string(absolutePath)]),
            context: noopContext(root: root)
        )
        Issue.record("Expected absolute-path rejection")
    } catch let error as AgentError {
        guard case .pathOutsideSandbox(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message == "Absolute paths are not allowed.")
    }
}

@Test
func filesToolPackReadRejectsOversizedFiles() async throws {
    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root.appendingPathComponent("big.txt")
    try Data(repeating: 0x61, count: 5).write(to: fileURL, options: .atomic)

    let pack = FilesToolPack(
        rootURL: root,
        configuration: FilesToolPackConfiguration(maximumReadBytes: 4)
    )
    let executor = try #require(pack.executors().first { $0.definition.name == "files.readText" })

    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(name: "files.readText", arguments: ["path": "big.txt"]),
            context: noopContext(root: root)
        )
    }
}

@Test
func filesToolPackReadRejectsNonUTF8Content() async throws {
    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root.appendingPathComponent("binary.bin")
    try Data([0xFF, 0xFE, 0xFD]).write(to: fileURL, options: .atomic)

    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.readText" })

    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(name: "files.readText", arguments: ["path": "binary.bin"]),
            context: noopContext(root: root)
        )
    }
}

@Test
func filesToolPackSearchReturnsEmptyForMissingRootPath() async throws {
    let root = makeToolPackTempRoot()
    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.search" })

    let result = try await executor.execute(
        call: ToolCall(name: "files.search", arguments: ["query": "notes"]),
        context: noopContext(root: root)
    )

    let matches = try #require(result.output.objectValue?["matches"]?.arrayValue)
    #expect(matches.isEmpty)
}

@Test
func filesToolPackListSeparatesInstructionDocumentsFromGenericEntries() async throws {
    let root = makeToolPackTempRoot()
    let fileManager = FileManager.default
    let targetDirectory = root.appendingPathComponent("Sources/App", isDirectory: true)
    try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
    try "root rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "module rules".write(to: root.appendingPathComponent("Sources/AGENTS.md"), atomically: true, encoding: .utf8)
    try "print(1)".write(to: targetDirectory.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.list" })

    let result = try await executor.execute(
        call: ToolCall(name: "files.list", arguments: ["path": "Sources/App"]),
        context: noopContext(root: root)
    )

    let output = try #require(result.output.objectValue)
    let entries = try #require(output["entries"]?.arrayValue)
    let names = entries.compactMap { $0.objectValue?["name"]?.stringValue }
    #expect(names == ["main.swift"])

    let instructionDocuments = try #require(output["instructionDocuments"]?.arrayValue)
    let relativePaths = instructionDocuments.compactMap { $0.objectValue?["relativePath"]?.stringValue }
    #expect(relativePaths == ["AGENTS.md", "Sources/AGENTS.md"])
}

@Test
func filesToolPackReadTextSurfacesRelevantInstructionDocumentsAndInstructionFlag() async throws {
    let root = makeToolPackTempRoot()
    let fileManager = FileManager.default
    let targetDirectory = root.appendingPathComponent("Sources/App", isDirectory: true)
    try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
    try "root rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "module rules".write(to: root.appendingPathComponent("Sources/AGENTS.md"), atomically: true, encoding: .utf8)
    try "print(1)".write(to: targetDirectory.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.readText" })

    let regularResult = try await executor.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "Sources/App/main.swift"]),
        context: noopContext(root: root)
    )

    let regularOutput = try #require(regularResult.output.objectValue)
    #expect(regularOutput["content"]?.stringValue == "print(1)")
    #expect(regularOutput["isInstructionDocument"]?.boolValue == false)
    let regularInstructionDocuments = try #require(regularOutput["instructionDocuments"]?.arrayValue)
    let regularPaths = regularInstructionDocuments.compactMap { $0.objectValue?["relativePath"]?.stringValue }
    #expect(regularPaths == ["AGENTS.md", "Sources/AGENTS.md"])

    let instructionResult = try await executor.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "AGENTS.md"]),
        context: noopContext(root: root)
    )

    let instructionOutput = try #require(instructionResult.output.objectValue)
    #expect(instructionOutput["isInstructionDocument"]?.boolValue == true)
    let instructionDocuments = try #require(instructionOutput["instructionDocuments"]?.arrayValue)
    #expect(instructionDocuments.isEmpty)
    #expect(instructionOutput["instructionScope"]?.stringValue == InstructionDocumentScope.project.rawValue)
}

@Test
func filesToolPackSearchHidesInstructionDocumentsUnlessRequested() async throws {
    let root = makeToolPackTempRoot()
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try "root rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "notes".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.search" })

    let hiddenResult = try await executor.execute(
        call: ToolCall(name: "files.search", arguments: ["query": "agents"]),
        context: noopContext(root: root)
    )
    let hiddenMatches = try #require(hiddenResult.output.objectValue?["matches"]?.arrayValue)
    #expect(hiddenMatches.isEmpty)

    let visibleResult = try await executor.execute(
        call: ToolCall(name: "files.search", arguments: ["query": "agents", "includeInstructionFiles": true]),
        context: noopContext(root: root)
    )
    let visibleMatches = try #require(visibleResult.output.objectValue?["matches"]?.arrayValue)
    #expect(visibleMatches.count == 1)
    #expect(visibleMatches.first?.objectValue?["isInstructionDocument"]?.boolValue == true)
    #expect(visibleMatches.first?.objectValue?["instructionScope"]?.stringValue == InstructionDocumentScope.project.rawValue)
}

@Test
func filesToolPackInitInstructionCreatesCanonicalTemplatesAndRespectsOverwriteFlag() async throws {
    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.initInstruction" })

    let projectResult = try await executor.execute(
        call: ToolCall(name: "files.initInstruction", arguments: ["directoryPath": "Sources/App", "scope": .string(InstructionDocumentScope.project.rawValue)]),
        context: noopContext(root: root)
    )
    let projectOutput = try #require(projectResult.output.objectValue)
    #expect(projectOutput["content"]?.stringValue == "Created Sources/App/AGENTS.md.")
    let projectTemplate = try #require(projectOutput["template"]?.stringValue)
    #expect(projectTemplate.contains("---\nnative-agent-merge: append\n---"))
    #expect(projectTemplate.contains("# Project Instructions"))
    #expect(projectTemplate.contains("Do not restate parent instructions unless you intentionally override them."))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/App/AGENTS.md").path))

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await executor.execute(
            call: ToolCall(name: "files.initInstruction", arguments: ["directoryPath": "Sources/App", "scope": .string(InstructionDocumentScope.project.rawValue)]),
            context: noopContext(root: root)
        )
    }

    let localResult = try await executor.execute(
        call: ToolCall(name: "files.initInstruction", arguments: ["scope": .string(InstructionDocumentScope.local.rawValue)]),
        context: noopContext(root: root)
    )
    let localOutput = try #require(localResult.output.objectValue)
    #expect(localOutput["content"]?.stringValue == "Created AGENTS.local.md.")
    let localTemplate = try #require(localOutput["template"]?.stringValue)
    #expect(localTemplate.contains("---\nnative-agent-merge: append\n---"))
    #expect(localTemplate.contains("# Local Instructions"))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.local.md").path))
}
