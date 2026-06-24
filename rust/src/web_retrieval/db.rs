use std::path::Path;
use std::sync::Arc;
use tokio_rusqlite::rusqlite;
use tokio_rusqlite::Connection;

use super::error::{Result, WebRetrievalError};

const SCHEMA_SQL: &str = include_str!("schema.sql");

/// A handle to the web-retrieval SQLite database. Cheap to clone (the inner
/// `tokio_rusqlite::Connection` is an actor sender).
#[derive(Clone)]
pub struct Db {
    conn: Connection,
}

impl Db {
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

    /// Raw handle for use by the cache layer.
    pub fn conn(&self) -> Connection {
        self.conn.clone()
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
            .await?;
        Ok(())
    }

    pub async fn migrate(&self) -> Result<()> {
        self.conn
            .call(|c| -> std::result::Result<(), rusqlite::Error> {
                c.execute_batch(SCHEMA_SQL)?;
                Ok(())
            })
            .await
            .map_err(|e| WebRetrievalError::Database(e.to_string()))?;
        Ok(())
    }
}

/// Shared DB handle wrapped in `Arc` for global access from FRB-exposed fns.
pub type SharedDb = Arc<Db>;
