use std::path::Path;
use std::sync::Arc;

use tokio_rusqlite::params;
use tokio_rusqlite::rusqlite;
use tokio_rusqlite::Connection;

use super::error::{ConversationsError, Result};

const SCHEMA_SQL: &str = include_str!("schema.sql");

/// A handle to the conversations SQLite database. Cheap to clone.
#[derive(Clone)]
pub struct ConversationsDb {
    conn: Connection,
}

impl ConversationsDb {
    /// Open (or create) the database at `path`, run migrations, set PRAGMAs.
    pub async fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path.as_ref()).await?;
        let db = Self { conn };
        db.configure_pragmas().await?;
        db.migrate().await?;
        Ok(db)
    }

    /// In-memory database, for tests.
    pub async fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().await?;
        let db = Self { conn };
        db.configure_pragmas().await?;
        db.migrate().await?;
        Ok(db)
    }

    pub async fn configure_pragmas(&self) -> Result<()> {
        self.conn
            .call(|c| -> std::result::Result<(), rusqlite::Error> {
                c.pragma_update(None, "journal_mode", "WAL")?;
                c.pragma_update(None, "synchronous", "NORMAL")?;
                c.pragma_update(None, "foreign_keys", "ON")?;
                c.pragma_update(None, "temp_store", "MEMORY")?;
                Ok(())
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))?;
        Ok(())
    }

    pub async fn migrate(&self) -> Result<()> {
        self.conn
            .call(|c| -> std::result::Result<(), rusqlite::Error> {
                c.execute_batch(SCHEMA_SQL)?;
                Ok(())
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))?;
        Ok(())
    }

    /// Load all conversations with their message trees, ordered by
    /// `updated_at` descending (most recent first).
    pub async fn load_all(&self) -> Result<Vec<StoredConversation>> {
        let result = self
            .conn
            .call(|c| -> std::result::Result<Vec<StoredConversation>, rusqlite::Error> {
                let mut conv_stmt = c.prepare(
                    "SELECT id, title, provider_account, created_at, current_leaf_id, updated_at
                     FROM conversations ORDER BY updated_at DESC",
                )?;
                let conv_rows = conv_stmt.query_map([], |row| {
                    Ok(StoredConversation {
                        id: row.get(0)?,
                        title: row.get(1)?,
                        provider_account: row.get(2)?,
                        created_at: row.get(3)?,
                        current_leaf_id: row.get(4)?,
                        updated_at: row.get(5)?,
                        messages: Vec::new(),
                    })
                })?;
                let mut convs: Vec<StoredConversation> =
                    conv_rows.collect::<std::result::Result<_, _>>()?;

                let mut msg_stmt = c.prepare(
                    "SELECT id, conversation_id, role, text, parent_id, children_ids,
                            original_content, has_error, active_child_id, tool_call_id,
                            tool_calls_json, created_at
                     FROM messages",
                )?;
                let msg_rows = msg_stmt.query_map([], |row| {
                    Ok(StoredMessage {
                        id: row.get(0)?,
                        conversation_id: row.get(1)?,
                        role: row.get(2)?,
                        text: row.get(3)?,
                        parent_id: row.get(4)?,
                        children_ids: row.get(5)?,
                        original_content: row.get(6)?,
                        has_error: row.get::<_, i64>(7)? != 0,
                        active_child_id: row.get(8)?,
                        tool_call_id: row.get(9)?,
                        tool_calls_json: row.get(10)?,
                        created_at: row.get(11)?,
                    })
                })?;
                let msgs: Vec<StoredMessage> =
                    msg_rows.collect::<std::result::Result<_, _>>()?;

                for conv in &mut convs {
                    conv.messages = msgs
                        .iter()
                        .filter(|m| m.conversation_id == conv.id)
                        .cloned()
                        .collect();
                }

                Ok(convs)
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))?;

        Ok(result)
    }

    /// Upsert a conversation and all its messages (replaces existing).
    pub async fn upsert_conversation(&self, conv: &StoredConversation) -> Result<()> {
        let conv = conv.clone();
        self.conn
            .call(move |c| -> std::result::Result<(), rusqlite::Error> {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0);

                c.execute(
                    "INSERT OR REPLACE INTO conversations
                     (id, title, provider_account, created_at, current_leaf_id, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        conv.id,
                        conv.title,
                        conv.provider_account,
                        conv.created_at,
                        conv.current_leaf_id,
                        now,
                    ],
                )?;

                c.execute(
                    "DELETE FROM messages WHERE conversation_id = ?1",
                    params![conv.id],
                )?;

                for m in &conv.messages {
                    c.execute(
                        "INSERT INTO messages
                         (id, conversation_id, role, text, parent_id, children_ids,
                          original_content, has_error, active_child_id, tool_call_id,
                          tool_calls_json, created_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                        params![
                            m.id,
                            m.conversation_id,
                            m.role,
                            m.text,
                            m.parent_id,
                            m.children_ids,
                            m.original_content,
                            m.has_error as i64,
                            m.active_child_id,
                            m.tool_call_id,
                            m.tool_calls_json,
                            m.created_at,
                        ],
                    )?;
                }
                Ok(())
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))?;
        Ok(())
    }

    /// Delete a conversation and all its messages (cascade).
    pub async fn delete_conversation(&self, id: &str) -> Result<()> {
        let id = id.to_string();
        self.conn
            .call(move |c| -> std::result::Result<(), rusqlite::Error> {
                c.execute("DELETE FROM conversations WHERE id = ?1", params![id])?;
                Ok(())
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))?;
        Ok(())
    }
}

/// Shared DB handle wrapped in `Arc` for global access from FRB-exposed fns.
pub type SharedConversationsDb = Arc<ConversationsDb>;

#[derive(Clone, Debug)]
pub struct StoredConversation {
    pub id: String,
    pub title: String,
    pub provider_account: Option<String>,
    pub created_at: String,
    pub current_leaf_id: Option<String>,
    pub updated_at: i64,
    pub messages: Vec<StoredMessage>,
}

#[derive(Clone, Debug)]
pub struct StoredMessage {
    pub id: String,
    pub conversation_id: String,
    pub role: String,
    pub text: String,
    pub parent_id: Option<String>,
    pub children_ids: String,
    pub original_content: Option<String>,
    pub has_error: bool,
    pub active_child_id: Option<String>,
    pub tool_call_id: Option<String>,
    pub tool_calls_json: Option<String>,
    pub created_at: String,
}
