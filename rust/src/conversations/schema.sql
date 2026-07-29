-- HavenChat conversations schema.
-- Conversations and their full message trees (with branching support).

CREATE TABLE conversations (
    id                TEXT PRIMARY KEY,
    title             TEXT NOT NULL DEFAULT 'New chat',
    provider_account  TEXT,
    created_at        TEXT NOT NULL,
    current_leaf_id   TEXT,
    is_pinned         INTEGER NOT NULL DEFAULT 0,
    updated_at        INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE messages (
    id                  TEXT PRIMARY KEY,
    conversation_id      TEXT NOT NULL,
    role                TEXT NOT NULL,
    text                TEXT NOT NULL DEFAULT '',
    parent_id           TEXT,
    children_ids        TEXT NOT NULL DEFAULT '[]',
    original_content    TEXT,
    has_error           INTEGER NOT NULL DEFAULT 0,
    active_child_id     TEXT,
    tool_call_id        TEXT,
    tool_calls_json    TEXT,
    created_at          TEXT NOT NULL,
    cleared             INTEGER NOT NULL DEFAULT 0,
    cleared_summary     TEXT,
    refetch_args        TEXT,
    is_compaction_summary INTEGER NOT NULL DEFAULT 0,
    prompt_tokens       INTEGER,
    completion_tokens   INTEGER,
    total_tokens        INTEGER,
    reasoning           TEXT,
    attachments_json    TEXT,
    generation_status   TEXT NOT NULL DEFAULT 'none',
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);

CREATE INDEX idx_messages_conversation
    ON messages(conversation_id);

CREATE TABLE generation_tasks (
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

CREATE INDEX idx_generation_tasks_claim
    ON generation_tasks(status, priority ASC, created_at, lease_expires_at);
CREATE INDEX idx_generation_tasks_conversation
    ON generation_tasks(conversation_id, created_at);

CREATE TABLE generation_runs (
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

CREATE INDEX idx_generation_runs_task
    ON generation_runs(task_id, attempt DESC);

CREATE TABLE provider_calls (
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

CREATE INDEX idx_provider_calls_run
    ON provider_calls(run_id, created_at);

CREATE TABLE generation_commands (
    id                TEXT PRIMARY KEY,
    task_id           TEXT NOT NULL,
    kind              TEXT NOT NULL,
    payload_json      TEXT,
    status            TEXT NOT NULL DEFAULT 'pending',
    created_at        INTEGER NOT NULL,
    acknowledged_at   INTEGER,
    FOREIGN KEY (task_id) REFERENCES generation_tasks(id) ON DELETE CASCADE
);

CREATE INDEX idx_generation_commands_pending
    ON generation_commands(task_id, status, created_at);

CREATE TABLE tool_executions (
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

CREATE INDEX idx_tool_executions_run
    ON tool_executions(run_id, created_at);

CREATE TABLE generation_lifecycle_events (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id           TEXT NOT NULL,
    run_id            TEXT,
    event_type        TEXT NOT NULL,
    payload_json      TEXT,
    created_at        INTEGER NOT NULL,
    FOREIGN KEY (task_id) REFERENCES generation_tasks(id) ON DELETE CASCADE,
    FOREIGN KEY (run_id) REFERENCES generation_runs(id) ON DELETE SET NULL
);

CREATE INDEX idx_generation_events_task
    ON generation_lifecycle_events(task_id, id);

CREATE TABLE oauth_refresh_leases (
    account_id        TEXT PRIMARY KEY,
    owner_id          TEXT NOT NULL,
    lease_expires_at  INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL
);
