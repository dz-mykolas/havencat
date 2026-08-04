use std::error::Error as _;

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

impl WebRetrievalError {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Network(_) => "network",
            Self::Auth(_) => "authentication",
            Self::RateLimit { .. } => "rate_limited",
            Self::Quota(_) => "quota_exhausted",
            Self::InvalidRequest(_) => "invalid_request",
            Self::Database(_) => "storage",
            Self::ProviderNotFound(_) => "unavailable",
            Self::AllProvidersFailed(_) | Self::Other(_) => "unknown",
        }
    }

    pub fn retry_after_secs(&self) -> Option<u64> {
        match self {
            Self::RateLimit {
                retry_after_secs, ..
            } => *retry_after_secs,
            _ => None,
        }
    }
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
        let detail = reqwest_error_detail(&e);
        if e.status() == Some(reqwest::StatusCode::UNAUTHORIZED) {
            WebRetrievalError::Auth(detail)
        } else {
            WebRetrievalError::Network(detail)
        }
    }
}

fn reqwest_error_detail(error: &reqwest::Error) -> String {
    let mut details = vec![error.to_string()];
    let mut source = error.source();
    while let Some(cause) = source {
        let detail = cause.to_string();
        if !details.contains(&detail) {
            details.push(detail);
        }
        source = cause.source();
    }
    details.join(": ")
}

impl From<serde_json::Error> for WebRetrievalError {
    fn from(e: serde_json::Error) -> Self {
        WebRetrievalError::InvalidRequest(format!("json: {e}"))
    }
}

pub type Result<T, E = WebRetrievalError> = std::result::Result<T, E>;
