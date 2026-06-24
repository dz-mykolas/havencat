use std::time::Duration;

use async_trait::async_trait;

use crate::web_retrieval::error::{Result, WebRetrievalError};
use crate::web_retrieval::html::{extract_title, html_to_markdown, html_to_text};
use crate::web_retrieval::provider::{
    FetchFormat, FetchOptions, FetchedPage, UrlFetchProvider,
};

const MAX_RESPONSE_BYTES: usize = 5 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";

/// Direct HTTP fetcher (provider-less, like OpenCode's `webfetch`). Browser
/// User-Agent, 5MB cap, Cloudflare-challenge retry with honest UA, HTML→markdown.
pub struct DirectHttpProvider {
    client: reqwest::Client,
}

impl DirectHttpProvider {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .redirect(reqwest::redirect::Policy::limited(10))
            .build()
            .expect("reqwest client");
        Self { client }
    }

    async fn fetch_with_ua(&self, url: &str, ua: &str, format: FetchFormat) -> Result<FetchedPage> {
        let accept = match format {
            FetchFormat::Markdown => {
                "text/markdown;q=1.0, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1"
            }
            FetchFormat::Text => "text/plain;q=1.0, text/html;q=0.8, */*;q=0.1",
            FetchFormat::Html => "text/html;q=1.0, */*;q=0.5",
        };
        let resp = self
            .client
            .get(url)
            .header("User-Agent", ua)
            .header("Accept", accept)
            .header("Accept-Language", "en-US,en;q=0.9")
            .send()
            .await?;

        let status = resp.status();
        if !status.is_success() {
            return Err(WebRetrievalError::Network(format!("direct_http: {status}")));
        }
        let content_type = resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();
        let mime = content_type.split(';').next().unwrap_or("").trim().to_lowercase();

        // Read body with a size cap.
        let bytes = resp.bytes().await?;
        if bytes.len() > MAX_RESPONSE_BYTES {
            return Err(WebRetrievalError::Network(
                "direct_http: response exceeds 5MB".into(),
            ));
        }
        let body = String::from_utf8_lossy(&bytes).into_owned();

        let (title, content) = if mime.contains("text/html") {
            let title = extract_title(&body);
            let content = match format {
                FetchFormat::Markdown => html_to_markdown(&body),
                FetchFormat::Text => html_to_text(&body),
                FetchFormat::Html => body,
            };
            (title, content)
        } else {
            (String::new(), body)
        };

        Ok(FetchedPage {
            url: url.to_string(),
            title,
            content,
            content_type,
        })
    }
}

impl Default for DirectHttpProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl UrlFetchProvider for DirectHttpProvider {
    fn kind(&self) -> &'static str {
        "direct_http"
    }

    async fn fetch(
        &self,
        url: &str,
        _secret: Option<&str>,
        options: FetchOptions,
    ) -> Result<FetchedPage> {
        // First attempt with browser UA.
        match self.fetch_with_ua(url, BROWSER_UA, options.format).await {
            Ok(page) => Ok(page),
            Err(WebRetrievalError::Network(msg)) if msg.contains("403") => {
                // Possibly a Cloudflare bot challenge — retry with honest UA.
                self.fetch_with_ua(url, "opencode", options.format).await
            }
            Err(e) => Err(e),
        }
    }
}
