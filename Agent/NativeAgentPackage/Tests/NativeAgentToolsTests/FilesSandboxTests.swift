import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentTools

@Test
func filesSandboxRelativePathDoesNotMaskOutsideURLAsBasename() {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let root = temporaryDirectory.appendingPathComponent("native-agent-root", isDirectory: true)
    let outside = temporaryDirectory.appendingPathComponent("secret.txt")
    let resolver = FilesSandboxPathResolver(rootURL: root)

    let relativePath = resolver.relativePath(for: outside)

    #expect(relativePath != "secret.txt")
    #expect(relativePath == "<outside sandbox>")
    #expect(relativePath.contains(outside.path) == false)
}

@Test
func filesToolPackRejectsTraversal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.readText" })

    do {
        _ = try await executor.execute(
            call: ToolCall(name: "files.readText", arguments: ["path": "../secret.txt"]),
            context: noopContext(root: root)
        )
        Issue.record("Expected sandbox traversal rejection")
    } catch let error as AgentError {
        guard case .pathOutsideSandbox(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message.contains("escapes sandbox root"))
    }
}

#if os(Linux)
@Test
func filesToolPackRejectsSymlinkEscape() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let outside = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    let linkedDir = root.appendingPathComponent("linked", isDirectory: true)
    try fileManager.createSymbolicLink(at: linkedDir, withDestinationURL: outside)

    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.writeText" })

    do {
        _ = try await executor.execute(
            call: ToolCall(
                name: "files.writeText",
                arguments: [
                    "path": "linked/escape.txt",
                    "content": "oops"
                ]
            ),
            context: noopContext(root: root)
        )
        Issue.record("Expected symlink escape rejection")
    } catch let error as ToolPreflightFailure {
        #expect(error.code == .permissionDenied)
        #expect(error.cause == "Symlink traversal is not allowed.")
    }
}

@Test
func filesToolPackRejectsRootSymlink() async throws {
    let fileManager = FileManager.default
    let realRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: realRoot, withIntermediateDirectories: true)

    let symlinkRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)

    let pack = FilesToolPack(rootURL: symlinkRoot)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.list" })

    do {
        _ = try await executor.execute(
            call: ToolCall(name: "files.list", arguments: ["path": ""]),
            context: noopContext(root: symlinkRoot)
        )
        Issue.record("Expected root symlink rejection")
    } catch let error as AgentError {
        guard case .pathOutsideSandbox(let message) = error else {
            Issue.record("Unexpected AgentError: \(error)")
            return
        }
        #expect(message == "Root sandbox path cannot be a symlink.")
    }
}

@Test
func filesToolPackRejectsFinalPathSymlink() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let outside = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideFile = outside.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outsideFile)

    let linkedFile = root.appendingPathComponent("linked.txt")
    try fileManager.createSymbolicLink(at: linkedFile, withDestinationURL: outsideFile)

    let pack = FilesToolPack(rootURL: root)
    let readExecutor = try #require(pack.executors().first { $0.definition.name == "files.readText" })
    let writeExecutor = try #require(pack.executors().first { $0.definition.name == "files.writeText" })

    do {
        _ = try await readExecutor.execute(
            call: ToolCall(name: "files.readText", arguments: ["path": "linked.txt"]),
            context: noopContext(root: root)
        )
        Issue.record("Expected final-path symlink read rejection")
    } catch let error as AgentError {
        guard case .pathOutsideSandbox(let message) = error else {
            Issue.record("Unexpected AgentError during read: \(error)")
            return
        }
        #expect(message == "Symlink traversal is not allowed.")
    }

    do {
        _ = try await writeExecutor.execute(
            call: ToolCall(name: "files.writeText", arguments: ["path": "linked.txt", "content": "oops"]),
            context: noopContext(root: root)
        )
        Issue.record("Expected final-path symlink write rejection")
    } catch let error as ToolPreflightFailure {
        #expect(error.code == .permissionDenied)
        #expect(error.cause == "Symlink traversal is not allowed.")
    }
}
#endif

#if os(Linux) || os(macOS)
@Test
func filesToolPackRejectsDanglingSymlinkTraversal() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let danglingTarget = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let linkedDirectory = root.appendingPathComponent("dangling", isDirectory: true)
    try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: danglingTarget)

    let pack = FilesToolPack(rootURL: root)
    let executor = try #require(pack.executors().first { $0.definition.name == "files.writeText" })

    do {
        _ = try await executor.execute(
            call: ToolCall(
                name: "files.writeText",
                arguments: ["path": "dangling/escape.txt", "content": "oops"]
            ),
            context: noopContext(root: root)
        )
        Issue.record("Expected dangling symlink traversal rejection")
    } catch {
        // The exact AgentError message is covered by the existing symlink tests.
    }
}
#endif

@Test
func filesToolPackRoundTrip() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let pack = FilesToolPack(rootURL: root)
    let executors = Dictionary(uniqueKeysWithValues: pack.executors().map { ($0.definition.name, $0) })
    let context = noopContext(root: root)

    _ = try await executors["files.writeText"]!.execute(
        call: ToolCall(
            name: "files.writeText",
            arguments: [
                "path": "hello.txt",
                "content": "world"
            ]
        ),
        context: context
    )

    let read = try await executors["files.readText"]!.execute(
        call: ToolCall(
            name: "files.readText",
            arguments: [
                "path": "hello.txt"
            ]
        ),
        context: context
    )
    #expect(read.renderedContent == "world")

    let list = try await executors["files.list"]!.execute(
        call: ToolCall(name: "files.list", arguments: ["path": ""]),
        context: context
    )
    #expect(list.output.displayString().contains("hello.txt"))

    _ = try await executors["files.delete"]!.execute(
        call: ToolCall(name: "files.delete", arguments: ["path": "hello.txt"]),
        context: context
    )
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("hello.txt").path) == false)
}
