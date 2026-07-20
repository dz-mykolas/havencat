//! FRB-exposed conversation persistence API.
//!
//! Holds a process-global `SharedConversationsDb` (opened lazily on first use
//! via `configure_conversations`). All conversation CRUD goes through here.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use once_cell::sync::{Lazy, OnceCell};

use crate::conversations::db::{
    ConversationsDb, GenerationCheckpoint, GenerationClaim, GenerationCommand, GenerationFinish,
    GenerationLifecycleEvent, GenerationRun, GenerationTask, NewGenerationCommand,
    NewGenerationLifecycleEvent, NewGenerationTask, ProviderCall, SharedConversationsDb,
    StoredConversation, ToolExecution,
};
use crate::conversations::error::{ConversationsError, Result};

static DB: OnceCell<ConfiguredDb> = OnceCell::new();
static CONFIGURE_LOCK: Lazy<tokio::sync::Mutex<()>> = Lazy::new(|| tokio::sync::Mutex::new(()));

struct ConfiguredDb {
    db: SharedConversationsDb,
    identity: DbIdentity,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum DbIdentity {
    InMemory,
    File(PathBuf),
}

impl DbIdentity {
    fn label(&self) -> String {
        match self {
            Self::InMemory => "<memory>".to_string(),
            Self::File(path) => path.display().to_string(),
        }
    }
}

/// Initialize the conversations database: open the DB at `db_path`, run
/// migrations. `db_path` of empty string opens an in-memory database.
#[flutter_rust_bridge::frb]
pub async fn configure_conversations(db_path: String) -> Result<()> {
    let identity = if db_path.is_empty() {
        DbIdentity::InMemory
    } else {
        DbIdentity::File(canonical_db_path(&db_path)?)
    };

    let _guard = CONFIGURE_LOCK.lock().await;
    if let Some(configured) = DB.get() {
        return if configured.identity == identity {
            Ok(())
        } else {
            Err(ConversationsError::AlreadyConfigured {
                configured: configured.identity.label(),
                requested: identity.label(),
            })
        };
    }

    let db = match &identity {
        DbIdentity::InMemory => ConversationsDb::open_in_memory().await?,
        DbIdentity::File(path) => ConversationsDb::open(path).await?,
    };
    let requested = identity.label();
    if DB
        .set(ConfiguredDb {
            db: Arc::new(db),
            identity,
        })
        .is_err()
    {
        return Err(ConversationsError::AlreadyConfigured {
            configured: DB
                .get()
                .map(|configured| configured.identity.label())
                .unwrap_or_else(|| "<unknown>".to_string()),
            requested,
        });
    }
    Ok(())
}

/// Load all conversations with their message trees, most recent first.
#[flutter_rust_bridge::frb]
pub async fn load_conversations() -> Result<Vec<StoredConversation>> {
    let db = db()?;
    db.load_all().await
}

/// Atomically upsert a conversation and the supplied messages.
///
/// Existing messages omitted from the snapshot are preserved.
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

/// Atomically persist a conversation snapshot and enqueue generation work.
#[flutter_rust_bridge::frb]
pub async fn upsert_conversation_and_enqueue_generation(
    conv: StoredConversation,
    task: NewGenerationTask,
) -> Result<()> {
    db()?.upsert_conversation_and_enqueue(&conv, &task).await
}

#[flutter_rust_bridge::frb]
pub async fn enqueue_generation_task(task: NewGenerationTask) -> Result<()> {
    db()?.enqueue_generation_task(&task).await
}

#[flutter_rust_bridge::frb]
pub async fn get_generation_task(id: String) -> Result<Option<GenerationTask>> {
    db()?.get_generation_task(&id).await
}

#[flutter_rust_bridge::frb]
pub async fn load_generation_tasks() -> Result<Vec<GenerationTask>> {
    db()?.load_generation_tasks().await
}

#[flutter_rust_bridge::frb]
pub async fn remove_queued_generation_task(id: String) -> Result<bool> {
    db()?.remove_queued_generation_task(&id).await
}

#[flutter_rust_bridge::frb]
pub async fn reorder_queued_generation_tasks(ids: Vec<String>, now_ms: i64) -> Result<()> {
    db()?.reorder_queued_generation_tasks(&ids, now_ms).await
}

#[flutter_rust_bridge::frb]
pub async fn load_generation_runs(task_id: String) -> Result<Vec<GenerationRun>> {
    db()?.load_generation_runs(&task_id).await
}

#[flutter_rust_bridge::frb]
pub async fn claim_generation_task(
    worker_id: String,
    now_ms: i64,
    lease_duration_ms: i64,
) -> Result<Option<GenerationClaim>> {
    db()?
        .claim_generation_task(&worker_id, now_ms, lease_duration_ms)
        .await
}

#[flutter_rust_bridge::frb]
pub async fn checkpoint_generation(checkpoint: GenerationCheckpoint) -> Result<bool> {
    db()?.checkpoint_generation(&checkpoint).await
}

#[flutter_rust_bridge::frb]
pub async fn finish_generation(finish: GenerationFinish) -> Result<bool> {
    db()?.finish_generation(&finish).await
}

#[flutter_rust_bridge::frb]
pub async fn recover_expired_generation_tasks(now_ms: i64) -> Result<Vec<String>> {
    db()?.recover_expired_generation_tasks(now_ms).await
}

#[flutter_rust_bridge::frb]
pub async fn enqueue_generation_command(command: NewGenerationCommand) -> Result<()> {
    db()?.enqueue_generation_command(&command).await
}

#[flutter_rust_bridge::frb]
pub async fn load_pending_generation_commands(task_id: String) -> Result<Vec<GenerationCommand>> {
    db()?.load_pending_generation_commands(&task_id).await
}

#[flutter_rust_bridge::frb]
pub async fn acknowledge_generation_command(
    command_id: String,
    acknowledged_at: i64,
) -> Result<bool> {
    db()?
        .acknowledge_generation_command(&command_id, acknowledged_at)
        .await
}

#[flutter_rust_bridge::frb]
pub async fn upsert_provider_call(call: ProviderCall) -> Result<()> {
    db()?.upsert_provider_call(&call).await
}

#[flutter_rust_bridge::frb]
pub async fn load_provider_calls(run_id: String) -> Result<Vec<ProviderCall>> {
    db()?.load_provider_calls(&run_id).await
}

#[flutter_rust_bridge::frb]
pub async fn upsert_tool_execution(execution: ToolExecution) -> Result<()> {
    db()?.upsert_tool_execution(&execution).await
}

#[flutter_rust_bridge::frb]
pub async fn load_tool_executions(run_id: String) -> Result<Vec<ToolExecution>> {
    db()?.load_tool_executions(&run_id).await
}

#[flutter_rust_bridge::frb]
pub async fn append_generation_lifecycle_event(event: NewGenerationLifecycleEvent) -> Result<i64> {
    db()?.append_generation_lifecycle_event(&event).await
}

#[flutter_rust_bridge::frb]
pub async fn load_generation_lifecycle_events(
    task_id: String,
    after_event_id: Option<i64>,
) -> Result<Vec<GenerationLifecycleEvent>> {
    db()?
        .load_generation_lifecycle_events(&task_id, after_event_id)
        .await
}

#[flutter_rust_bridge::frb]
pub async fn acquire_oauth_refresh_lease(
    account_id: String,
    owner_id: String,
    now_ms: i64,
    lease_duration_ms: i64,
) -> Result<bool> {
    db()?
        .acquire_oauth_refresh_lease(&account_id, &owner_id, now_ms, lease_duration_ms)
        .await
}

#[flutter_rust_bridge::frb]
pub async fn release_oauth_refresh_lease(account_id: String, owner_id: String) -> Result<()> {
    db()?
        .release_oauth_refresh_lease(&account_id, &owner_id)
        .await
}

fn db() -> Result<&'static SharedConversationsDb> {
    DB.get()
        .map(|configured| &configured.db)
        .ok_or(ConversationsError::NotConfigured)
}

