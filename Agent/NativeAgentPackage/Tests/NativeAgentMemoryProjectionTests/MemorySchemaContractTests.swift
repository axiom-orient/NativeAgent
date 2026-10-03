import Foundation
import Dispatch
import Testing
@testable import NativeAgentMemoryProjection

private final class ConcurrentOpenResults: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [String] = []
    private var errors: [String] = []
    func append(_ result: Result<String, any Error>) {
        lock.lock(); defer { lock.unlock() }
        switch result {
        case .success(let value): identities.append(value)
        case .failure(let error): errors.append(String(describing: error))
        }
    }
    func snapshot() -> ([String], [String]) {
        lock.lock(); defer { lock.unlock() }; return (identities, errors)
    }
}

@Test func concurrentFirstOpenHasOneCompleteSchemaAndIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-first-open-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for attempt in 0..<12 {
        let path = root.appendingPathComponent("\(attempt).db").path
        let results = ConcurrentOpenResults()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            results.append(Result {
                let store = try Store(path: path)
                let identity = store.workspaceID
                try store.close()
                return identity
            })
        }
        let (ids, errors) = results.snapshot()
        #expect(errors.isEmpty, "\(errors)")
        #expect(ids.count == 2 && Set(ids).count == 1)
    }
}

private final class FailingInitialSchemaDatabase: Database {
    let base: DB
    init(_ path: String) throws { base = try DB(path) }
    func close() throws { try base.close() }
    func exec(_ sql: String, _ params: [SQLValue]) throws { try base.exec(sql, params) }
    func query(_ sql: String, _ params: [SQLValue]) throws -> [SQLRow] { try base.query(sql, params) }
    func changes() -> Int { base.changes() }
    func execScript(_ sql: String) throws {
        if sql == schemaSQL {
            let prefix = sql.components(separatedBy: "CREATE TABLE IF NOT EXISTS memory_event")[0]
            try base.execScript(prefix)
            throw AppError.storage("injected_schema_failure", "failure after first real DDL")
        }
        try base.execScript(sql)
    }
}

@Test func failedFirstOpenRollsBackPartialSchemaAndCanRetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-first-failure-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("memories.db").path
    let db = try FailingInitialSchemaDatabase(path)
    #expect(throws: (any Error).self) { _ = try Store(database: db) }
    #expect(try db.query("SELECT name FROM sqlite_master WHERE type='table'").isEmpty)
    #expect(try db.query("PRAGMA user_version").first?.int(0) == 0)
    try db.close()
    let retry = try Store(path: path)
    #expect(!retry.workspaceID.isEmpty)
    #expect(try retry.db.query("PRAGMA user_version").first?.int(0) == 2)
    try retry.close()
}

private func seedV1Database(_ path: String) throws {
    let db = try DB(path)
    defer { try? db.close() }
    try db.execScript(legacyMemorySchema)
    try db.exec("INSERT INTO memory_schema VALUES('workspace-old',1,42)")
    try db.exec("""
        INSERT INTO memory_event(id,workspace_id,profile_id,user_id,namespace,source_session_id,
            source_message_id,source_index,role,content,occurred_at_ms,content_hash,metadata_json)
        VALUES('event-old','workspace-old','p','u','n','s','message-old',0,'user','cobalt amount 48271',1000,'hash','{}')
        """)
    try db.exec("""
        INSERT INTO memory_checkpoint(workspace_id,profile_id,user_id,namespace,source_session_id,message_count,agent_revision,
            consolidated_rowid,last_source_message_id,last_source_content_hash,last_source_role,last_source_occurred_at_ms)
        VALUES('workspace-old','p','u','n','s',1,7,0,'message-old','raw-hash','user',1000)
        """)
}

@Test func requiredTableCannotBeReplacedByAView() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-view-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("memories.db")
    let current = try Store(path: file.path)
    try current.close()
    let db = try DB(file.path)
    try db.exec("PRAGMA journal_mode=DELETE")
    try db.exec("DROP TABLE memory_relation")
    try db.exec("CREATE VIEW memory_relation AS SELECT 'a' AS from_record_id, 'causes' AS relation, 'b' AS to_record_id")
    try db.close()
    let before = try Data(contentsOf: file)
    do {
        let store = try Store(path: file.path)
        try store.close()
        Issue.record("a same-name view cannot satisfy a required table")
    } catch let error as AppError {
        #expect(error.code == "incomplete_schema")
    }
    #expect(try Data(contentsOf: file) == before)
}

