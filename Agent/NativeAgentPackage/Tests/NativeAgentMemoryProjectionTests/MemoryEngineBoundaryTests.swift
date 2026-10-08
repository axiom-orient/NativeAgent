import Foundation
import Testing

@testable import NativeAgentMemoryProjection

private func memoryTestRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-memory-v1-\(label)-\(UUID().uuidString)", isDirectory: true)
}

@Test
func unsupportedWALModeIsRejectedBeforeSchemaCreation() throws {
    let database = try DB(":memory:")
    defer { try? database.close() }
    do {
        let store = try Store(database: database)
        try store.close()
        Issue.record("WAL refusal must not be treated as successful configuration")
        return
    } catch let error as AppError {
        #expect(error.code == "unsupported_journal_mode")
    }
    #expect(try database.query("PRAGMA journal_mode").first?.text(0) == "memory")
    #expect(try database.query("PRAGMA user_version").first?.int(0) == 0)
    #expect(try database.query("SELECT name FROM sqlite_master").isEmpty)
}

@Test
func v1SchemaRequiresStrictFtsAndForeignKeys() async throws {
    let root = memoryTestRoot("schema")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    let info = try await engine.initialize()
    let capabilities = try await engine.capabilities()
    #expect(capabilities.foreignKeys)
    #expect(capabilities.strictTables)
    #expect(capabilities.fts5)
    #expect(capabilities.sqliteVersion.isEmpty == false)
    try await engine.close()

    let store = try Store(path: info.databaseFile.path)
    #expect(store.workspaceID == info.workspaceID)
    let tables = Set(try store.db.query(
        "SELECT name FROM sqlite_master WHERE type='table' OR type='view'"
    ).compactMap { try? $0.text(0) })
    #expect(tables.contains("memory_schema"))
    #expect(tables.contains("memory_event"))
    #expect(tables.contains("memory_record"))
    #expect(tables.contains("memory_evidence"))
    #expect(tables.contains("memory_relation"))
    #expect(tables.contains("memory_checkpoint"))
    #expect(tables.contains("memory_record_fts"))
    #expect(tables.contains("memory_event_fts"))
    #expect(tables.contains("l0_messages") == false)
    let foreignKeyViolations = try store.db.query("PRAGMA foreign_key_check")
    let integrity = try store.db.query("PRAGMA integrity_check").first.map { try $0.text(0) } ?? ""
    #expect(foreignKeyViolations.isEmpty)
    #expect(integrity == "ok")
    try store.close()
}

@Test
func capabilityProbeLeavesNoTemporaryTables() async throws {
    let root = memoryTestRoot("capability-probe")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    let info = try await engine.initialize()
    try await engine.close()
    let store = try Store(path: info.databaseFile.path)
    let names = Set(try store.db.query(
        "SELECT name FROM sqlite_temp_master WHERE type='table'"
    ).map { try $0.text(0) })

    #expect(names.isDisjoint(with: [
        "__native_agent_strict_probe",
        "__native_agent_fts_probe",
        "__native_agent_capability_strict_probe",
        "__native_agent_capability_fts_probe"
    ]))
    try store.close()
}

@Test
func foreignDatabaseSchemaIsExplicitlyRejected() async throws {
    let root = memoryTestRoot("foreign-schema")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try DB(root.appendingPathComponent("memories.db").path)
    try database.exec("CREATE TABLE foreign_state(id TEXT)")
    #expect(try database.query("PRAGMA journal_mode").first?.text(0) == "delete")
    try database.close()

    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    do {
        _ = try await engine.initialize()
        Issue.record("expected a foreign schema failure")
    } catch let error as AgentMemoryError {
        #expect(error.kind == .storage)
        #expect(error.code == "unsupported_schema")
    }
    let unchanged = try DB(root.appendingPathComponent("memories.db").path)
    defer { try? unchanged.close() }
    #expect(try unchanged.query("PRAGMA journal_mode").first?.text(0) == "delete")
    #expect(try unchanged.query("SELECT name FROM sqlite_master WHERE type='table'").map { try $0.text(0) } == ["foreign_state"])
}

