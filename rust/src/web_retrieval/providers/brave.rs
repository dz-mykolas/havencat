use std::time::Duration;

use async_trait::async_trait;
use serde::Deserialize;

use crate::web_retrieval::error::{Result, WebRetrievalError};
use crate::web_retrieval::provider::{SearchOptions, SearchResult, WebSearchProvider};

const BRAVE_SEARCH_URL: &str = "https://api.search.brave.com/res/v1/web/search";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

pub struct BraveSearchProvider {
    client: reqwest::Client,
}

impl BraveSearchProvider {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(REQUEST_TIMEOUT)
                .build()
                .expect("reqwest client"),
        }
    }
}

impl Default for BraveSearchProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl WebSearchProvider for BraveSearchProvider {
    fn kind(&self) -> &'static str {
        "brave"
    }

    async fn search(
        &self,
        query: &str,
        secret: Option<&str>,
        _endpoint: Option<&str>,
        options: SearchOptions,
    ) -> Result<Vec<SearchResult>> {
        let key = secret
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| WebRetrievalError::Auth("brave api key required".into()))?;
        let url = format!(
            "{BRAVE_SEARCH_URL}?q={}&count={}",
            encode_query(query),
            options.num_results
        );
        let response = self
            .client
            .get(url)
            .header("Accept", "application/json")
            .header("X-Subscription-Token", key)
            .send()
            .await?;
        let status = response.status();
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            let retry_after_secs = response
                .headers()
                .get("retry-after")
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse::<u64>().ok());
            return Err(WebRetrievalError::RateLimit {
                provider: "brave".into(),
                retry_after_secs,
            });
        }
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(WebRetrievalError::Auth("brave credentials rejected".into()));
        }
        if status == reqwest::StatusCode::PAYMENT_REQUIRED {
            return Err(WebRetrievalError::Quota("brave".into()));
        }
        if !status.is_success() {
            return Err(WebRetrievalError::Network(format!(
                "brave returned {status}"
            )));
        }
        let body: BraveResponse = response.json().await?;
        Ok(body
            .web
            .map(|web| web.results)
            .unwrap_or_default()
            .into_iter()
            .take(options.num_results)
            .map(|item| SearchResult {
                title: item.title,
                url: item.url,
                snippet: item.description.unwrap_or_default(),
                published_at: None,
                provider: "brave".into(),
            })
            .collect())
    }
}

#[derive(Deserialize)]
struct BraveResponse {
    web: Option<BraveWebResults>,
}

#[derive(Deserialize)]
struct BraveWebResults {
    #[serde(default)]
    results: Vec<BraveResult>,
}

#[derive(Deserialize)]
struct BraveResult {
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
    description: Option<String>,
}

fn encode_query(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                output.push(byte as char)
            }
            _ => output.push_str(&format!("%{byte:02X}")),
        }
    }
    output
}
