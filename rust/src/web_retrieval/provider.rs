use serde::{Deserialize, Serialize};

use super::error::Result;

/// A single search result.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub title: String,
    pub url: String,
    #[serde(default)]
    pub snippet: String,
    #[serde(default)]
    pub published_at: Option<i64>,
    /// Which provider produced this result.
    #[serde(default)]
    pub provider: String,
}

/// Options for a search call.
#[derive(Debug, Clone)]
pub struct SearchOptions {
    pub num_results: usize,
}

impl Default for SearchOptions {
    fn default() -> Self {
        Self { num_results: 5 }
    }
}

/// A fetched page.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FetchedPage {
    pub url: String,
    pub title: String,
    pub content: String,
    pub content_type: String,
}

/// Options for a fetch call.
#[derive(Debug, Clone)]
pub struct FetchOptions {
    pub format: FetchFormat,
}

impl Default for FetchOptions {
    fn default() -> Self {
        Self {
            format: FetchFormat::Markdown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchFormat {
    Markdown,
    Text,
    Html,
}

/// A web search provider. Stateless — auth/config come in via `secret`.
#[async_trait::async_trait]
pub trait WebSearchProvider: Send + Sync {
    fn kind(&self) -> &'static str;
    async fn search(
        &self,
        query: &str,
        secret: Option<&str>,
        options: SearchOptions,
    ) -> Result<Vec<SearchResult>>;
}

/// A URL fetch provider. Stateless — auth/config come in via `secret`.
#[async_trait::async_trait]
pub trait UrlFetchProvider: Send + Sync {
    fn kind(&self) -> &'static str;
    async fn fetch(
        &self,
        url: &str,
        secret: Option<&str>,
        options: FetchOptions,
    ) -> Result<FetchedPage>;
}
