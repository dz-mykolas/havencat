use std::net::IpAddr;
use std::str::FromStr;
use std::time::Duration;

use async_trait::async_trait;
use serde::Deserialize;

use crate::web_retrieval::error::{Result, WebRetrievalError};
use crate::web_retrieval::provider::{SearchOptions, SearchResult, WebSearchProvider};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// SearXNG provider with an optional bearer access token.
pub struct SearxngProvider {
    client: reqwest::Client,
}

impl SearxngProvider {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("reqwest client");
        Self { client }
    }

    fn search_request(
        &self,
        base: &str,
        query: &str,
        access_token: Option<&str>,
    ) -> Result<reqwest::Request> {
        validate_endpoint(base, access_token)?;
        let mut request = self
            .client
            .get(format!(
                "{base}/search?q={}&format=json&pageno=1",
                urlencoding::encode(query)
            ))
            .header("Accept", "application/json");
        if let Some(access_token) = access_token.filter(|value| !value.trim().is_empty()) {
            request = request.bearer_auth(access_token.trim());
        }
        Ok(request.build()?)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum EndpointScope {
    Loopback,
    PrivateNetwork,
    PublicNetwork,
    Invalid,
}

fn validate_endpoint(base: &str, access_token: Option<&str>) -> Result<()> {
    let url = reqwest::Url::parse(base).map_err(|_| {
        WebRetrievalError::InvalidRequest("searxng requires an HTTP or HTTPS instance URL".into())
    })?;
    if url.scheme() != "http" && url.scheme() != "https" {
        return Err(WebRetrievalError::InvalidRequest(
            "searxng requires an HTTP or HTTPS instance URL".into(),
        ));
    }
    let scope = endpoint_scope(&url);
    if scope == EndpointScope::Invalid {
        return Err(WebRetrievalError::InvalidRequest(
            "enter a valid searxng instance address".into(),
        ));
    }
    if url.scheme() == "https" {
        return Ok(());
    }
    if scope == EndpointScope::PublicNetwork {
        return Err(WebRetrievalError::InvalidRequest(
            "public searxng instances require HTTPS".into(),
        ));
    }
    if scope != EndpointScope::Loopback
        && access_token.is_some_and(|value| !value.trim().is_empty())
    {
        return Err(WebRetrievalError::InvalidRequest(
            "searxng access tokens require HTTPS outside this device".into(),
        ));
    }
    Ok(())
}

fn endpoint_scope(url: &reqwest::Url) -> EndpointScope {
    let Some(host) = url.host_str() else {
        return EndpointScope::Invalid;
    };
    if let Ok(address) = IpAddr::from_str(host) {
        return match address {
            IpAddr::V4(address) if address.is_unspecified() => EndpointScope::Invalid,
            IpAddr::V4(address) if address.is_loopback() => EndpointScope::Loopback,
            IpAddr::V4(address)
                if address.is_private()
                    || address.is_link_local()
                    || matches!(address.octets(), [100, 64..=127, _, _]) =>
            {
                EndpointScope::PrivateNetwork
            }
            IpAddr::V6(address) if address.is_unspecified() => EndpointScope::Invalid,
            IpAddr::V6(address) if address.is_loopback() => EndpointScope::Loopback,
            IpAddr::V6(address) if address.is_unique_local() || address.is_unicast_link_local() => {
                EndpointScope::PrivateNetwork
            }
            _ => EndpointScope::PublicNetwork,
        };
    }
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if host == "localhost" || host.ends_with(".localhost") {
        return EndpointScope::Loopback;
    }
    if !host.contains('.')
        || [".local", ".localdomain", ".lan", ".internal", ".home.arpa"]
            .iter()
            .any(|suffix| host.ends_with(suffix))
    {
        return EndpointScope::PrivateNetwork;
    }
    EndpointScope::PublicNetwork
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
        endpoint: Option<&str>,
        options: SearchOptions,
    ) -> Result<Vec<SearchResult>> {
        let base = endpoint
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                WebRetrievalError::InvalidRequest("searxng: instance url required".into())
            })?
            .trim_end_matches('/');

        let request = self.search_request(base, query, secret)?;
        let resp = self.client.execute(request).await?;

        let status = resp.status();
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            let retry_after_secs = resp
                .headers()
                .get("retry-after")
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse::<u64>().ok());
            return Err(WebRetrievalError::RateLimit {
                provider: "searxng".into(),
                retry_after_secs,
            });
        }
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(WebRetrievalError::Auth(
                "searxng instance rejected the request".into(),
            ));
        }
        if status == reqwest::StatusCode::BAD_REQUEST {
            return Err(WebRetrievalError::InvalidRequest(
                "searxng rejected the search parameters".into(),
            ));
        }
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

#[cfg(test)]
mod tests {
    use reqwest::header::AUTHORIZATION;

    use super::*;

    #[test]
    fn adds_bearer_token_to_search_request() {
        let request = SearxngProvider::new()
            .search_request(
                "https://search.example.com",
                "rust mobile",
                Some(" access-token "),
            )
            .expect("search request");

        assert_eq!(
            request.headers().get(AUTHORIZATION).unwrap(),
            "Bearer access-token"
        );
        assert_eq!(
            request.url().as_str(),
            "https://search.example.com/search?q=rust%20mobile&format=json&pageno=1"
        );
    }

    #[test]
    fn leaves_public_instance_request_unauthenticated() {
        let request = SearxngProvider::new()
            .search_request("https://search.example.com", "rust", None)
            .expect("search request");

        assert!(request.headers().get(AUTHORIZATION).is_none());
    }

    #[test]
    fn rejects_cleartext_public_instances() {
        let error = SearxngProvider::new()
            .search_request("http://search.example.com", "rust", None)
            .expect_err("public HTTP must be rejected");

        assert!(matches!(error, WebRetrievalError::InvalidRequest(_)));
    }

    #[test]
    fn permits_cleartext_private_instances_without_credentials() {
        let request = SearxngProvider::new()
            .search_request("http://192.168.1.20:8080", "rust", None)
            .expect("private HTTP without credentials");

        assert_eq!(request.url().scheme(), "http");
    }

    #[test]
    fn rejects_credentials_over_cleartext_private_networks() {
        let error = SearxngProvider::new()
            .search_request("http://searxng.local", "rust", Some("token"))
            .expect_err("LAN credentials require HTTPS");

        assert!(matches!(error, WebRetrievalError::InvalidRequest(_)));
    }

    #[test]
    fn permits_credentials_over_cleartext_loopback() {
        let request = SearxngProvider::new()
            .search_request("http://127.0.0.1:8080", "rust", Some("token"))
            .expect("loopback credentials stay on device");

        assert_eq!(
            request.headers().get(AUTHORIZATION).unwrap(),
            "Bearer token"
        );
    }
}
