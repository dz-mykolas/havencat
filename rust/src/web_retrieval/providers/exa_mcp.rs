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

/// Exa hosted MCP provider. The no-key path uses Exa's limited free access;
/// an optional API key raises those limits.
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

    async fn call_tool(
        &self,
        tool: &str,
        args: serde_json::Value,
        secret: Option<&str>,
    ) -> Result<String> {
        let body = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": { "name": tool, "arguments": args }
        });

        let mut request = self
            .client
            .post(EXA_MCP_URL)
            .header("Accept", "application/json, text/event-stream")
            .json(&body);
        if let Some(key) = secret.filter(|key| !key.trim().is_empty()) {
            request = request.header("x-api-key", key);
        }
        let resp = request.send().await?;

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
        if status == reqwest::StatusCode::PAYMENT_REQUIRED {
            return Err(WebRetrievalError::Quota("exa".into()));
        }
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(WebRetrievalError::Network(format!("exa: {status} {text}")));
        }

        let text = resp.text().await?;
        let (content, is_error) = parse_mcp_response(&text)
            .ok_or_else(|| WebRetrievalError::Network("exa: empty/unparseable response".into()))?;
        if is_error {
            return Err(classify_mcp_error(&content));
        }
        Ok(content)
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
        _endpoint: Option<&str>,
        options: SearchOptions,
    ) -> Result<Vec<SearchResult>> {
        let args = json!({
            "query": query,
            "type": "auto",
            "numResults": options.num_results,
            "livecrawl": "fallback",
        });
        let text = self.call_tool("web_search_exa", args, secret).await?;
        tracing::debug!(query = query, response = %text, "exa raw search response");

        // Exa's MCP tools/call returns results as markdown text, not JSON:
        //   Title: ...
        //   URL: ...
        //   Published: ...
        //   Author: ...
        //   Highlights:
        //   <snippet text>
        //   ---
        //   Title: ...
        //   ...
        let results = parse_exa_search_markdown(&text);
        tracing::info!(query = query, count = results.len(), "exa search parsed");
        Ok(results)
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
        let args = json!({ "url": url });
        let text = self.call_tool("web_fetch_exa", args, secret).await?;
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
fn parse_mcp_response(body: &str) -> Option<(String, bool)> {
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

fn parse_payload(payload: &str) -> Option<(String, bool)> {
    if !payload.starts_with('{') {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(payload).ok()?;
    let content = v.get("result")?.get("content")?.as_array()?;
    let text = content
        .iter()
        .find(|c| c.get("type").and_then(|t| t.as_str()) == Some("text"))
        .and_then(|c| c.get("text"))
        .and_then(|t| t.as_str())
        .map(|s| s.to_string())?;
    let is_error = v
        .get("result")
        .and_then(|result| result.get("isError"))
        .and_then(|value| value.as_bool())
        .unwrap_or(false);
    Some((text, is_error))
}

fn classify_mcp_error(message: &str) -> WebRetrievalError {
    let normalized = message.to_lowercase();
    if normalized.contains("rate limit") || normalized.contains("too many requests") {
        WebRetrievalError::RateLimit {
            provider: "exa".into(),
            retry_after_secs: None,
        }
    } else if normalized.contains("api key") || normalized.contains("unauthorized") {
        WebRetrievalError::Auth("exa credentials rejected".into())
    } else if normalized.contains("credit") || normalized.contains("quota") {
        WebRetrievalError::Quota("exa".into())
    } else {
        WebRetrievalError::Other("exa tool call failed".into())
    }
}

/// Parse Exa's markdown-formatted search response into [SearchResult]s.
///
/// Each result is a block with fields like `Title:`, `URL:`, `Published:`,
/// `Author:`, and `Highlights:` (the snippet). Blocks are separated by `---`.
fn parse_exa_search_markdown(text: &str) -> Vec<SearchResult> {
    // Split on `---` separators (possibly surrounded by whitespace).
    let blocks: Vec<&str> = text.split("\n---\n").collect();
    let mut results = Vec::new();

    for block in blocks {
        let block = block.trim();
        if block.is_empty() {
            continue;
        }

        let mut title = String::new();
        let mut url = String::new();
        let mut snippet = String::new();
        let mut published_at: Option<i64> = None;
        let mut in_highlights = false;

        for line in block.lines() {
            let line = line.trim_end();

            if in_highlights {
                // Everything after "Highlights:" until the next field or block
                // is the snippet text.
                if line.starts_with("Title:")
                    || line.starts_with("URL:")
                    || line.starts_with("Published:")
                    || line.starts_with("Author:")
                {
                    in_highlights = false;
                    // Re-process this line as a field below.
                } else {
                    if !snippet.is_empty() {
                        snippet.push(' ');
                    }
                    snippet.push_str(line.trim());
                    continue;
                }
            }

            if let Some(val) = line.strip_prefix("Title:") {
                title = val.trim().to_string();
            } else if let Some(val) = line.strip_prefix("URL:") {
                url = val.trim().to_string();
            } else if let Some(val) = line.strip_prefix("Published:") {
                let val = val.trim();
                if val != "N/A" && !val.is_empty() {
                    published_at = parse_exa_date(val);
                }
            } else if let Some(_val) = line.strip_prefix("Author:") {
                // Author is not part of SearchResult; skip.
            } else if line.starts_with("Highlights:") {
                in_highlights = true;
                let rest = line.strip_prefix("Highlights:").unwrap_or("").trim();
                if !rest.is_empty() {
                    snippet = rest.to_string();
                }
            }
        }

        // Only add if we got at least a URL (filters out empty blocks).
        if !url.is_empty() {
            results.push(SearchResult {
                title,
                url,
                snippet,
                published_at,
                provider: "exa".into(),
            });
        }
    }

    results
}

/// Parse an Exa date string (ISO 8601, e.g. "2009-03-02T12:55:27.000Z") into
/// Unix epoch seconds. Returns None if parsing fails.
fn parse_exa_date(s: &str) -> Option<i64> {
    // Exa dates look like "2009-03-02T12:55:27.000Z".
    // We only need the date part for a rough timestamp.
    let date_part = s.split('T').next()?;
    let mut parts = date_part.split('-');
    let year: i64 = parts.next()?.parse().ok()?;
    let month: i64 = parts.next()?.parse().ok()?;
    let day: i64 = parts.next()?.parse().ok()?;

    // Days from Unix epoch (1970-01-01) to the given date.
    // Simple approximation: ignore leap years beyond the standard rule.
    let days_in_month = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let is_leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);

    let mut total_days: i64 = 0;
    for y in 1970..year {
        total_days += if (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0) {
            366
        } else {
            365
        };
    }
    for m in 1..month {
        total_days += if m == 2 && is_leap {
            29
        } else {
            days_in_month[(m - 1) as usize]
        };
    }
    total_days += day - 1;

    Some(total_days * 86400)
}

#[derive(Serialize, Deserialize, Default)]
struct ExaFetchResponse {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    markdown: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_mcp_error_payloads() {
        let payload = r#"{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"Rate limit exceeded"}]}}"#;
        let (content, is_error) = parse_mcp_response(payload).expect("payload");

        assert_eq!(content, "Rate limit exceeded");
        assert!(is_error);
        assert!(matches!(
            classify_mcp_error(&content),
            WebRetrievalError::RateLimit { .. }
        ));
    }
}
