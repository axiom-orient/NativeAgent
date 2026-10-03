import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentTools

private func mutationContext(root: URL) -> ToolExecutionContext {
    ToolExecutionContext(
        sessionID: "mutation-session",
        sessionDirectoryURL: root,
        sandboxRootURL: root
    )
}

private func mutationRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-files-mutation-\(UUID().uuidString)", isDirectory: true)
}

private func strictMutationPack(root: URL, maximumWriteBytes: Int = 1_000_000) -> FilesToolPack {
    FilesToolPack(
        rootURL: root,
        configuration: FilesToolPackConfiguration(
            maximumWriteBytes: maximumWriteBytes,
            requireExpectedSHA256ForOverwrite: true
        )
    )
}

private func executor(
    named name: String,
    in pack: FilesToolPack
) throws -> any ToolExecutor {
    try #require(pack.executors().first { $0.definition.name == name })
}

private func stringMetadata(_ result: ToolResult, key: String) throws -> String {
    try #require(result.metadata[key]?.stringValue)
}


@Test
func sha256DigestMatchesStandardKnownVectors() {
    #expect(
        SHA256HexDigest.digest(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    #expect(
        SHA256HexDigest.digest("abc") ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
}

@Test
func defaultFileConfigurationRequiresDigestGuard() {
    #expect(FilesToolPackConfiguration().requireExpectedSHA256ForOverwrite)
    #expect(FilesToolPackConfiguration().maximumWriteBytes == 1_000_000)
}

@Test
func writeParserRejectsMalformedDigestTypeBeforeFilesystemMutation() async throws {
    let root = mutationRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("typed.txt")
    try Data("original".utf8).write(to: target, options: .atomic)
    let write = try executor(named: "files.writeText", in: strictMutationPack(root: root))

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await write.execute(
            call: ToolCall(
                name: "files.writeText",
                arguments: [
                    "path": "typed.txt",
                    "content": "changed",
                    "overwrite": true,
                    "expectedSHA256": .integer(42)
                ]
            ),
            context: mutationContext(root: root)
        )
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
}

@Test
func readTextReturnsStableContentDigest() async throws {
    let root = mutationRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("world".utf8).write(to: root.appendingPathComponent("value.txt"), options: .atomic)

    let read = try executor(named: "files.readText", in: FilesToolPack(rootURL: root))
    let result = try await read.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "value.txt"]),
        context: mutationContext(root: root)
    )

    let expected = "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7"
    #expect(result.output.objectValue?["sha256"]?.stringValue == expected)
    #expect(result.metadata["sha256"]?.stringValue == expected)
}

@Test
func guardedOverwriteRequiresCurrentDigestAndPreservesContentOnConflict() async throws {
    let root = mutationRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("guarded.txt")
    try Data("alpha".utf8).write(to: target, options: .atomic)

    let pack = strictMutationPack(root: root)
    let read = try executor(named: "files.readText", in: pack)
    let write = try executor(named: "files.writeText", in: pack)
    let context = mutationContext(root: root)
    let initial = try await read.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "guarded.txt"]),
        context: context
    )
    let initialDigest = try #require(initial.metadata["sha256"]?.stringValue)

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await write.execute(
            call: ToolCall(
                name: "files.writeText",
                arguments: ["path": "guarded.txt", "content": "beta", "overwrite": true]
            ),
            context: context
        )
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "alpha")

    let updated = try await write.execute(
        call: ToolCall(
            name: "files.writeText",
            arguments: [
                "path": "guarded.txt",
                "content": "beta",
                "overwrite": true,
                "expectedSHA256": .string(initialDigest)
            ]
        ),
        context: context
    )
    #expect(updated.metadata["previousSHA256"]?.stringValue == initialDigest)
    let updatedDigest = try stringMetadata(updated, key: "sha256")
    #expect(updatedDigest != initialDigest)
    #expect(try String(contentsOf: target, encoding: .utf8) == "beta")

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await write.execute(
            call: ToolCall(
                name: "files.writeText",
                arguments: [
                    "path": "guarded.txt",
                    "content": "gamma",
                    "overwrite": true,
                    "expectedSHA256": .string(initialDigest)
                ]
            ),
            context: context
        )
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "beta")
}

