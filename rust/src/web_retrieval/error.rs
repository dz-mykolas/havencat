use thiserror::Error;

#[derive(Debug, Error)]
pub enum WebRetrievalError {
    #[error("network error: {0}")]
    Network(String),

    #[error("auth error: {0}")]
    Auth(String),

    #[error("rate limited by provider {provider}; retry after {retry_after_secs:?}s")]
    RateLimit {
        provider: String,
        retry_after_secs: Option<u64>,
    },

    #[error("quota exhausted for provider {0}")]
    Quota(String),

    #[error("invalid request: {0}")]
    InvalidRequest(String),

    #[error("database error: {0}")]
    Database(String),

    #[error("all providers failed: {0}")]
    AllProvidersFailed(String),

    #[error("provider not found: {0}")]
    ProviderNotFound(String),

    #[error("{0}")]
    Other(String),
}

impl From<tokio_rusqlite::Error<tokio_rusqlite::rusqlite::Error>> for WebRetrievalError {
    fn from(e: tokio_rusqlite::Error<tokio_rusqlite::rusqlite::Error>) -> Self {
        WebRetrievalError::Database(e.to_string())
    }
}

impl From<tokio_rusqlite::rusqlite::Error> for WebRetrievalError {
    fn from(e: tokio_rusqlite::rusqlite::Error) -> Self {
        WebRetrievalError::Database(e.to_string())
    }
}

impl From<reqwest::Error> for WebRetrievalError {
    fn from(e: reqwest::Error) -> Self {
        if e.status() == Some(reqwest::StatusCode::UNAUTHORIZED) {
            WebRetrievalError::Auth(e.to_string())
        } else {
            WebRetrievalError::Network(e.to_string())
        }
    }
}

impl From<serde_json::Error> for WebRetrievalError {
    fn from(e: serde_json::Error) -> Self {
        WebRetrievalError::InvalidRequest(format!("json: {e}"))
    }
}

pub type Result<T, E = WebRetrievalError> = std::result::Result<T, E>;