@Test func oldSchemaIsRejectedWithoutChangingIdentityDataOrJournal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-old-schema-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("memories.db")
    try seedV1Database(file.path)
    let db = try DB(file.path)
    try db.exec("PRAGMA journal_mode=DELETE")
    try db.close()
    let before = try Data(contentsOf: file)
    let results = ConcurrentOpenResults()
    DispatchQueue.concurrentPerform(iterations: 2) { _ in
        results.append(Result {
            do {
                let store = try Store(path: file.path)
                defer { try? store.close() }
                return store.workspaceID
            } catch let error as AppError {
                #expect(error.code == "unsupported_schema_version")
                throw error
            }
        })
    }
    let (ids, errors) = results.snapshot()
    #expect(ids.isEmpty)
    #expect(errors.count == 2)
    #expect(try Data(contentsOf: file) == before)
    let unchanged = try DB(file.path)
    defer { try? unchanged.close() }
    #expect(try unchanged.query("PRAGMA user_version").first?.int(0) == 1)
    #expect(try unchanged.query("SELECT workspace_id,schema_version FROM memory_schema").first?.text(0) == "workspace-old")
    #expect(try unchanged.query("SELECT content FROM memory_event").first?.text(0) == "cobalt amount 48271")
    #expect(try unchanged.query("SELECT agent_revision FROM memory_checkpoint").first?.int(0) == 7)
    #expect(try unchanged.query("PRAGMA integrity_check").first?.text(0) == "ok")
}

// Frozen pre-change v1 input, not constructed from the current production schema.
private let legacyMemorySchema = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=5000;
PRAGMA user_version=1;

CREATE TABLE IF NOT EXISTS memory_schema (
    workspace_id TEXT PRIMARY KEY,
    schema_version INTEGER NOT NULL CHECK(schema_version = 1),
    created_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS memory_event (
    rowid INTEGER PRIMARY KEY,
    id TEXT NOT NULL UNIQUE,
    workspace_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    namespace TEXT NOT NULL DEFAULT '',
    source_session_id TEXT NOT NULL,
    source_message_id TEXT NOT NULL,
    source_index INTEGER CHECK(source_index IS NULL OR source_index >= 0),
    role TEXT NOT NULL CHECK(role IN ('user','assistant','tool')),
    content TEXT NOT NULL,
    occurred_at_ms INTEGER NOT NULL,
    content_hash TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    UNIQUE(workspace_id, profile_id, user_id, namespace, source_message_id)
) STRICT;

CREATE INDEX IF NOT EXISTS ix_memory_event_scope_time
ON memory_event(workspace_id, profile_id, user_id, namespace, occurred_at_ms, rowid);
CREATE INDEX IF NOT EXISTS ix_memory_event_session
ON memory_event(workspace_id, profile_id, user_id, namespace, source_session_id, rowid);
CREATE INDEX IF NOT EXISTS ix_memory_event_session_position
ON memory_event(workspace_id, profile_id, user_id, namespace, source_session_id, source_index);

CREATE TABLE IF NOT EXISTS memory_record (
    rowid INTEGER PRIMARY KEY,
    id TEXT NOT NULL UNIQUE,
    workspace_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    namespace TEXT NOT NULL DEFAULT '',
    source_session_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('fact','episode','instruction','workflow','gotcha')),
    slot_key TEXT,
    content TEXT NOT NULL,
    valid_from_ms INTEGER,
    created_at_ms INTEGER NOT NULL,
    content_hash TEXT NOT NULL,
    UNIQUE(workspace_id, profile_id, user_id, namespace, kind, slot_key, content_hash)
) STRICT;

