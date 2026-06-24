use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::web_retrieval::error::{Result, WebRetrievalError};
use crate::web_retrieval::provider::{
    FetchFormat, FetchOptions, FetchedPage, SearchOptions, SearchResult, UrlFetchProvider,
    WebSearchProvider,
};

const EXA_MCP_URL: &str = "https://mcp.exa.ai/mcp";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(25);

/// Exa hosted MCP provider. No-key path uses the server free-tier key + IP
/// rate limiting. If `secret` is set, it's appended as `?exaApiKey=...` to
/// bypass IP rate limiting.
///
/// Mirrors OpenCode's approach: a single stateless JSON-RPC `tools/call` POST,
/// no `initialize` handshake (Exa's hosted MCP allows this).
pub struct ExaMcpProvider {
    client: reqwest::Client,
}

impl ExaMcpProvider {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .expect("reqwest client");
        Self { client }
    }

    fn endpoint(secret: Option<&str>) -> String {
        match secret {
            Some(key) if !key.is_empty() => {
                format!("{EXA_MCP_URL}?exaApiKey={}", urlencoding::encode(key))
            }
            _ => EXA_MCP_URL.to_string(),
        }
    }

    async fn call_tool(
        &self,
        endpoint: &str,
        tool: &str,
        args: serde_json::Value,
    ) -> Result<String> {
        let body = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": { "name": tool, "arguments": args }
        });

        let resp = self
            .client
            .post(endpoint)
            .header("Accept", "application/json, text/event-stream")
            .json(&body)
            .send()
            .await?;

        let status = resp.status();
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            let retry_after = resp
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok());
            return Err(WebRetrievalError::RateLimit {
                provider: "exa".into(),
                retry_after_secs: retry_after,
            });
        }
        if status == reqwest::StatusCode::UNAUTHORIZED {
            return Err(WebRetrievalError::Auth("exa: invalid api key".into()));
        }
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(WebRetrievalError::Network(format!("exa: {status} {text}")));
        }

        let text = resp.text().await?;
        parse_mcp_response(&text).ok_or_else(|| {
            WebRetrievalError::Network("exa: empty/unparseable response".into())
        })
    }
}

impl Default for ExaMcpProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl WebSearchProvider for ExaMcpProvider {
    fn kind(&self) -> &'static str {
        "exa"
    }

    async fn search(
        &self,
        query: &str,
        secret: Option<&str>,
        options: SearchOptions,
    ) -> Result<Vec<SearchResult>> {
        let endpoint = Self::endpoint(secret);
        let args = json!({
            "query": query,
            "type": "auto",
            "numResults": options.num_results,
            "livecrawl": "fallback",
        });
        let text = self.call_tool(&endpoint, "web_search_exa", args).await?;
        let parsed: ExaSearchResponse = serde_json::from_str(&text).unwrap_or_default();
        Ok(parsed
            .results
            .into_iter()
            .map(|r| SearchResult {
                title: r.title,
                url: r.url,
                snippet: r.text.unwrap_or_default(),
                published_at: None,
                provider: "exa".into(),
            })
            .collect())
    }
}

#[async_trait]
impl UrlFetchProvider for ExaMcpProvider {
    fn kind(&self) -> &'static str {
        "exa"
    }

    async fn fetch(
        &self,
        url: &str,
        secret: Option<&str>,
        options: FetchOptions,
    ) -> Result<FetchedPage> {
        let endpoint = Self::endpoint(secret);
        let args = json!({ "url": url });
        let text = self.call_tool(&endpoint, "web_fetch_exa", args).await?;
        let parsed: ExaFetchResponse = serde_json::from_str(&text).unwrap_or_default();
        Ok(FetchedPage {
            url: url.to_string(),
            title: parsed.title.unwrap_or_default(),
            content: parsed.markdown.unwrap_or(text),
            content_type: match options.format {
                FetchFormat::Markdown => "text/markdown",
                FetchFormat::Text => "text/plain",
                FetchFormat::Html => "text/html",
            }
            .into(),
        })
    }
}

/// Parse an MCP `tools/call` response. Handles both direct JSON and SSE
/// `data:` lines (Exa may return either).
fn parse_mcp_response(body: &str) -> Option<String> {
    if let Some(s) = parse_payload(body.trim()) {
        return Some(s);
    }
    for line in body.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("data: ") {
            if let Some(s) = parse_payload(rest) {
                return Some(s);
            }
        }
    }
    None
}

fn parse_payload(payload: &str) -> Option<String> {
    if !payload.starts_with('{') {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(payload).ok()?;
    let content = v.get("result")?.get("content")?.as_array()?;
    content
        .iter()
        .find(|c| c.get("type").and_then(|t| t.as_str()) == Some("text"))
        .and_then(|c| c.get("text"))
        .and_then(|t| t.as_str())
        .map(|s| s.to_string())
}

#[derive(Serialize, Deserialize, Default)]
struct ExaSearchResponse {
    #[serde(default)]
    results: Vec<ExaSearchItem>,
}

#[derive(Serialize, Deserialize)]
struct ExaSearchItem {
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    text: Option<String>,
}

#[derive(Serialize, Deserialize, Default)]
struct ExaFetchResponse {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    markdown: Option<String>,
}

// Minimal URL-encoding for the api key query param (avoid pulling a crate).
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