@Test
func nonV1UserVersionIsExplicitlyRejected() async throws {
    let root = memoryTestRoot("future-version")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    let info = try await engine.initialize()
    try await engine.close()

    let database = try DB(info.databaseFile.path)
    try database.exec("PRAGMA journal_mode=DELETE")
    try database.exec("PRAGMA user_version=\(Store.currentSchemaVersion + 1)")
    try database.close()

    let reopened = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: root)
    )
    do {
        _ = try await reopened.open()
        Issue.record("expected a future schema version failure")
    } catch let error as AgentMemoryError {
        #expect(error.kind == .storage)
        #expect(error.code == "unsupported_schema_version")
    }
    let unchanged = try DB(info.databaseFile.path)
    defer { try? unchanged.close() }
    #expect(try unchanged.query("PRAGMA journal_mode").first?.text(0) == "delete")
    #expect(try unchanged.query("PRAGMA user_version").first?.int(0) == Store.currentSchemaVersion + 1)
}

@Test
func workspacePathValidationRemainsBounded() {
    #expect(throws: AppError.self) { _ = try resolveDataDir("") }
    #expect(throws: AppError.self) { _ = try resolveDataDir("relative/memory") }

    let root = memoryTestRoot("paths")
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: AppError.self) {
        try ensureInside(root.path, root.appendingPathComponent("../escape").path)
    }
}

@Test(arguments: [false, true])
func missingV2IdentityIsRejectedWithoutChangingStoredMemory(populated: Bool) async throws {
    let root = memoryTestRoot("missing-identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = AgentMemoryConfiguration(dataDirectory: root)
    let engine = AgentMemoryEngine(configuration: configuration)
    let info = try await engine.initialize()
    let scope = AgentMemoryScope(profileID: "p", userID: "u", namespace: "shared")
    if populated {
        _ = try await engine.ingest(scope: scope, turns: [AgentMemoryTurn(
            id: "forgotten", role: .user, content: "Remember cobalt.",
            timestampMilliseconds: 1, sessionID: "s")])
        try await engine.forget(scope: scope)
        _ = try await engine.ingest(scope: scope, turns: [AgentMemoryTurn(
            id: "current", role: .user, content: "Remember amber.",
            timestampMilliseconds: 2, sessionID: "s")])
    }
    try await engine.close()

    let database = try DB(info.databaseFile.path)
    try database.exec("PRAGMA journal_mode=DELETE")
    try database.exec("DELETE FROM memory_schema")
    #expect(try database.query("SELECT COUNT(*) FROM memory_event").first?.int(0) == (populated ? 1 : 0))
    #expect(try database.query("SELECT COUNT(*) FROM memory_forgotten_message").first?.int(0) == (populated ? 1 : 0))
    try database.close()
    let corruptedBytes = try Data(contentsOf: info.databaseFile)

    for _ in 0..<2 {
        let reopened = AgentMemoryEngine(configuration: configuration)
        do {
            _ = try await reopened.open()
            Issue.record("existing v2 storage with no identity must not bootstrap")
        } catch let error as AgentMemoryError {
            #expect(error.kind == .storage)
            #expect(error.code == "invalid_workspace_identity")
        }
        try await reopened.close()
        #expect(try Data(contentsOf: info.databaseFile) == corruptedBytes)
    }
    let unchanged = try DB(info.databaseFile.path)
    defer { try? unchanged.close() }
    #expect(try unchanged.query("SELECT COUNT(*) FROM memory_schema").first?.int(0) == 0)
    #expect(try unchanged.query("PRAGMA journal_mode").first?.text(0) == "delete")
    #expect(try unchanged.query("PRAGMA integrity_check").first?.text(0) == "ok")
}

@Test
func workspaceIdentitySurvivesDirectoryMove() async throws {
    let parent = memoryTestRoot("move-parent")
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    let original = parent.appendingPathComponent("original", isDirectory: true)
    let moved = parent.appendingPathComponent("moved", isDirectory: true)

    let first = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: original)
    )
    let created = try await first.initialize()
    try await first.close()

    try FileManager.default.moveItem(at: original, to: moved)

    let reopened = AgentMemoryEngine(
        configuration: AgentMemoryConfiguration(dataDirectory: moved)
    )
    let opened = try await reopened.open()
    #expect(opened.workspaceID == created.workspaceID)
    #expect(opened.dataDirectory.standardizedFileURL == moved.standardizedFileURL)
    try await reopened.close()
}
