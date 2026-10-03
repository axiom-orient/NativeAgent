import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentTools

@Test
func filesWriteTextIsIdempotentForIdenticalContentAndRejectsSilentOverwrite() async throws {
    let root = makeToolPackTempRoot()
    let pack = FilesToolPack(rootURL: root)
    let write = try #require(pack.executors().first { $0.definition.name == "files.writeText" })
    let context = noopContext(root: root)

    _ = try await write.execute(
        call: ToolCall(name: "files.writeText", arguments: ["path": "same.txt", "content": "alpha"]),
        context: context
    )

    let skipped = try await write.execute(
        call: ToolCall(name: "files.writeText", arguments: ["path": "same.txt", "content": "alpha"]),
        context: context
    )
    #expect(skipped.metadata["action"]?.stringValue == "skipped_identical")
    #expect(skipped.renderedContent.contains("Skipped same.txt"))

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await write.execute(
            call: ToolCall(name: "files.writeText", arguments: ["path": "same.txt", "content": "beta"]),
            context: context
        )
    }

    let read = try #require(pack.executors().first { $0.definition.name == "files.readText" })
    let current = try await read.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "same.txt"]),
        context: context
    )
    let expectedSHA256 = try #require(current.metadata["sha256"]?.stringValue)
    _ = try await write.execute(
        call: ToolCall(
            name: "files.writeText",
            arguments: [
                "path": "same.txt",
                "content": "beta",
                "overwrite": true,
                "expectedSHA256": .string(expectedSHA256)
            ]
        ),
        context: context
    )

    let content = try String(contentsOf: root.appendingPathComponent("same.txt"), encoding: .utf8)
    #expect(content == "beta")
}

@Test
func filesDeleteTreatsMissingTargetAsSuccessButStillRejectsRootDelete() async throws {
    let root = makeToolPackTempRoot()
    let pack = FilesToolPack(rootURL: root)
    let delete = try #require(pack.executors().first { $0.definition.name == "files.delete" })
    let context = noopContext(root: root)

    _ = try await delete.execute(
        call: ToolCall(name: "files.delete", arguments: ["path": "missing.txt"]),
        context: context
    )

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await delete.execute(
            call: ToolCall(name: "files.delete", arguments: ["path": ""]),
            context: context
        )
    }
}


@Test
func filesDeleteSupportsDigestPreconditionAndVerifiesAbsence() async throws {
    let root = makeToolPackTempRoot()
    let target = root.appendingPathComponent("guarded-delete.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: target, options: .atomic)

    let pack = FilesToolPack(rootURL: root)
    let read = try #require(pack.executors().first { $0.definition.name == "files.readText" })
    let delete = try #require(pack.executors().first { $0.definition.name == "files.delete" })
    let context = noopContext(root: root)
    let observed = try await read.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "guarded-delete.txt"]),
        context: context
    )
    let digest = try #require(observed.metadata["sha256"]?.stringValue)

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await delete.execute(
            call: ToolCall(
                name: "files.delete",
                arguments: [
                    "path": "guarded-delete.txt",
                    "expectedSHA256": .string(String(repeating: "0", count: 64))
                ]
            ),
            context: context
        )
    }
    #expect(FileManager.default.fileExists(atPath: target.path))

    let result = try await delete.execute(
        call: ToolCall(
            name: "files.delete",
            arguments: [
                "path": "guarded-delete.txt",
                "expectedSHA256": .string(digest)
            ]
        ),
        context: context
    )
    #expect(result.metadata["previousSHA256"]?.stringValue == digest)
    #expect(result.metadata["verifiedAbsent"]?.boolValue == true)
    #expect(result.metadata["action"]?.stringValue == "deleted")
    #expect(FileManager.default.fileExists(atPath: target.path) == false)
}
