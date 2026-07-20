use thiserror::Error;

pub type Result<T> = std::result::Result<T, ConversationsError>;

#[derive(Debug, Error)]
pub enum ConversationsError {
    #[error("database error: {0}")]
    Database(String),
    #[error("not configured: call configure_conversations first")]
    NotConfigured,
    #[error("conversation database is already configured at {configured}; requested {requested}")]
    AlreadyConfigured {
        configured: String,
        requested: String,
    },
    #[error("invalid database path: {0}")]
    InvalidPath(String),
    #[error("invalid argument: {0}")]
    InvalidArgument(String),
    #[error("serialization error: {0}")]
    Serialization(String),
}

impl From<tokio_rusqlite::rusqlite::Error> for ConversationsError {
    fn from(e: tokio_rusqlite::rusqlite::Error) -> Self {
        ConversationsError::Database(e.to_string())
    }
}
