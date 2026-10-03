import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Uses real files and the production state store; no provider or filesystem mocks.
@Test
func missingSkillSourceFailsBeforeCreatingDestination() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Skills", isDirectory: true)
    )
    let policy = SkillFileImportPolicy(fileManager: fileManager, pathPolicy: SkillPathPolicy(workspace: workspace))
    let destination = workspace.userSkillDirectoryURL(named: "missing")
    #expect(throws: (any Error).self) {
        try policy.copySkillDirectory(from: root.appendingPathComponent("gone"), to: destination)
    }
    #expect(!fileManager.fileExists(atPath: destination.path))
}

@Test
func missingSkillSourceCannotCommitAnEmptyReplacement() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Skills", isDirectory: true)
    )
    let target = workspace.userSkillDirectoryURL(named: "original")
    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    let originalBytes = Data("original skill".utf8)
    try originalBytes.write(to: target.appendingPathComponent("SKILL.md"))
    let stateStore = SkillStateStore(fileURL: root.appendingPathComponent("state.json"))
    let previous = SkillState(updatedAt: Date(timeIntervalSince1970: 1), selectionOverrides: ["original": true])
    let updated = SkillState(updatedAt: Date(timeIntervalSince1970: 2), selectionOverrides: ["original": false])
    try await stateStore.prepare()
    try await stateStore.save(previous)
    let pathPolicy = SkillPathPolicy(workspace: workspace)
    let executor = SkillWorkspaceTransactionExecutor(
        workspace: workspace,
        fileManager: fileManager,
        pathPolicy: pathPolicy,
        fileImportPolicy: SkillFileImportPolicy(fileManager: fileManager, pathPolicy: pathPolicy),
        stateStore: SkillStatePersistenceBoundary(store: stateStore)
    )
    let plan = SkillWorkspaceMutationPlan(
        previousState: previous,
        updatedState: updated,
        directoryMutations: [
            .init(directoryName: "original", contents: .copied(from: root.appendingPathComponent("gone")))
        ]
    )
    await #expect(throws: (any Error).self) {
        try await executor.perform(plan)
    }
    #expect(try await stateStore.load() == previous)
    #expect(try Data(contentsOf: target.appendingPathComponent("SKILL.md")) == originalBytes)
    #expect(
        !fileManager.fileExists(
            atPath: workspace.userSkillsRootURL.appendingPathComponent(".native-agent-skill-transaction").path))
}

@Test
func boundedSkillReaderRejectsSymbolicLinks() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let target = root.appendingPathComponent("actual.txt")
    let link = root.appendingPathComponent("link.txt")
    try Data("outside".utf8).write(to: target)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: (any Error).self) {
        _ = try SkillBoundedFileReader.read(from: link, maximumByteCount: 128, label: "test")
    }
}

@Test(arguments: [false, true])
func boundedSkillReaderRejectsNonRegularNodes(fifo: Bool) throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("node")
    if fifo {
        try #require(mkfifo(source.path, S_IRUSR | S_IWUSR) == 0)
    } else {
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
    }
    // No writer is opened for the FIFO. A blocking open would hang this test.
    #expect(throws: AgentError.self) {
        _ = try SkillBoundedFileReader.read(from: source, maximumByteCount: 128, label: "test")
    }
}

@Test(arguments: [0, 1, 4, 5])
func boundedSkillReaderEnforcesExactByteLimit(byteCount: Int) throws {
    let fileManager = FileManager.default
    let source = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = Data(repeating: 0x61, count: byteCount)
    try data.write(to: source)
    defer { try? fileManager.removeItem(at: source) }
    if byteCount <= 4 {
        #expect(try SkillBoundedFileReader.read(from: source, maximumByteCount: 4, label: "test") == data)
    } else {
        #expect(throws: AgentError.self) {
            _ = try SkillBoundedFileReader.read(from: source, maximumByteCount: 4, label: "test")
        }
    }
}

@Test
func boundedSkillReaderDoesNotOverflowAtMaximumIntegerLimit() throws {
    let fileManager = FileManager.default
    let source = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = Data("bounded allocation".utf8)
    try data.write(to: source)
    defer { try? fileManager.removeItem(at: source) }
    #expect(try SkillBoundedFileReader.read(from: source, maximumByteCount: Int.max, label: "test") == data)
}

@Test
func localSkillImportRejectsFIFOInsteadOfWaitingForAWriter() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("Source", isDirectory: true)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Skills", isDirectory: true)
    )
    try #require(mkfifo(source.appendingPathComponent("SKILL.md").path, S_IRUSR | S_IWUSR) == 0)
    let library = SkillLibrary(workspace: workspace)
    await #expect(throws: AgentError.self) {
        _ = try await library.importSkill(fromDirectoryURL: source)
    }
    #expect(
        !fileManager.fileExists(
            atPath: workspace.userSkillsRootURL.appendingPathComponent(".native-agent-skill-transaction").path))
}

@Test
func skillDirectoryCopyRejectsARegularFileAsItsRoot() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("file")
    try Data("not a directory".utf8).write(to: source)
    let workspace = SkillWorkspace(
        supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: root.appendingPathComponent("Skills", isDirectory: true)
    )
    let destination = workspace.userSkillDirectoryURL(named: "invalid")
    let policy = SkillFileImportPolicy(fileManager: fileManager, pathPolicy: SkillPathPolicy(workspace: workspace))
    #expect(throws: AgentError.self) {
        try policy.copySkillDirectory(from: source, to: destination)
    }
    #expect(!fileManager.fileExists(atPath: destination.path))
}

@Test
func skillStateStoreRejectsMissingOrUnsupportedV1Contract() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("state.json")
    let store = SkillStateStore(fileURL: fileURL)

    try Data("{}".utf8).write(to: fileURL)
    await #expect(throws: (any Error).self) {
        _ = try await store.load()
    }

    try Data(#"{"version":"native-agent.skill-state/99","updatedAt":0,"selectionOverrides":{},"remoteSkills":[],"installedPlugins":[]}"#.utf8).write(to: fileURL)
    await #expect(throws: (any Error).self) {
        _ = try await store.load()
    }
}

@Test
func skillStateStoreRejectsUnsupportedInMemoryContractBeforeWrite() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("state.json")
    let store = SkillStateStore(fileURL: fileURL)

    let invalid = SkillState(version: "native-agent.skill-state/99")
    await #expect(throws: AgentError.self) {
        try await store.save(invalid)
    }
    #expect(fileManager.fileExists(atPath: fileURL.path) == false)
}