CREATE INDEX IF NOT EXISTS ix_memory_record_scope_kind
ON memory_record(workspace_id, profile_id, user_id, namespace, kind);
CREATE INDEX IF NOT EXISTS ix_memory_record_slot
ON memory_record(workspace_id, profile_id, user_id, namespace, slot_key, valid_from_ms)
WHERE slot_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS memory_evidence (
    record_id TEXT NOT NULL REFERENCES memory_record(id) ON DELETE CASCADE,
    event_id TEXT NOT NULL REFERENCES memory_event(id) ON DELETE CASCADE,
    quote TEXT NOT NULL,
    PRIMARY KEY(record_id, event_id, quote)
) STRICT;
CREATE INDEX IF NOT EXISTS ix_memory_evidence_event ON memory_evidence(event_id);

CREATE TABLE IF NOT EXISTS memory_relation (
    from_record_id TEXT NOT NULL REFERENCES memory_record(id) ON DELETE CASCADE,
    relation TEXT NOT NULL CHECK(relation IN ('supersedes','causes','depends_on')),
    to_record_id TEXT NOT NULL REFERENCES memory_record(id) ON DELETE CASCADE,
    PRIMARY KEY(from_record_id, relation, to_record_id),
    CHECK(from_record_id <> to_record_id)
) STRICT;
CREATE INDEX IF NOT EXISTS ix_memory_relation_to ON memory_relation(to_record_id, relation);
CREATE INDEX IF NOT EXISTS ix_memory_relation_from ON memory_relation(from_record_id, relation);

CREATE TABLE IF NOT EXISTS memory_checkpoint (
    workspace_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    namespace TEXT NOT NULL DEFAULT '',
    source_session_id TEXT NOT NULL,
    message_count INTEGER NOT NULL DEFAULT 0 CHECK(message_count >= 0),
    agent_revision INTEGER NOT NULL DEFAULT 0 CHECK(agent_revision >= 0),
    consolidated_rowid INTEGER NOT NULL DEFAULT 0 CHECK(consolidated_rowid >= 0),
    last_source_message_id TEXT NOT NULL DEFAULT '',
    last_source_content_hash TEXT NOT NULL DEFAULT '',
    last_source_role TEXT NOT NULL DEFAULT '',
    last_source_occurred_at_ms INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(workspace_id, profile_id, user_id, namespace, source_session_id)
) STRICT;

CREATE VIRTUAL TABLE IF NOT EXISTS memory_record_fts USING fts5(
    slot_key,
    kind,
    content,
    content='memory_record',
    content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
);
CREATE VIRTUAL TABLE IF NOT EXISTS memory_event_fts USING fts5(
    role,
    content,
    content='memory_event',
    content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS memory_record_ai AFTER INSERT ON memory_record BEGIN
    INSERT INTO memory_record_fts(rowid, slot_key, kind, content)
    VALUES(new.rowid, new.slot_key, new.kind, new.content);
END;
CREATE TRIGGER IF NOT EXISTS memory_record_au AFTER UPDATE ON memory_record BEGIN
    INSERT INTO memory_record_fts(memory_record_fts, rowid, slot_key, kind, content)
    VALUES('delete', old.rowid, old.slot_key, old.kind, old.content);
    INSERT INTO memory_record_fts(rowid, slot_key, kind, content)
    VALUES(new.rowid, new.slot_key, new.kind, new.content);
END;
CREATE TRIGGER IF NOT EXISTS memory_record_ad AFTER DELETE ON memory_record BEGIN
    INSERT INTO memory_record_fts(memory_record_fts, rowid, slot_key, kind, content)
    VALUES('delete', old.rowid, old.slot_key, old.kind, old.content);
END;
CREATE TRIGGER IF NOT EXISTS memory_event_ai AFTER INSERT ON memory_event BEGIN
    INSERT INTO memory_event_fts(rowid, role, content)
    VALUES(new.rowid, new.role, new.content);
END;
CREATE TRIGGER IF NOT EXISTS memory_event_au AFTER UPDATE ON memory_event BEGIN
    INSERT INTO memory_event_fts(memory_event_fts, rowid, role, content)
    VALUES('delete', old.rowid, old.role, old.content);
    INSERT INTO memory_event_fts(rowid, role, content)
    VALUES(new.rowid, new.role, new.content);
END;
CREATE TRIGGER IF NOT EXISTS memory_event_ad AFTER DELETE ON memory_event BEGIN
    INSERT INTO memory_event_fts(memory_event_fts, rowid, role, content)
    VALUES('delete', old.rowid, old.role, old.content);
END;
"""
