import Foundation
import NativeAgentDomain
import Testing

@testable import NativeAgentTools

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Test
func toolPackReaderRejectsSymbolicLinksAtOpen() throws {
    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("regular")
    let link = root.appendingPathComponent("link")
    try Data("content".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: (any Error).self) {
        _ = try ToolPackBoundedFileReader.read(from: link, maximumByteCount: 64, label: "File")
    }
}

@Test
func toolPackReaderAcceptsExactLimitAndMaximumIntegerLimit() throws {
    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("regular")
    let data = Data("1234".utf8)
    try data.write(to: file)
    #expect(try ToolPackBoundedFileReader.read(from: file, maximumByteCount: 4, label: "File") == data)
    #expect(try ToolPackBoundedFileReader.read(from: file, maximumByteCount: Int.max, label: "File") == data)
    #expect(throws: AgentError.self) {
        _ = try ToolPackBoundedFileReader.read(from: file, maximumByteCount: 3, label: "File")
    }
}

@Test
func filesReadTextRejectsFIFOWithoutWaitingForAWriter() async throws {
    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fifo = root.appendingPathComponent("pipe")
    try #require(fifo.path.withCString { mkfifo($0, 0o600) } == 0)
    let executor = try #require(
        FilesToolPack(rootURL: root).executors().first {
            $0.definition.name == "files.readText"
        })
    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(name: "files.readText", arguments: ["path": "pipe"]),
            context: noopContext(root: root)
        )
    }
}

@Test(arguments: [false, true])
func toolPackReaderRejectsNonRegularNodes(fifo: Bool) throws {
    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let node = root.appendingPathComponent("node")
    if fifo {
        try #require(node.path.withCString { mkfifo($0, 0o600) } == 0)
    } else {
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
    }
    #expect(throws: AgentError.self) {
        _ = try ToolPackBoundedFileReader.read(from: node, maximumByteCount: 64, label: "File")
    }
}
