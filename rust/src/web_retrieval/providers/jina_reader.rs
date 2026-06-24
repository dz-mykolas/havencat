use std::time::Duration;

use async_trait::async_trait;

use crate::web_retrieval::error::Result;
use crate::web_retrieval::provider::{
    FetchOptions, FetchedPage, UrlFetchProvider,
};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const JINA_READER_BASE: &str = "https://r.jina.ai/";

/// Jina Reader provider. URL -> markdown. No key required for basic use
/// (~20 RPM anonymous). If `secret` is set, sent as `Authorization: Bearer`.
pub struct JinaReaderProvider {
    client: reqwest::Client,
}

impl JinaReaderProvider {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .expect("reqwest client");
        Self { client }
    }
}

impl Default for JinaReaderProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl UrlFetchProvider for JinaReaderProvider {
    fn kind(&self) -> &'static str {
        "jina_reader"
    }

    async fn fetch(
        &self,
        url: &str,
        secret: Option<&str>,
        _options: FetchOptions,
    ) -> Result<FetchedPage> {
        let endpoint = format!("{JINA_READER_BASE}{url}");
        let mut req = self
            .client
            .get(&endpoint)
            .header("Accept", "text/markdown, text/plain;q=0.8, */*;q=0.1")
            .header("X-Return-Format", "markdown");
        if let Some(key) = secret.filter(|s| !s.is_empty()) {
            req = req.bearer_auth(key);
        }
        let resp = req.send().await?;
        let status = resp.status();
        if !status.is_success() {
            return Err(crate::web_retrieval::error::WebRetrievalError::Network(
                format!("jina_reader: {status}"),
            ));
        }
        let content = resp.text().await?;
        // r.jina.ai returns markdown; the first line is often a "Title: ..." header.
        let title = content
            .lines()
            .find_map(|l| l.trim().strip_prefix("Title:").map(|s| s.trim().to_string()))
            .unwrap_or_default();
        Ok(FetchedPage {
            url: url.to_string(),
            title,
            content,
            content_type: "text/markdown".into(),
        })
    }
}
