-- HavenChat conversations schema.
-- Conversations and their full message trees (with branching support).

CREATE TABLE IF NOT EXISTS conversations (
    id                TEXT PRIMARY KEY,
    title             TEXT NOT NULL DEFAULT 'New chat',
    provider_account  TEXT,
    created_at        TEXT NOT NULL,
    current_leaf_id   TEXT,
    updated_at        INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS messages (
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
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation
    ON messages(conversation_id);
