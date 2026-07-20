use std::collections::HashSet;

use tokio_rusqlite::rusqlite::{self, Connection, Transaction};

const V1_SCHEMA_SQL: &str = include_str!("schema.sql");

const V3_GENERATION_SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS generation_tasks (
    id                    TEXT PRIMARY KEY,
    conversation_id       TEXT NOT NULL,
    assistant_message_id  TEXT,
    status                TEXT NOT NULL,
    request_json          TEXT NOT NULL,
    priority              INTEGER NOT NULL DEFAULT 0,
    attempt_count         INTEGER NOT NULL DEFAULT 0,
    max_attempts          INTEGER NOT NULL DEFAULT 3,
    lease_owner           TEXT,
    lease_expires_at      INTEGER,
    checkpoint_json       TEXT,
    last_error            TEXT,
    created_at            INTEGER NOT NULL,
    updated_at            INTEGER NOT NULL,
    started_at            INTEGER,
    finished_at           INTEGER,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE,
    FOREIGN KEY (assistant_message_id) REFERENCES messages(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_generation_tasks_claim
    ON generation_tasks(status, priority ASC, created_at, lease_expires_at);
CREATE INDEX IF NOT EXISTS idx_generation_tasks_conversation
    ON generation_tasks(conversation_id, created_at);

CREATE TABLE IF NOT EXISTS generation_runs (
    id                TEXT PRIMARY KEY,
    task_id           TEXT NOT NULL,
    attempt           INTEGER NOT NULL,
    status            TEXT NOT NULL,
    worker_id         TEXT NOT NULL,
    checkpoint_json   TEXT,
    error             TEXT,
    started_at        INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL,
    finished_at       INTEGER,
    FOREIGN KEY (task_id) REFERENCES generation_tasks(id) ON DELETE CASCADE,
    UNIQUE(task_id, attempt)
);

CREATE INDEX IF NOT EXISTS idx_generation_runs_task
    ON generation_runs(task_id, attempt DESC);

CREATE TABLE IF NOT EXISTS provider_calls (
    id                TEXT PRIMARY KEY,
    run_id            TEXT NOT NULL,
    provider          TEXT NOT NULL,
    model             TEXT,
    status            TEXT NOT NULL,
    request_json      TEXT NOT NULL,
    response_json     TEXT,
    error             TEXT,
    created_at        INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL,
    finished_at       INTEGER,
    FOREIGN KEY (run_id) REFERENCES generation_runs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_provider_calls_run
    ON provider_calls(run_id, created_at);

CREATE TABLE IF NOT EXISTS generation_commands (
    id                TEXT PRIMARY KEY,
    task_id           TEXT NOT NULL,
    kind              TEXT NOT NULL,
    payload_json      TEXT,
    status            TEXT NOT NULL DEFAULT 'pending',
    created_at        INTEGER NOT NULL,
    acknowledged_at   INTEGER,
    FOREIGN KEY (task_id) REFERENCES generation_tasks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_generation_commands_pending
    ON generation_commands(task_id, status, created_at);

CREATE TABLE IF NOT EXISTS tool_executions (
    id                TEXT PRIMARY KEY,
    run_id            TEXT NOT NULL,
    tool_call_id      TEXT,
    tool_name         TEXT NOT NULL,
    status            TEXT NOT NULL,
    input_json        TEXT NOT NULL,
    output_json       TEXT,
    error             TEXT,
    created_at        INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL,
    finished_at       INTEGER,
    FOREIGN KEY (run_id) REFERENCES generation_runs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_tool_executions_run
    ON tool_executions(run_id, created_at);

CREATE TABLE IF NOT EXISTS generation_lifecycle_events (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id           TEXT NOT NULL,
    run_id            TEXT,
    event_type        TEXT NOT NULL,
    payload_json      TEXT,
    created_at        INTEGER NOT NULL,
    FOREIGN KEY (task_id) REFERENCES generation_tasks(id) ON DELETE CASCADE,
    FOREIGN KEY (run_id) REFERENCES generation_runs(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_generation_events_task
    ON generation_lifecycle_events(task_id, id);
"#;

const V4_OAUTH_LEASE_SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS oauth_refresh_leases (
    account_id        TEXT PRIMARY KEY,
    owner_id          TEXT NOT NULL,
    lease_expires_at  INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL
);
"#;

const V5_GENERATION_ORDER_SCHEMA_SQL: &str = r#"
DROP INDEX IF EXISTS idx_generation_tasks_claim;
CREATE INDEX idx_generation_tasks_claim
    ON generation_tasks(status, priority ASC, created_at, lease_expires_at);
"#;

pub const LATEST_SCHEMA_VERSION: i64 = 5;

pub fn migrate(connection: &mut Connection) -> rusqlite::Result<()> {
    let current_version =
        connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
    if current_version > LATEST_SCHEMA_VERSION {
        return Err(rusqlite::Error::InvalidParameterName(format!(
            "database schema version {current_version} is newer than supported version {LATEST_SCHEMA_VERSION}"
        )));
    }

    let tx = connection.transaction()?;
    if current_version < 1 {
        tx.execute_batch(V1_SCHEMA_SQL)?;
        tx.pragma_update(None, "user_version", 1)?;
    }
    if current_version < 2 {
        migrate_v2(&tx)?;
        tx.pragma_update(None, "user_version", 2)?;
    }
    if current_version < 3 {
        tx.execute_batch(V3_GENERATION_SCHEMA_SQL)?;
        tx.pragma_update(None, "user_version", 3)?;
    }
    if current_version < 4 {
        tx.execute_batch(V4_OAUTH_LEASE_SCHEMA_SQL)?;
        tx.pragma_update(None, "user_version", 4)?;
    }
    if current_version < 5 {
        tx.execute_batch(V5_GENERATION_ORDER_SCHEMA_SQL)?;
        tx.pragma_update(None, "user_version", 5)?;
    }
    tx.commit()
}

fn migrate_v2(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    add_missing_columns(
        tx,
        "messages",
        &[
            ("cleared", "INTEGER NOT NULL DEFAULT 0"),
            ("cleared_summary", "TEXT"),
            ("refetch_args", "TEXT"),
            ("is_compaction_summary", "INTEGER NOT NULL DEFAULT 0"),
            ("prompt_tokens", "INTEGER"),
            ("completion_tokens", "INTEGER"),
            ("total_tokens", "INTEGER"),
            ("reasoning", "TEXT"),
            ("attachments_json", "TEXT"),
            ("generation_status", "TEXT NOT NULL DEFAULT 'none'"),
        ],
    )?;
    add_missing_columns(
        tx,
        "conversations",
        &[
            ("is_pinned", "INTEGER NOT NULL DEFAULT 0"),
            ("updated_at", "INTEGER NOT NULL DEFAULT 0"),
        ],
    )?;
    tx.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_messages_conversation
             ON messages(conversation_id);",
    )
}

fn add_missing_columns(
    tx: &Transaction<'_>,
    table: &str,
    columns: &[(&str, &str)],
) -> rusqlite::Result<()> {
    let existing: HashSet<String> = tx
        .prepare(&format!("PRAGMA table_info({table})"))?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<_>>()?;

    for (name, declaration) in columns {
        if !existing.contains(*name) {
            tx.execute(
                &format!("ALTER TABLE {table} ADD COLUMN {name} {declaration}"),
                [],
            )?;
        }
    }
    Ok(())
}
