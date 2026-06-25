//! FRB-exposed conversation persistence API.
//!
//! Holds a process-global `SharedConversationsDb` (opened lazily on first use
//! via `configure_conversations`). All conversation CRUD goes through here.

use std::sync::Arc;

use once_cell::sync::OnceCell;

use crate::conversations::db::{ConversationsDb, SharedConversationsDb, StoredConversation};
use crate::conversations::error::{Result, ConversationsError};

static DB: OnceCell<SharedConversationsDb> = OnceCell::new();

/// Initialize the conversations database: open the DB at `db_path`, run
/// migrations. `db_path` of empty string opens an in-memory database.
#[flutter_rust_bridge::frb]
pub async fn configure_conversations(db_path: String) -> Result<()> {
    let db = if db_path.is_empty() {
        ConversationsDb::open_in_memory().await?
    } else {
        ConversationsDb::open(&db_path).await?
    };
    let _ = DB.set(Arc::new(db));
    Ok(())
}

/// Load all conversations with their message trees, most recent first.
#[flutter_rust_bridge::frb]
pub async fn load_conversations() -> Result<Vec<StoredConversation>> {
    let db = db()?;
    db.load_all().await
}

/// Upsert (insert or replace) a conversation and all its messages.
#[flutter_rust_bridge::frb]
pub async fn upsert_conversation(conv: StoredConversation) -> Result<()> {
    let db = db()?;
    db.upsert_conversation(&conv).await
}

/// Delete a conversation and all its messages.
#[flutter_rust_bridge::frb]
pub async fn delete_conversation(id: String) -> Result<()> {
    let db = db()?;
    db.delete_conversation(&id).await
}

fn db() -> Result<&'static SharedConversationsDb> {
    DB.get().ok_or(ConversationsError::NotConfigured)
}
