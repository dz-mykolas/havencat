use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use tokio_rusqlite::params;
use tokio_rusqlite::rusqlite::{self, OptionalExtension, Transaction, TransactionBehavior};
use tokio_rusqlite::Connection;

use super::error::{ConversationsError, Result};
use super::migrations;

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
                c.busy_timeout(Duration::from_secs(5))?;
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
            .call(|c| -> std::result::Result<(), rusqlite::Error> { migrations::migrate(c) })
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
                    "SELECT id, title, provider_account, created_at, current_leaf_id, is_pinned, updated_at
                     FROM conversations ORDER BY is_pinned DESC, updated_at DESC",
                )?;
                let conv_rows = conv_stmt.query_map([], |row| {
                    Ok(StoredConversation {
                        id: row.get(0)?,
                        title: row.get(1)?,
                        provider_account: row.get(2)?,
                        created_at: row.get(3)?,
                        current_leaf_id: row.get(4)?,
                        is_pinned: row.get::<_, i64>(5)? != 0,
                        updated_at: row.get(6)?,
                        messages: Vec::new(),
                    })
                })?;
                let mut convs: Vec<StoredConversation> =
                    conv_rows.collect::<std::result::Result<_, _>>()?;

                let mut msg_stmt = c.prepare(
                    "SELECT id, conversation_id, role, text, parent_id, children_ids,
                            original_content, has_error, active_child_id, tool_call_id,
                            tool_calls_json, created_at, cleared, cleared_summary,
                            refetch_args, is_compaction_summary,
                            prompt_tokens, completion_tokens, total_tokens, reasoning,
                            attachments_json, generation_status
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
                        cleared: row.get::<_, i64>(12)? != 0,
                        cleared_summary: row.get(13)?,
                        refetch_args: row.get(14)?,
                        is_compaction_summary: row.get::<_, i64>(15)? != 0,
                        prompt_tokens: row.get(16)?,
                        completion_tokens: row.get(17)?,
                        total_tokens: row.get(18)?,
                        reasoning: row.get(19)?,
                        attachments_json: row.get(20)?,
                        generation_status: row.get(21)?,
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

    /// Atomically upsert a conversation and the supplied messages.
    ///
    /// Messages omitted by the caller are preserved. Explicit deletion goes
    /// through `delete_conversation`, avoiding data loss from partial snapshots.
    pub async fn upsert_conversation(&self, conv: &StoredConversation) -> Result<()> {
        validate_conversation(conv)?;
        let conv = conv.clone();
        self.conn
            .call(move |c| -> std::result::Result<(), rusqlite::Error> {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0);
                let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
                upsert_conversation_tx(&tx, &conv, now)?;
                tx.commit()
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))?;
        Ok(())
    }

    /// Atomically persist a conversation snapshot and enqueue generation work.
    pub async fn upsert_conversation_and_enqueue(
        &self,
        conv: &StoredConversation,
        task: &NewGenerationTask,
    ) -> Result<()> {
        validate_conversation(conv)?;
        validate_new_task(task)?;
        if task.conversation_id != conv.id {
            return Err(ConversationsError::InvalidArgument(
                "generation task conversation_id does not match the conversation".to_string(),
            ));
        }

        let conv = conv.clone();
        let task = task.clone();
        self.conn
            .call(move |c| -> std::result::Result<(), rusqlite::Error> {
                let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
                upsert_conversation_tx(&tx, &conv, task.created_at)?;
                enqueue_generation_task_tx(&tx, &task)?;
                tx.commit()
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn enqueue_generation_task(&self, task: &NewGenerationTask) -> Result<()> {
        validate_new_task(task)?;
        let task = task.clone();
        self.conn
            .call(move |c| -> std::result::Result<(), rusqlite::Error> {
                let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
                enqueue_generation_task_tx(&tx, &task)?;
                tx.commit()
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn get_generation_task(&self, id: &str) -> Result<Option<GenerationTask>> {
        let id = id.to_string();
        self.conn
            .call(
                move |c| -> std::result::Result<Option<GenerationTask>, rusqlite::Error> {
                    c.query_row(
                        GENERATION_TASK_SELECT_BY_ID,
                        params![id],
                        generation_task_from_row,
                    )
                    .optional()
                },
            )
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn load_generation_tasks(&self) -> Result<Vec<GenerationTask>> {
        self.conn
            .call(
                move |c| -> std::result::Result<Vec<GenerationTask>, rusqlite::Error> {
                    let mut statement = c.prepare(
                        "SELECT id, conversation_id, assistant_message_id, status, request_json,
                                priority, attempt_count, max_attempts, lease_owner,
                                lease_expires_at, checkpoint_json, last_error, created_at,
                                updated_at, started_at, finished_at
                         FROM generation_tasks
                         ORDER BY created_at, id",
                    )?;
                    let tasks = statement
                        .query_map([], generation_task_from_row)?
                        .collect::<rusqlite::Result<Vec<_>>>()?;
                    Ok(tasks)
                },
            )
            .await
            .map_err(|error| ConversationsError::Database(error.to_string()))
    }

    pub async fn remove_queued_generation_task(&self, id: &str) -> Result<bool> {
        let id = id.to_string();
        self.conn
            .call(move |connection| {
                connection
                    .execute(
                        "DELETE FROM generation_tasks WHERE id = ?1 AND status = 'queued'",
                        params![id],
                    )
                    .map(|changed| changed != 0)
            })
            .await
            .map_err(|error| ConversationsError::Database(error.to_string()))
    }

    pub async fn reorder_queued_generation_tasks(&self, ids: &[String], now_ms: i64) -> Result<()> {
        let ids = ids.to_vec();
        self.conn
            .call(
                move |connection| -> std::result::Result<(), rusqlite::Error> {
                    let tx =
                        connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
                    let base_priority = now_ms.saturating_mul(100_000);
                    for (index, id) in ids.iter().enumerate() {
                        let priority = base_priority.saturating_add(index as i64);
                        tx.execute(
                            "UPDATE generation_tasks
                         SET priority = ?2, updated_at = ?3
                         WHERE id = ?1 AND status = 'queued'",
                            params![id, priority, now_ms],
                        )?;
                    }
                    tx.commit()
                },
            )
            .await
            .map_err(|error| ConversationsError::Database(error.to_string()))
    }

    pub async fn load_generation_runs(&self, task_id: &str) -> Result<Vec<GenerationRun>> {
        let task_id = task_id.to_string();
        self.conn
            .call(
                move |c| -> std::result::Result<Vec<GenerationRun>, rusqlite::Error> {
                    let mut stmt = c.prepare(
                        "SELECT id, task_id, attempt, status, worker_id, checkpoint_json,
                                error, started_at, updated_at, finished_at
                         FROM generation_runs
                         WHERE task_id = ?1
                         ORDER BY attempt",
                    )?;
                    let runs = stmt
                        .query_map(params![task_id], generation_run_from_row)?
                        .collect();
                    runs
                },
            )
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    /// Claim the earliest queued task and create its durable run.
    ///
    /// Expired leases are recovered in the same immediate transaction before
    /// selecting work, so two workers cannot claim the same task.
    pub async fn claim_generation_task(
        &self,
        worker_id: &str,
        now_ms: i64,
        lease_duration_ms: i64,
    ) -> Result<Option<GenerationClaim>> {
        if worker_id.is_empty() {
            return Err(ConversationsError::InvalidArgument(
                "worker_id must not be empty".to_string(),
            ));
        }
        if lease_duration_ms <= 0 {
            return Err(ConversationsError::InvalidArgument(
                "lease_duration_ms must be positive".to_string(),
            ));
        }

        let worker_id = worker_id.to_string();
        self.conn
            .call(
                move |c| -> std::result::Result<Option<GenerationClaim>, rusqlite::Error> {
                    let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
                    recover_expired_tx(&tx, now_ms)?;
                    let candidate: Option<(String, i64)> = tx
                        .query_row(
                            "SELECT id, attempt_count
                             FROM generation_tasks
                             WHERE status = 'queued' AND attempt_count < max_attempts
                             ORDER BY priority ASC, created_at, id
                             LIMIT 1",
                            [],
                            |row| Ok((row.get(0)?, row.get(1)?)),
                        )
                        .optional()?;

                    let Some((task_id, prior_attempts)) = candidate else {
                        tx.commit()?;
                        return Ok(None);
                    };

                    let attempt = prior_attempts + 1;
                    let run_id = format!("{task_id}:run:{attempt}");
                    let lease_expires_at = now_ms.saturating_add(lease_duration_ms);
                    let changed = tx.execute(
                        "UPDATE generation_tasks
                         SET status = 'leased', attempt_count = ?2, lease_owner = ?3,
                             lease_expires_at = ?4, updated_at = ?5,
                             started_at = COALESCE(started_at, ?5), finished_at = NULL
                         WHERE id = ?1 AND status = 'queued' AND attempt_count = ?6",
                        params![
                            task_id,
                            attempt,
                            worker_id,
                            lease_expires_at,
                            now_ms,
                            prior_attempts
                        ],
                    )?;
                    if changed == 0 {
                        tx.commit()?;
                        return Ok(None);
                    }

                    tx.execute(
                        "INSERT INTO generation_runs
                         (id, task_id, attempt, status, worker_id, started_at, updated_at)
                         VALUES (?1, ?2, ?3, 'leased', ?4, ?5, ?5)",
                        params![run_id, task_id, attempt, worker_id, now_ms],
                    )?;
                    append_event_tx(&tx, &task_id, Some(&run_id), "leased", None, now_ms)?;

                    let task = tx.query_row(
                        GENERATION_TASK_SELECT_BY_ID,
                        params![task_id],
                        generation_task_from_row,
                    )?;
                    let run = tx.query_row(
                        GENERATION_RUN_SELECT_BY_ID,
                        params![run_id],
                        generation_run_from_row,
                    )?;
                    tx.commit()?;
                    Ok(Some(GenerationClaim { task, run }))
                },
            )
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    /// Save a checkpoint and extend the lease if the caller still owns it.
    pub async fn checkpoint_generation(&self, checkpoint: &GenerationCheckpoint) -> Result<bool> {
        if checkpoint.lease_duration_ms <= 0 {
            return Err(ConversationsError::InvalidArgument(
                "lease_duration_ms must be positive".to_string(),
            ));
        }
        let checkpoint = checkpoint.clone();
        self.conn
            .call(move |c| -> std::result::Result<bool, rusqlite::Error> {
                let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
                let lease_expires_at = checkpoint
                    .now_ms
                    .saturating_add(checkpoint.lease_duration_ms);
                let changed = tx.execute(
                    "UPDATE generation_tasks
                     SET status = 'running', checkpoint_json = ?4, lease_expires_at = ?5,
                         updated_at = ?6
                     WHERE id = ?1 AND lease_owner = ?2
                       AND status IN ('leased', 'running')
                       AND lease_expires_at > ?6
                       AND EXISTS (
                           SELECT 1 FROM generation_runs
                           WHERE id = ?3 AND task_id = ?1 AND worker_id = ?2
                             AND status IN ('leased', 'running')
                       )",
                    params![
                        checkpoint.task_id,
                        checkpoint.worker_id,
                        checkpoint.run_id,
                        checkpoint.checkpoint_json,
                        lease_expires_at,
                        checkpoint.now_ms
                    ],
                )?;
                if changed == 0 {
                    tx.commit()?;
                    return Ok(false);
                }
                tx.execute(
                    "UPDATE generation_runs
                     SET status = 'running', checkpoint_json = ?2, updated_at = ?3
                     WHERE id = ?1",
                    params![
                        checkpoint.run_id,
                        checkpoint.checkpoint_json,
                        checkpoint.now_ms
                    ],
                )?;
                append_event_tx(
                    &tx,
                    &checkpoint.task_id,
                    Some(&checkpoint.run_id),
                    "checkpoint",
                    None,
                    checkpoint.now_ms,
                )?;
                tx.commit()?;
                Ok(true)
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    /// Finish an owned run and its task in one transaction.
    pub async fn finish_generation(&self, finish: &GenerationFinish) -> Result<bool> {
        if !matches!(
            finish.status.as_str(),
            "succeeded" | "failed" | "cancelled" | "interrupted" | "outcome_unknown"
        ) {
            return Err(ConversationsError::InvalidArgument(
                "invalid terminal generation status".to_string(),
            ));
        }
        let finish = finish.clone();
        self.conn
            .call(move |c| -> std::result::Result<bool, rusqlite::Error> {
                let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
                let changed = tx.execute(
                    "UPDATE generation_tasks
                     SET status = ?4, checkpoint_json = COALESCE(?5, checkpoint_json),
                         last_error = ?6, updated_at = ?7, finished_at = ?7,
                         lease_owner = NULL, lease_expires_at = NULL
                     WHERE id = ?1 AND lease_owner = ?2
                       AND status IN ('leased', 'running')
                       AND lease_expires_at > ?7
                       AND EXISTS (
                           SELECT 1 FROM generation_runs
                           WHERE id = ?3 AND task_id = ?1 AND worker_id = ?2
                             AND status IN ('leased', 'running')
                       )",
                    params![
                        finish.task_id,
                        finish.worker_id,
                        finish.run_id,
                        finish.status,
                        finish.checkpoint_json,
                        finish.error,
                        finish.finished_at
                    ],
                )?;
                if changed == 0 {
                    tx.commit()?;
                    return Ok(false);
                }
                tx.execute(
                    "UPDATE generation_runs
                     SET status = ?2, checkpoint_json = COALESCE(?3, checkpoint_json),
                         error = ?4, updated_at = ?5, finished_at = ?5
                     WHERE id = ?1",
                    params![
                        finish.run_id,
                        finish.status,
                        finish.checkpoint_json,
                        finish.error,
                        finish.finished_at
                    ],
                )?;
                append_event_tx(
                    &tx,
                    &finish.task_id,
                    Some(&finish.run_id),
                    &finish.status,
                    finish.error.as_deref(),
                    finish.finished_at,
                )?;
                tx.commit()?;
                Ok(true)
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    /// Recover expired leases. Retryable tasks return to `queued`; exhausted
    /// tasks become `failed`. Returns the affected task IDs.
    pub async fn recover_expired_generation_tasks(&self, now_ms: i64) -> Result<Vec<String>> {
        self.conn
            .call(
                move |c| -> std::result::Result<Vec<String>, rusqlite::Error> {
                    let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
                    let recovered = recover_expired_tx(&tx, now_ms)?;
                    tx.commit()?;
                    Ok(recovered)
                },
            )
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn enqueue_generation_command(&self, command: &NewGenerationCommand) -> Result<()> {
        if command.id.is_empty() || command.task_id.is_empty() {
            return Err(ConversationsError::InvalidArgument(
                "command id, task_id, and kind must not be empty".to_string(),
            ));
        }
        if !matches!(command.kind.as_str(), "cancel" | "steer") {
            return Err(ConversationsError::InvalidArgument(
                "command kind must be cancel or steer".to_string(),
            ));
        }
        let command = command.clone();
        self.conn
            .call(move |c| -> std::result::Result<(), rusqlite::Error> {
                let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
                let inserted = tx.execute(
                    "INSERT INTO generation_commands
                     (id, task_id, kind, payload_json, status, created_at)
                     VALUES (?1, ?2, ?3, ?4, 'pending', ?5)
                     ON CONFLICT(id) DO NOTHING",
                    params![
                        command.id,
                        command.task_id,
                        command.kind,
                        command.payload_json,
                        command.created_at
                    ],
                )?;
                if inserted != 0 {
                    append_event_tx(
                        &tx,
                        &command.task_id,
                        None,
                        "command_enqueued",
                        command.payload_json.as_deref(),
                        command.created_at,
                    )?;
                }
                tx.commit()
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn load_pending_generation_commands(
        &self,
        task_id: &str,
    ) -> Result<Vec<GenerationCommand>> {
        let task_id = task_id.to_string();
        self.conn
            .call(
                move |c| -> std::result::Result<Vec<GenerationCommand>, rusqlite::Error> {
                    let mut stmt = c.prepare(
                        "SELECT id, task_id, kind, payload_json, status, created_at,
                                acknowledged_at
                         FROM generation_commands
                         WHERE task_id = ?1 AND status = 'pending'
                         ORDER BY created_at, id",
                    )?;
                    let commands = stmt
                        .query_map(params![task_id], generation_command_from_row)?
                        .collect();
                    commands
                },
            )
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn acknowledge_generation_command(
        &self,
        command_id: &str,
        acknowledged_at: i64,
    ) -> Result<bool> {
        let command_id = command_id.to_string();
        self.conn
            .call(move |c| -> std::result::Result<bool, rusqlite::Error> {
                let changed = c.execute(
                    "UPDATE generation_commands
                     SET status = 'acknowledged', acknowledged_at = ?2
                     WHERE id = ?1 AND status = 'pending'",
                    params![command_id, acknowledged_at],
                )?;
                Ok(changed != 0)
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn upsert_provider_call(&self, call: &ProviderCall) -> Result<()> {
        let call = call.clone();
        self.conn
            .call(move |c| -> std::result::Result<(), rusqlite::Error> {
                c.execute(
                    "INSERT INTO provider_calls
                     (id, run_id, provider, model, status, request_json, response_json,
                      error, created_at, updated_at, finished_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                     ON CONFLICT(id) DO UPDATE SET
                       status = excluded.status,
                       response_json = excluded.response_json,
                       error = excluded.error,
                       updated_at = excluded.updated_at,
                       finished_at = excluded.finished_at",
                    params![
                        call.id,
                        call.run_id,
                        call.provider,
                        call.model,
                        call.status,
                        call.request_json,
                        call.response_json,
                        call.error,
                        call.created_at,
                        call.updated_at,
                        call.finished_at
                    ],
                )?;
                Ok(())
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn load_provider_calls(&self, run_id: &str) -> Result<Vec<ProviderCall>> {
        let run_id = run_id.to_string();
        self.conn
            .call(
                move |c| -> std::result::Result<Vec<ProviderCall>, rusqlite::Error> {
                    let mut stmt = c.prepare(
                        "SELECT id, run_id, provider, model, status, request_json,
                                response_json, error, created_at, updated_at, finished_at
                         FROM provider_calls
                         WHERE run_id = ?1
                         ORDER BY created_at, id",
                    )?;
                    let calls = stmt
                        .query_map(params![run_id], provider_call_from_row)?
                        .collect();
                    calls
                },
            )
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn upsert_tool_execution(&self, execution: &ToolExecution) -> Result<()> {
        let execution = execution.clone();
        self.conn
            .call(move |c| -> std::result::Result<(), rusqlite::Error> {
                c.execute(
                    "INSERT INTO tool_executions
                     (id, run_id, tool_call_id, tool_name, status, input_json, output_json,
                      error, created_at, updated_at, finished_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                     ON CONFLICT(id) DO UPDATE SET
                       status = excluded.status,
                       output_json = excluded.output_json,
                       error = excluded.error,
                       updated_at = excluded.updated_at,
                       finished_at = excluded.finished_at",
                    params![
                        execution.id,
                        execution.run_id,
                        execution.tool_call_id,
                        execution.tool_name,
                        execution.status,
                        execution.input_json,
                        execution.output_json,
                        execution.error,
                        execution.created_at,
                        execution.updated_at,
                        execution.finished_at
                    ],
                )?;
                Ok(())
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn load_tool_executions(&self, run_id: &str) -> Result<Vec<ToolExecution>> {
        let run_id = run_id.to_string();
        self.conn
            .call(
                move |c| -> std::result::Result<Vec<ToolExecution>, rusqlite::Error> {
                    let mut stmt = c.prepare(
                        "SELECT id, run_id, tool_call_id, tool_name, status, input_json,
                                output_json, error, created_at, updated_at, finished_at
                         FROM tool_executions
                         WHERE run_id = ?1
                         ORDER BY created_at, id",
                    )?;
                    let executions = stmt
                        .query_map(params![run_id], tool_execution_from_row)?
                        .collect();
                    executions
                },
            )
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn append_generation_lifecycle_event(
        &self,
        event: &NewGenerationLifecycleEvent,
    ) -> Result<i64> {
        let event = event.clone();
        self.conn
            .call(move |c| -> std::result::Result<i64, rusqlite::Error> {
                append_event_tx(
                    c,
                    &event.task_id,
                    event.run_id.as_deref(),
                    &event.event_type,
                    event.payload_json.as_deref(),
                    event.created_at,
                )
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn load_generation_lifecycle_events(
        &self,
        task_id: &str,
        after_event_id: Option<i64>,
    ) -> Result<Vec<GenerationLifecycleEvent>> {
        let task_id = task_id.to_string();
        let after_event_id = after_event_id.unwrap_or(0);
        self.conn
            .call(
                move |c| -> std::result::Result<Vec<GenerationLifecycleEvent>, rusqlite::Error> {
                    let mut stmt = c.prepare(
                        "SELECT id, task_id, run_id, event_type, payload_json, created_at
                         FROM generation_lifecycle_events
                         WHERE task_id = ?1 AND id > ?2
                         ORDER BY id",
                    )?;
                    let events = stmt
                        .query_map(
                            params![task_id, after_event_id],
                            generation_lifecycle_event_from_row,
                        )?
                        .collect();
                    events
                },
            )
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    /// Acquire a short-lived OAuth refresh lease for [account_id].
    ///
    /// Returns true when [owner_id] owns the lease and may refresh. Expired
    /// leases are stolen; live leases owned by another worker are rejected.
    pub async fn acquire_oauth_refresh_lease(
        &self,
        account_id: &str,
        owner_id: &str,
        now_ms: i64,
        lease_duration_ms: i64,
    ) -> Result<bool> {
        if account_id.is_empty() || owner_id.is_empty() || lease_duration_ms <= 0 {
            return Err(ConversationsError::InvalidArgument(
                "account_id, owner_id, and lease_duration_ms are required".to_string(),
            ));
        }
        let account_id = account_id.to_string();
        let owner_id = owner_id.to_string();
        self.conn
            .call(move |c| -> std::result::Result<bool, rusqlite::Error> {
                let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
                let existing: Option<(String, i64)> = tx
                    .query_row(
                        "SELECT owner_id, lease_expires_at
                         FROM oauth_refresh_leases
                         WHERE account_id = ?1",
                        params![account_id],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .optional()?;
                if let Some((current_owner, expires_at)) = existing {
                    if current_owner != owner_id && expires_at > now_ms {
                        tx.commit()?;
                        return Ok(false);
                    }
                }
                let expires_at = now_ms.saturating_add(lease_duration_ms);
                tx.execute(
                    "INSERT INTO oauth_refresh_leases
                     (account_id, owner_id, lease_expires_at, updated_at)
                     VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT(account_id) DO UPDATE SET
                       owner_id = excluded.owner_id,
                       lease_expires_at = excluded.lease_expires_at,
                       updated_at = excluded.updated_at",
                    params![account_id, owner_id, expires_at, now_ms],
                )?;
                tx.commit()?;
                Ok(true)
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
    }

    pub async fn release_oauth_refresh_lease(
        &self,
        account_id: &str,
        owner_id: &str,
    ) -> Result<()> {
        let account_id = account_id.to_string();
        let owner_id = owner_id.to_string();
        self.conn
            .call(move |c| -> std::result::Result<(), rusqlite::Error> {
                c.execute(
                    "DELETE FROM oauth_refresh_leases
                     WHERE account_id = ?1 AND owner_id = ?2",
                    params![account_id, owner_id],
                )?;
                Ok(())
            })
            .await
            .map_err(|e| ConversationsError::Database(e.to_string()))
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
    pub is_pinned: bool,
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
    pub cleared: bool,
    pub cleared_summary: Option<String>,
    pub refetch_args: Option<String>,
    pub is_compaction_summary: bool,
    pub prompt_tokens: Option<i64>,
    pub completion_tokens: Option<i64>,
    pub total_tokens: Option<i64>,
    pub reasoning: Option<String>,
    pub attachments_json: Option<String>,
    pub generation_status: String,
}

#[derive(Clone, Debug)]
pub struct NewGenerationTask {
    pub id: String,
    pub conversation_id: String,
    pub assistant_message_id: Option<String>,
    pub request_json: String,
    pub priority: i64,
    pub max_attempts: i64,
    pub created_at: i64,
}

#[derive(Clone, Debug)]
pub struct GenerationTask {
    pub id: String,
    pub conversation_id: String,
    pub assistant_message_id: Option<String>,
    pub status: String,
    pub request_json: String,
    pub priority: i64,
    pub attempt_count: i64,
    pub max_attempts: i64,
    pub lease_owner: Option<String>,
    pub lease_expires_at: Option<i64>,
    pub checkpoint_json: Option<String>,
    pub last_error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub started_at: Option<i64>,
    pub finished_at: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct GenerationRun {
    pub id: String,
    pub task_id: String,
    pub attempt: i64,
    pub status: String,
    pub worker_id: String,
    pub checkpoint_json: Option<String>,
    pub error: Option<String>,
    pub started_at: i64,
    pub updated_at: i64,
    pub finished_at: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct GenerationClaim {
    pub task: GenerationTask,
    pub run: GenerationRun,
}

#[derive(Clone, Debug)]
pub struct GenerationCheckpoint {
    pub task_id: String,
    pub run_id: String,
    pub worker_id: String,
    pub checkpoint_json: String,
    pub now_ms: i64,
    pub lease_duration_ms: i64,
}

#[derive(Clone, Debug)]
pub struct GenerationFinish {
    pub task_id: String,
    pub run_id: String,
    pub worker_id: String,
    pub status: String,
    pub checkpoint_json: Option<String>,
    pub error: Option<String>,
    pub finished_at: i64,
}

#[derive(Clone, Debug)]
pub struct ProviderCall {
    pub id: String,
    pub run_id: String,
    pub provider: String,
    pub model: Option<String>,
    pub status: String,
    pub request_json: String,
    pub response_json: Option<String>,
    pub error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub finished_at: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct NewGenerationCommand {
    pub id: String,
    pub task_id: String,
    pub kind: String,
    pub payload_json: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug)]
pub struct GenerationCommand {
    pub id: String,
    pub task_id: String,
    pub kind: String,
    pub payload_json: Option<String>,
    pub status: String,
    pub created_at: i64,
    pub acknowledged_at: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct ToolExecution {
    pub id: String,
    pub run_id: String,
    pub tool_call_id: Option<String>,
    pub tool_name: String,
    pub status: String,
    pub input_json: String,
    pub output_json: Option<String>,
    pub error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub finished_at: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct NewGenerationLifecycleEvent {
    pub task_id: String,
    pub run_id: Option<String>,
    pub event_type: String,
    pub payload_json: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug)]
pub struct GenerationLifecycleEvent {
    pub id: i64,
    pub task_id: String,
    pub run_id: Option<String>,
    pub event_type: String,
    pub payload_json: Option<String>,
    pub created_at: i64,
}

const GENERATION_TASK_SELECT_BY_ID: &str = "
    SELECT id, conversation_id, assistant_message_id, status, request_json,
           priority, attempt_count, max_attempts, lease_owner, lease_expires_at,
           checkpoint_json, last_error, created_at, updated_at, started_at, finished_at
    FROM generation_tasks
    WHERE id = ?1";

const GENERATION_RUN_SELECT_BY_ID: &str = "
    SELECT id, task_id, attempt, status, worker_id, checkpoint_json, error,
           started_at, updated_at, finished_at
    FROM generation_runs
    WHERE id = ?1";

fn validate_conversation(conv: &StoredConversation) -> Result<()> {
    if conv.id.is_empty() {
        return Err(ConversationsError::InvalidArgument(
            "conversation id must not be empty".to_string(),
        ));
    }
    if let Some(message) = conv
        .messages
        .iter()
        .find(|message| message.conversation_id != conv.id)
    {
        return Err(ConversationsError::InvalidArgument(format!(
            "message {} belongs to conversation {}, not {}",
            message.id, message.conversation_id, conv.id
        )));
    }
    Ok(())
}

fn validate_new_task(task: &NewGenerationTask) -> Result<()> {
    if task.id.is_empty() || task.conversation_id.is_empty() {
        return Err(ConversationsError::InvalidArgument(
            "task id and conversation_id must not be empty".to_string(),
        ));
    }
    if task.max_attempts <= 0 {
        return Err(ConversationsError::InvalidArgument(
            "max_attempts must be positive".to_string(),
        ));
    }
    Ok(())
}

fn upsert_conversation_tx(
    tx: &Transaction<'_>,
    conv: &StoredConversation,
    updated_at: i64,
) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT INTO conversations
         (id, title, provider_account, created_at, current_leaf_id, is_pinned, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(id) DO UPDATE SET
           title = excluded.title,
           provider_account = excluded.provider_account,
           current_leaf_id = excluded.current_leaf_id,
           is_pinned = excluded.is_pinned,
           updated_at = excluded.updated_at",
        params![
            conv.id,
            conv.title,
            conv.provider_account,
            conv.created_at,
            conv.current_leaf_id,
            conv.is_pinned as i64,
            updated_at,
        ],
    )?;

    for message in &conv.messages {
        tx.execute(
            "INSERT INTO messages
             (id, conversation_id, role, text, parent_id, children_ids,
              original_content, has_error, active_child_id, tool_call_id,
              tool_calls_json, created_at, cleared, cleared_summary,
              refetch_args, is_compaction_summary, prompt_tokens, completion_tokens,
              total_tokens, reasoning, attachments_json, generation_status)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                     ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
             ON CONFLICT(id) DO UPDATE SET
               conversation_id = excluded.conversation_id,
               role = excluded.role,
               text = excluded.text,
               parent_id = excluded.parent_id,
               children_ids = excluded.children_ids,
               original_content = excluded.original_content,
               has_error = excluded.has_error,
               active_child_id = excluded.active_child_id,
               tool_call_id = excluded.tool_call_id,
               tool_calls_json = excluded.tool_calls_json,
               cleared = excluded.cleared,
               cleared_summary = excluded.cleared_summary,
               refetch_args = excluded.refetch_args,
               is_compaction_summary = excluded.is_compaction_summary,
               prompt_tokens = excluded.prompt_tokens,
               completion_tokens = excluded.completion_tokens,
               total_tokens = excluded.total_tokens,
               reasoning = excluded.reasoning,
               attachments_json = excluded.attachments_json,
               generation_status = excluded.generation_status",
            params![
                message.id,
                message.conversation_id,
                message.role,
                message.text,
                message.parent_id,
                message.children_ids,
                message.original_content,
                message.has_error as i64,
                message.active_child_id,
                message.tool_call_id,
                message.tool_calls_json,
                message.created_at,
                message.cleared as i64,
                message.cleared_summary,
                message.refetch_args,
                message.is_compaction_summary as i64,
                message.prompt_tokens,
                message.completion_tokens,
                message.total_tokens,
                message.reasoning,
                message.attachments_json,
                message.generation_status,
            ],
        )?;
    }
    Ok(())
}

fn enqueue_generation_task_tx(
    tx: &Transaction<'_>,
    task: &NewGenerationTask,
) -> rusqlite::Result<()> {
    let inserted = tx.execute(
        "INSERT INTO generation_tasks
         (id, conversation_id, assistant_message_id, status, request_json, priority,
          max_attempts, created_at, updated_at)
         VALUES (?1, ?2, ?3, 'queued', ?4, ?5, ?6, ?7, ?7)
         ON CONFLICT(id) DO NOTHING",
        params![
            task.id,
            task.conversation_id,
            task.assistant_message_id,
            task.request_json,
            task.priority,
            task.max_attempts,
            task.created_at
        ],
    )?;
    if inserted != 0 {
        append_event_tx(tx, &task.id, None, "enqueued", None, task.created_at)?;
    }
    Ok(())
}

fn recover_expired_tx(tx: &Transaction<'_>, now_ms: i64) -> rusqlite::Result<Vec<String>> {
    let expired: Vec<(String, i64, i64)> = {
        let mut stmt = tx.prepare(
            "SELECT id, attempt_count, max_attempts
             FROM generation_tasks
             WHERE status IN ('leased', 'running')
               AND lease_expires_at IS NOT NULL
               AND lease_expires_at <= ?1
             ORDER BY id",
        )?;
        let rows = stmt
            .query_map(params![now_ms], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })?
            .collect::<rusqlite::Result<_>>()?;
        rows
    };

    for (task_id, attempt_count, max_attempts) in &expired {
        let run_id: Option<String> = tx
            .query_row(
                "SELECT id FROM generation_runs
                 WHERE task_id = ?1 AND status IN ('leased', 'running')
                 ORDER BY attempt DESC LIMIT 1",
                params![task_id],
                |row| row.get(0),
            )
            .optional()?;
        let ambiguous_dispatch = if let Some(run_id) = run_id.as_deref() {
            tx.query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM provider_calls
                    WHERE run_id = ?1
                      AND status NOT IN ('prepared', 'failed_before_send')
                 )",
                params![run_id],
                |row| row.get::<_, bool>(0),
            )?
        } else {
            false
        };
        let run_status = if ambiguous_dispatch {
            "outcome_unknown"
        } else {
            "interrupted"
        };
        tx.execute(
            "UPDATE generation_runs
             SET status = ?3, error = 'lease expired',
                 updated_at = ?2, finished_at = ?2
             WHERE task_id = ?1 AND status IN ('leased', 'running')",
            params![task_id, now_ms, run_status],
        )?;

        let exhausted = attempt_count >= max_attempts;
        let status = if ambiguous_dispatch {
            "outcome_unknown"
        } else if exhausted {
            "failed"
        } else {
            "queued"
        };
        tx.execute(
            "UPDATE generation_tasks
             SET status = ?2, lease_owner = NULL, lease_expires_at = NULL,
                 last_error = 'lease expired', updated_at = ?3,
                 finished_at = CASE WHEN ?4 OR ?5 THEN ?3 ELSE NULL END
             WHERE id = ?1",
            params![task_id, status, now_ms, exhausted, ambiguous_dispatch],
        )?;
        append_event_tx(
            tx,
            task_id,
            run_id.as_deref(),
            if ambiguous_dispatch {
                "outcome_unknown"
            } else if exhausted {
                "attempts_exhausted"
            } else {
                "recovered"
            },
            Some("lease expired"),
            now_ms,
        )?;
    }

    Ok(expired.into_iter().map(|(id, _, _)| id).collect())
}

fn append_event_tx(
    connection: &rusqlite::Connection,
    task_id: &str,
    run_id: Option<&str>,
    event_type: &str,
    payload_json: Option<&str>,
    created_at: i64,
) -> rusqlite::Result<i64> {
    connection.execute(
        "INSERT INTO generation_lifecycle_events
         (task_id, run_id, event_type, payload_json, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![task_id, run_id, event_type, payload_json, created_at],
    )?;
    Ok(connection.last_insert_rowid())
}

fn generation_task_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<GenerationTask> {
    Ok(GenerationTask {
        id: row.get(0)?,
        conversation_id: row.get(1)?,
        assistant_message_id: row.get(2)?,
        status: row.get(3)?,
        request_json: row.get(4)?,
        priority: row.get(5)?,
        attempt_count: row.get(6)?,
        max_attempts: row.get(7)?,
        lease_owner: row.get(8)?,
        lease_expires_at: row.get(9)?,
        checkpoint_json: row.get(10)?,
        last_error: row.get(11)?,
        created_at: row.get(12)?,
        updated_at: row.get(13)?,
        started_at: row.get(14)?,
        finished_at: row.get(15)?,
    })
}

fn generation_run_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<GenerationRun> {
    Ok(GenerationRun {
        id: row.get(0)?,
        task_id: row.get(1)?,
        attempt: row.get(2)?,
        status: row.get(3)?,
        worker_id: row.get(4)?,
        checkpoint_json: row.get(5)?,
        error: row.get(6)?,
        started_at: row.get(7)?,
        updated_at: row.get(8)?,
        finished_at: row.get(9)?,
    })
}

fn generation_command_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<GenerationCommand> {
    Ok(GenerationCommand {
        id: row.get(0)?,
        task_id: row.get(1)?,
        kind: row.get(2)?,
        payload_json: row.get(3)?,
        status: row.get(4)?,
        created_at: row.get(5)?,
        acknowledged_at: row.get(6)?,
    })
}

fn provider_call_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ProviderCall> {
    Ok(ProviderCall {
        id: row.get(0)?,
        run_id: row.get(1)?,
        provider: row.get(2)?,
        model: row.get(3)?,
        status: row.get(4)?,
        request_json: row.get(5)?,
        response_json: row.get(6)?,
        error: row.get(7)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
        finished_at: row.get(10)?,
    })
}

fn tool_execution_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ToolExecution> {
    Ok(ToolExecution {
        id: row.get(0)?,
        run_id: row.get(1)?,
        tool_call_id: row.get(2)?,
        tool_name: row.get(3)?,
        status: row.get(4)?,
        input_json: row.get(5)?,
        output_json: row.get(6)?,
        error: row.get(7)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
        finished_at: row.get(10)?,
    })
}

fn generation_lifecycle_event_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<GenerationLifecycleEvent> {
    Ok(GenerationLifecycleEvent {
        id: row.get(0)?,
        task_id: row.get(1)?,
        run_id: row.get(2)?,
        event_type: row.get(3)?,
        payload_json: row.get(4)?,
        created_at: row.get(5)?,
    })
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use tokio_rusqlite::rusqlite;

    use super::{
        ConversationsDb, GenerationCheckpoint, GenerationFinish, NewGenerationCommand,
        NewGenerationTask, ProviderCall, StoredConversation, StoredMessage, ToolExecution,
    };

    fn conversation(id: &str, is_pinned: bool) -> StoredConversation {
        StoredConversation {
            id: id.to_string(),
            title: id.to_string(),
            provider_account: None,
            created_at: "2026-01-01T00:00:00Z".to_string(),
            current_leaf_id: None,
            is_pinned,
            updated_at: 0,
            messages: Vec::new(),
        }
    }

    fn message(id: &str, conversation_id: &str, text: &str) -> StoredMessage {
        StoredMessage {
            id: id.to_string(),
            conversation_id: conversation_id.to_string(),
            role: "assistant".to_string(),
            text: text.to_string(),
            parent_id: None,
            children_ids: "[]".to_string(),
            original_content: None,
            has_error: false,
            active_child_id: None,
            tool_call_id: None,
            tool_calls_json: None,
            created_at: "2026-01-01T00:00:00Z".to_string(),
            cleared: false,
            cleared_summary: None,
            refetch_args: None,
            is_compaction_summary: false,
            prompt_tokens: None,
            completion_tokens: None,
            total_tokens: None,
            reasoning: None,
            attachments_json: None,
            generation_status: "none".to_string(),
        }
    }

    fn task(id: &str, conversation_id: &str, max_attempts: i64) -> NewGenerationTask {
        NewGenerationTask {
            id: id.to_string(),
            conversation_id: conversation_id.to_string(),
            assistant_message_id: None,
            request_json: "{}".to_string(),
            priority: 0,
            max_attempts,
            created_at: 10,
        }
    }

    #[tokio::test]
    async fn file_databases_enable_wal_and_busy_timeout() {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "havencat-conversations-{}-{suffix}.db",
            std::process::id()
        ));
        let db = ConversationsDb::open(&path).await.unwrap();
        let settings = db
            .conn
            .call(
                |connection| -> std::result::Result<(String, i64), rusqlite::Error> {
                    let journal_mode =
                        connection.query_row("PRAGMA journal_mode", [], |row| row.get(0))?;
                    let busy_timeout =
                        connection.query_row("PRAGMA busy_timeout", [], |row| row.get(0))?;
                    Ok((journal_mode, busy_timeout))
                },
            )
            .await
            .unwrap();
        assert_eq!(settings.0, "wal");
        assert_eq!(settings.1, 5_000);

        drop(db);
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(path.with_extension("db-wal"));
        let _ = std::fs::remove_file(path.with_extension("db-shm"));
    }

    #[tokio::test]
    async fn pin_state_persists_and_pinned_conversations_load_first() {
        let db = ConversationsDb::open_in_memory().await.unwrap();
        db.upsert_conversation(&conversation("regular", false))
            .await
            .unwrap();
        db.upsert_conversation(&conversation("pinned", true))
            .await
            .unwrap();

        let loaded = db.load_all().await.unwrap();
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].id, "pinned");
        assert!(loaded[0].is_pinned);
        assert!(!loaded[1].is_pinned);
    }

    #[tokio::test]
    async fn incremental_upsert_preserves_omitted_messages() {
        let db = ConversationsDb::open_in_memory().await.unwrap();
        let mut initial = conversation("conversation", false);
        initial.messages = vec![
            message("first", "conversation", "before"),
            message("second", "conversation", "keep"),
        ];
        db.upsert_conversation(&initial).await.unwrap();

        let mut partial = conversation("conversation", true);
        partial.messages = vec![message("first", "conversation", "after")];
        db.upsert_conversation(&partial).await.unwrap();

        let loaded = db.load_all().await.unwrap();
        assert_eq!(loaded.len(), 1);
        assert!(loaded[0].is_pinned);
        assert_eq!(loaded[0].messages.len(), 2);
        assert_eq!(
            loaded[0]
                .messages
                .iter()
                .find(|item| item.id == "first")
                .unwrap()
                .text,
            "after"
        );
        assert!(loaded[0].messages.iter().any(|item| item.id == "second"));
    }

    #[tokio::test]
    async fn conversation_and_generation_enqueue_roll_back_together() {
        let db = ConversationsDb::open_in_memory().await.unwrap();
        let mut invalid_task = task("task", "conversation", 1);
        invalid_task.assistant_message_id = Some("missing-message".to_string());

        assert!(db
            .upsert_conversation_and_enqueue(&conversation("conversation", false), &invalid_task,)
            .await
            .is_err());
        assert!(db.load_all().await.unwrap().is_empty());
        assert!(db.get_generation_task("task").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn generation_lease_checkpoint_command_recovery_and_finish_are_durable() {
        let db = ConversationsDb::open_in_memory().await.unwrap();
        let conv = conversation("conversation", false);
        db.upsert_conversation_and_enqueue(&conv, &task("task", "conversation", 2))
            .await
            .unwrap();

        let first = db
            .claim_generation_task("worker-a", 100, 10)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(first.task.status, "leased");
        assert_eq!(first.run.attempt, 1);
        assert!(!db
            .checkpoint_generation(&GenerationCheckpoint {
                task_id: "task".to_string(),
                run_id: first.run.id.clone(),
                worker_id: "worker-b".to_string(),
                checkpoint_json: r#"{"offset":1}"#.to_string(),
                now_ms: 105,
                lease_duration_ms: 10,
            })
            .await
            .unwrap());
        assert!(db
            .checkpoint_generation(&GenerationCheckpoint {
                task_id: "task".to_string(),
                run_id: first.run.id.clone(),
                worker_id: "worker-a".to_string(),
                checkpoint_json: r#"{"offset":1}"#.to_string(),
                now_ms: 105,
                lease_duration_ms: 10,
            })
            .await
            .unwrap());

        db.upsert_provider_call(&ProviderCall {
            id: "provider-call".to_string(),
            run_id: first.run.id.clone(),
            provider: "provider".to_string(),
            model: Some("model".to_string()),
            status: "prepared".to_string(),
            request_json: "{}".to_string(),
            response_json: None,
            error: None,
            created_at: 105,
            updated_at: 105,
            finished_at: None,
        })
        .await
        .unwrap();
        db.upsert_tool_execution(&ToolExecution {
            id: "tool".to_string(),
            run_id: first.run.id.clone(),
            tool_call_id: Some("call".to_string()),
            tool_name: "search".to_string(),
            status: "succeeded".to_string(),
            input_json: "{}".to_string(),
            output_json: Some("{}".to_string()),
            error: None,
            created_at: 105,
            updated_at: 106,
            finished_at: Some(106),
        })
        .await
        .unwrap();
        assert_eq!(
            db.load_provider_calls(&first.run.id).await.unwrap().len(),
            1
        );
        assert_eq!(
            db.load_tool_executions(&first.run.id).await.unwrap().len(),
            1
        );

        db.enqueue_generation_command(&NewGenerationCommand {
            id: "stop-command".to_string(),
            task_id: "task".to_string(),
            kind: "cancel".to_string(),
            payload_json: None,
            created_at: 106,
        })
        .await
        .unwrap();
        assert_eq!(
            db.load_pending_generation_commands("task")
                .await
                .unwrap()
                .len(),
            1
        );
        assert!(db
            .acknowledge_generation_command("stop-command", 107)
            .await
            .unwrap());

        assert_eq!(
            db.recover_expired_generation_tasks(116).await.unwrap(),
            vec!["task".to_string()]
        );
        let second = db
            .claim_generation_task("worker-b", 117, 10)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(second.run.attempt, 2);
        assert!(db
            .finish_generation(&GenerationFinish {
                task_id: "task".to_string(),
                run_id: second.run.id,
                worker_id: "worker-b".to_string(),
                status: "succeeded".to_string(),
                checkpoint_json: Some(r#"{"offset":2}"#.to_string()),
                error: None,
                finished_at: 120,
            })
            .await
            .unwrap());

        let stored = db.get_generation_task("task").await.unwrap().unwrap();
        assert_eq!(stored.status, "succeeded");
        assert_eq!(stored.attempt_count, 2);
        assert!(stored.lease_owner.is_none());
        assert_eq!(db.load_generation_runs("task").await.unwrap().len(), 2);
        let event_types: Vec<String> = db
            .load_generation_lifecycle_events("task", None)
            .await
            .unwrap()
            .into_iter()
            .map(|event| event.event_type)
            .collect();
        assert_eq!(
            event_types,
            vec![
                "enqueued",
                "leased",
                "checkpoint",
                "command_enqueued",
                "recovered",
                "leased",
                "succeeded"
            ]
        );
    }

    #[tokio::test]
    async fn expired_dispatched_call_is_never_requeued() {
        let db = ConversationsDb::open_in_memory().await.unwrap();
        db.upsert_conversation_and_enqueue(
            &conversation("conversation", false),
            &task("task", "conversation", 2),
        )
        .await
        .unwrap();
        let claim = db
            .claim_generation_task("worker", 100, 10)
            .await
            .unwrap()
            .unwrap();
        db.upsert_provider_call(&ProviderCall {
            id: "provider-call".to_string(),
            run_id: claim.run.id,
            provider: "provider".to_string(),
            model: Some("model".to_string()),
            status: "sending".to_string(),
            request_json: "{}".to_string(),
            response_json: None,
            error: None,
            created_at: 101,
            updated_at: 101,
            finished_at: None,
        })
        .await
        .unwrap();

        db.recover_expired_generation_tasks(111).await.unwrap();

        let stored = db.get_generation_task("task").await.unwrap().unwrap();
        assert_eq!(stored.status, "outcome_unknown");
        assert!(db
            .claim_generation_task("other-worker", 112, 10)
            .await
            .unwrap()
            .is_none());
    }

    #[test]
    fn versioned_migration_upgrades_a_v1_database() {
        let mut connection = tokio_rusqlite::rusqlite::Connection::open_in_memory().unwrap();
        connection
            .execute_batch(include_str!("schema.sql"))
            .unwrap();
        connection.pragma_update(None, "user_version", 1).unwrap();

        crate::conversations::migrations::migrate(&mut connection).unwrap();

        let version: i64 = connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        let generation_table: String = connection
            .query_row(
                "SELECT name FROM sqlite_master
                 WHERE type = 'table' AND name = 'generation_tasks'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            version,
            crate::conversations::migrations::LATEST_SCHEMA_VERSION
        );
        assert_eq!(generation_table, "generation_tasks");
    }
}
