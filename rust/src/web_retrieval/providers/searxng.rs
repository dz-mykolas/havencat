use std::time::Duration;

use async_trait::async_trait;
use serde::Deserialize;

use crate::web_retrieval::error::{Result, WebRetrievalError};
use crate::web_retrieval::provider::{SearchOptions, SearchResult, WebSearchProvider};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// SearXNG public-instance provider. No key. The instance URL is passed in
/// `secret` (reused as a config slot) — e.g. `https://searx.be`.
pub struct SearxngProvider {
    client: reqwest::Client,
}

impl SearxngProvider {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .expect("reqwest client");
        Self { client }
    }
}

impl Default for SearxngProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl WebSearchProvider for SearxngProvider {
    fn kind(&self) -> &'static str {
        "searxng"
    }

    async fn search(
        &self,
        query: &str,
        secret: Option<&str>,
        options: SearchOptions,
    ) -> Result<Vec<SearchResult>> {
        let base = secret
            .filter(|s| !s.is_empty())
            .ok_or_else(|| WebRetrievalError::InvalidRequest("searxng: instance url required".into()))?
            .trim_end_matches('/');

        let resp = self
            .client
            .get(format!(
                "{base}/search?q={}&format=json&pageno=1",
                urlencoding::encode(query)
            ))
            .header("Accept", "application/json")
            .send()
            .await?;

        let status = resp.status();
        if !status.is_success() {
            return Err(WebRetrievalError::Network(format!(
                "searxng: {status} from {base}"
            )));
        }
        let body: SearxngResponse = resp.json().await?;
        Ok(body
            .results
            .into_iter()
            .take(options.num_results)
            .map(|r| SearchResult {
                title: r.title,
                url: r.url,
                snippet: r.content.unwrap_or_default(),
                published_at: None,
                provider: "searxng".into(),
            })
            .collect())
    }
}

#[derive(Deserialize)]
struct SearxngResponse {
    #[serde(default)]
    results: Vec<SearxngItem>,
}

#[derive(Deserialize)]
struct SearxngItem {
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    content: Option<String>,
}

// Minimal URL-encoding for the query param.
mod urlencoding {
    pub fn encode(s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        for b in s.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(b as char)
                }
                _ => out.push_str(&format!("%{:02X}", b)),
            }
        }
        out
    }
}