@Test
func replaceTextRequiresOneOccurrenceAndMatchingDigest() async throws {
    let root = mutationRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("replace.txt")
    try Data("hello world".utf8).write(to: target, options: .atomic)

    let pack = strictMutationPack(root: root)
    let read = try executor(named: "files.readText", in: pack)
    let replace = try executor(named: "files.replaceText", in: pack)
    let context = mutationContext(root: root)
    let before = try await read.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "replace.txt"]),
        context: context
    )
    let beforeDigest = try stringMetadata(before, key: "sha256")

    let replaced = try await replace.execute(
        call: ToolCall(
            name: "files.replaceText",
            arguments: [
                "path": "replace.txt",
                "expectedSHA256": .string(beforeDigest),
                "old": "world",
                "new": "NativeAgent"
            ]
        ),
        context: context
    )
    #expect(replaced.metadata["previousSHA256"]?.stringValue == beforeDigest)
    #expect(try String(contentsOf: target, encoding: .utf8) == "hello NativeAgent")

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await replace.execute(
            call: ToolCall(
                name: "files.replaceText",
                arguments: [
                    "path": "replace.txt",
                    "expectedSHA256": .string(beforeDigest),
                    "old": "NativeAgent",
                    "new": "agent"
                ]
            ),
            context: context
        )
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "hello NativeAgent")

    try Data("same same".utf8).write(to: target, options: .atomic)
    let duplicate = try await read.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "replace.txt"]),
        context: context
    )
    let duplicateDigest = try stringMetadata(duplicate, key: "sha256")
    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await replace.execute(
            call: ToolCall(
                name: "files.replaceText",
                arguments: [
                    "path": "replace.txt",
                    "expectedSHA256": .string(duplicateDigest),
                    "old": "same",
                    "new": "one"
                ]
            ),
            context: context
        )
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "same same")
}

@Test
func concurrentWritesWithSameDigestAllowExactlyOneCommit() async throws {
    let root = mutationRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("race.txt")
    try Data("initial".utf8).write(to: target, options: .atomic)

    let pack = strictMutationPack(root: root)
    let read = try executor(named: "files.readText", in: pack)
    let write = try executor(named: "files.writeText", in: pack)
    let context = mutationContext(root: root)
    let initial = try await read.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "race.txt"]),
        context: context
    )
    let digest = try stringMetadata(initial, key: "sha256")

    let firstCall = ToolCall(
        name: "files.writeText",
        arguments: [
            "path": "race.txt",
            "content": "first",
            "overwrite": true,
            "expectedSHA256": .string(digest)
        ]
    )
    let secondCall = ToolCall(
        name: "files.writeText",
        arguments: [
            "path": "race.txt",
            "content": "second",
            "overwrite": true,
            "expectedSHA256": .string(digest)
        ]
    )

    let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        group.addTask {
            do {
                _ = try await write.execute(call: firstCall, context: context)
                return true
            } catch {
                return false
            }
        }
        group.addTask {
            do {
                _ = try await write.execute(call: secondCall, context: context)
                return true
            } catch {
                return false
            }
        }
        var values: [Bool] = []
        for await value in group {
            values.append(value)
        }
        return values
    }

    #expect(outcomes.filter { $0 }.count == 1)
    let final = try String(contentsOf: target, encoding: .utf8)
    #expect(final == "first" || final == "second")
}

@Test
func mutationWriteBudgetFailsBeforeChangingExistingContent() async throws {
    let root = mutationRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("bounded.txt")
    try Data("old".utf8).write(to: target, options: .atomic)

    let pack = strictMutationPack(root: root, maximumWriteBytes: 3)
    let read = try executor(named: "files.readText", in: pack)
    let write = try executor(named: "files.writeText", in: pack)
    let context = mutationContext(root: root)
    let before = try await read.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "bounded.txt"]),
        context: context
    )
    let digest = try stringMetadata(before, key: "sha256")

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await write.execute(
            call: ToolCall(
                name: "files.writeText",
                arguments: [
                    "path": "bounded.txt",
                    "content": "longer",
                    "overwrite": true,
                    "expectedSHA256": .string(digest)
                ]
            ),
            context: context
        )
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "old")
}

@Test
func concurrentWriteAndDeleteWithSameDigestAllowExactlyOneCommit() async throws {
    let root = mutationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("write-delete-race.txt")
    try Data("initial".utf8).write(to: target, options: .atomic)

    let pack = strictMutationPack(root: root)
    let read = try executor(named: "files.readText", in: pack)
    let write = try executor(named: "files.writeText", in: pack)
    let delete = try executor(named: "files.delete", in: pack)
    let context = mutationContext(root: root)
    let initial = try await read.execute(
        call: ToolCall(name: "files.readText", arguments: ["path": "write-delete-race.txt"]),
        context: context
    )
    let digest = try stringMetadata(initial, key: "sha256")

    let writeCall = ToolCall(
        name: "files.writeText",
        arguments: [
            "path": "write-delete-race.txt",
            "content": "updated",
            "overwrite": true,
            "expectedSHA256": .string(digest)
        ]
    )
    let deleteCall = ToolCall(
        name: "files.delete",
        arguments: [
            "path": "write-delete-race.txt",
            "expectedSHA256": .string(digest)
        ]
    )

    let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        group.addTask {
            do {
                _ = try await write.execute(call: writeCall, context: context)
                return true
            } catch {
                return false
            }
        }
        group.addTask {
            do {
                _ = try await delete.execute(call: deleteCall, context: context)
                return true
            } catch {
                return false
            }
        }
        var values: [Bool] = []
        for await value in group { values.append(value) }
        return values
    }

    #expect(outcomes.filter { $0 }.count == 1)
    if FileManager.default.fileExists(atPath: target.path) {
        #expect(try String(contentsOf: target, encoding: .utf8) == "updated")
    }
}
