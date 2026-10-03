import Foundation

enum MemorySchemaVersion {
    static let current: Int64 = 2
}

/// The current projection includes durable forgetting and operation epochs.
/// Store rejects every other persisted schema before changing the database.
let schemaSQL = """
PRAGMA user_version=\(MemorySchemaVersion.current);

CREATE TABLE IF NOT EXISTS memory_schema (
    workspace_id TEXT PRIMARY KEY,
    schema_version INTEGER NOT NULL CHECK(schema_version = \(MemorySchemaVersion.current)),
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
\(memoryLifecycleSchemaSQL)
"""

let memoryRequiredTables = [
    "memory_schema", "memory_event", "memory_record", "memory_evidence",
    "memory_relation", "memory_checkpoint", "memory_record_fts", "memory_event_fts",
    "memory_scope_generation", "memory_forgotten_session", "memory_forgotten_message"
]

/// Contains only scope/source identity metadata, never forgotten content.
let memoryLifecycleSchemaSQL = """
CREATE TABLE memory_scope_generation (
    workspace_id TEXT NOT NULL, profile_id TEXT NOT NULL,
    user_id TEXT NOT NULL, namespace TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK(generation >= 0),
    PRIMARY KEY(workspace_id,profile_id,user_id,namespace)
) STRICT;
CREATE TABLE memory_forgotten_session (
    workspace_id TEXT NOT NULL, profile_id TEXT NOT NULL,
    user_id TEXT NOT NULL, namespace TEXT NOT NULL,
    source_session_id TEXT NOT NULL,
    message_count INTEGER NOT NULL CHECK(message_count >= 0),
    PRIMARY KEY(workspace_id,profile_id,user_id,namespace,source_session_id)
) STRICT;
CREATE TABLE memory_forgotten_message (
    workspace_id TEXT NOT NULL, profile_id TEXT NOT NULL,
    user_id TEXT NOT NULL, namespace TEXT NOT NULL,
    source_message_id TEXT NOT NULL,
    PRIMARY KEY(workspace_id,profile_id,user_id,namespace,source_message_id)
) STRICT;
"""