fn canonical_db_path(raw_path: &str) -> Result<PathBuf> {
    let path = Path::new(raw_path);
    if !path.is_absolute() {
        return Err(ConversationsError::InvalidPath(
            "database path must be absolute".to_string(),
        ));
    }
    let file_name = path.file_name().ok_or_else(|| {
        ConversationsError::InvalidPath("database path must name a file".to_string())
    })?;

    if path.exists() {
        if !path.is_file() {
            return Err(ConversationsError::InvalidPath(format!(
                "{} is not a file",
                path.display()
            )));
        }
        return std::fs::canonicalize(path)
            .map_err(|error| ConversationsError::InvalidPath(error.to_string()));
    }

    let parent = path.parent().ok_or_else(|| {
        ConversationsError::InvalidPath("database path must have a parent directory".to_string())
    })?;
    let canonical_parent = std::fs::canonicalize(parent).map_err(|error| {
        ConversationsError::InvalidPath(format!(
            "cannot resolve database parent {}: {error}",
            parent.display()
        ))
    })?;
    Ok(canonical_parent.join(file_name))
}

#[cfg(test)]
mod tests {
    use super::canonical_db_path;

    #[test]
    fn database_path_must_be_absolute_and_is_canonicalized() {
        assert!(canonical_db_path("relative/conversations.db").is_err());

        let canonical = canonical_db_path("/tmp/../tmp/havencat-conversations.db").unwrap();
        assert_eq!(canonical, PathBuf::from("/tmp/havencat-conversations.db"));
    }

    use std::path::PathBuf;
}
