let sqliteSessionSchema = """
CREATE TABLE IF NOT EXISTS store_metadata (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY NOT NULL,
    revision INTEGER NOT NULL CHECK (revision >= 0),
    schema_version TEXT NOT NULL,
    title TEXT,
    status TEXT NOT NULL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    provider_id TEXT,
    model_id TEXT,
    metadata BLOB NOT NULL,
    context_checkpoint BLOB,
    wait_state BLOB,
    failure BLOB,
    last_signal BLOB,
    message_count INTEGER NOT NULL CHECK (message_count >= 0),
    artifact_count INTEGER NOT NULL CHECK (artifact_count >= 0)
);

CREATE INDEX IF NOT EXISTS sessions_updated_at_index
ON sessions(updated_at DESC, session_id ASC);

CREATE TABLE IF NOT EXISTS session_messages (
    session_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    message_id TEXT NOT NULL,
    payload BLOB NOT NULL,
    PRIMARY KEY (session_id, ordinal),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS session_artifacts (
    session_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    artifact_id TEXT NOT NULL,
    filename TEXT NOT NULL,
    payload BLOB NOT NULL,
    PRIMARY KEY (session_id, ordinal),
    UNIQUE (session_id, artifact_id),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS session_events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    created_at REAL NOT NULL,
    payload BLOB NOT NULL,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS session_events_order_index
ON session_events(session_id, sequence);

CREATE TABLE IF NOT EXISTS session_effects (
    session_id TEXT NOT NULL,
    scope TEXT NOT NULL,
    effect_key TEXT NOT NULL,
    status TEXT NOT NULL,
    payload BLOB NOT NULL,
    PRIMARY KEY (session_id, scope, effect_key),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
);
"""
