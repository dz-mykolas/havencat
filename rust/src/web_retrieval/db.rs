use std::path::Path;
use std::sync::Arc;
use tokio_rusqlite::rusqlite;
use tokio_rusqlite::Connection;

use super::error::{Result, WebRetrievalError};

const SCHEMA_SQL: &str = include_str!("schema.sql");
const SCHEMA_VERSION: i64 = 1;

/// A handle to the web-retrieval SQLite database. Cheap to clone (the inner
/// `tokio_rusqlite::Connection` is an actor sender).
#[derive(Clone)]
pub struct Db {
    conn: Connection,
}

impl Db {
    /// Open or create the current database schema at `path`.
    pub async fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path.as_ref()).await?;
        let db = Self { conn };
        db.configure_pragmas().await?;
        db.initialize_schema().await?;
        Ok(db)
    }

    /// In-memory database, for tests.
    pub async fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().await?;
        let db = Self { conn };
        db.configure_pragmas().await?;
        db.initialize_schema().await?;
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

    pub async fn initialize_schema(&self) -> Result<()> {
        self.conn
            .call(initialize_schema)
            .await
            .map_err(|e| WebRetrievalError::Database(e.to_string()))?;
        Ok(())
    }
}

/// Shared DB handle wrapped in `Arc` for global access from FRB-exposed fns.
pub type SharedDb = Arc<Db>;

fn initialize_schema(connection: &mut rusqlite::Connection) -> rusqlite::Result<()> {
    let version = connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
    if version == SCHEMA_VERSION {
        return Ok(());
    }
    if version != 0 {
        return Err(rusqlite::Error::InvalidParameterName(format!(
            "unsupported web-retrieval schema version {version}; clear the database"
        )));
    }
    let table_count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        [],
        |row| row.get(0),
    )?;
    if table_count != 0 {
        return Err(rusqlite::Error::InvalidParameterName(
            "unversioned web-retrieval schema; clear the database".to_string(),
        ));
    }

    let transaction = connection.transaction()?;
    transaction.execute_batch(SCHEMA_SQL)?;
    transaction.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    transaction.commit()
}
