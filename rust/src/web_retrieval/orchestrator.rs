//! Multi-provider fan-out orchestration.
//!
//! Fires all enabled providers concurrently, collects successes, merges
//! results. No fallback chain — if a provider 429s, its results are simply
//! absent from the merged output.

use std::sync::Arc;

use futures_util::future::join_all;

use crate::web_retrieval::error::{Result, WebRetrievalError};
use crate::web_retrieval::merge::merge_results;
use crate::web_retrieval::provider::{
    FetchOptions, FetchedPage, ProviderIssue, SearchBatch, SearchOptions, UrlFetchProvider,
    WebSearchProvider,
};

/// A search provider paired with its optional secret (or config string).
#[derive(Clone)]
pub struct SearchProviderSlot {
    pub provider: Arc<dyn WebSearchProvider>,
    pub secret: Option<String>,
}

/// A fetch provider paired with its optional secret.
#[derive(Clone)]
pub struct FetchProviderSlot {
    pub provider: Arc<dyn UrlFetchProvider>,
    pub secret: Option<String>,
}

/// Fan out a search query across all enabled providers, merge results.
///
/// Errors from individual providers are logged (via tracing) and swallowed;
/// only an all-failed scenario surfaces as `AllProvidersFailed`.
pub async fn search_all(
    slots: Vec<SearchProviderSlot>,
    query: &str,
    options: SearchOptions,
) -> Result<SearchBatch> {
    if slots.is_empty() {
        return Err(WebRetrievalError::ProviderNotFound(
            "no search providers configured".into(),
        ));
    }

    let futures: Vec<_> = slots
        .into_iter()
        .map(|slot| {
            let options = options.clone();
            async move {
                let kind = slot.provider.kind();
                match slot
                    .provider
                    .search(query, slot.secret.as_deref(), options)
                    .await
                {
                    Ok(results) => (kind, Ok(results)),
                    Err(e) => {
                        tracing::warn!(
                            provider = kind,
                            query = query,
                            error = %e,
                            "search provider failed"
                        );
                        (kind, Err(e))
                    }
                }
            }
        })
        .collect();

    let outcomes = join_all(futures).await;
    let all_results = outcomes
        .iter()
        .filter_map(|(_, result)| result.as_ref().ok().cloned())
        .collect();
    let successful_providers = outcomes
        .iter()
        .filter_map(|(provider, result)| result.as_ref().ok().map(|_| provider.to_string()))
        .collect();
    let issues = outcomes
        .into_iter()
        .filter_map(|(provider, result)| {
            result.err().map(|error| ProviderIssue {
                provider: provider.to_string(),
                kind: error.kind().to_string(),
                retry_after_secs: error.retry_after_secs(),
            })
        })
        .collect();
    Ok(SearchBatch {
        results: merge_results(all_results),
        issues,
        successful_providers,
    })
}

/// Fan out a URL fetch across all enabled providers. Returns the first
/// successful result (providers are tried in priority order via join_all +
/// first-ok). Since join_all runs concurrently, we return whichever returns
/// first with a success.
pub async fn fetch_all(
    slots: Vec<FetchProviderSlot>,
    url: &str,
    options: FetchOptions,
) -> Result<FetchedPage> {
    if slots.is_empty() {
        return Err(WebRetrievalError::ProviderNotFound(
            "no fetch providers configured".into(),
        ));
    }

    let futures: Vec<_> = slots
        .into_iter()
        .map(|slot| {
            let options = options.clone();
            async move {
                let kind = slot.provider.kind();
                match slot
                    .provider
                    .fetch(url, slot.secret.as_deref(), options)
                    .await
                {
                    Ok(page) => Some(page),
                    Err(e) => {
                        tracing::warn!(
                            provider = kind,
                            url = url,
                            error = %e,
                            "fetch provider failed"
                        );
                        None
                    }
                }
            }
        })
        .collect();

    let outcomes = join_all(futures).await;
    outcomes
        .into_iter()
        .flatten()
        .next()
        .ok_or_else(|| WebRetrievalError::AllProvidersFailed("all fetch providers failed".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestProvider {
        kind: &'static str,
        fails: bool,
    }

    #[async_trait::async_trait]
    impl WebSearchProvider for TestProvider {
        fn kind(&self) -> &'static str {
            self.kind
        }

        async fn search(
            &self,
            _query: &str,
            _secret: Option<&str>,
            _options: SearchOptions,
        ) -> Result<Vec<crate::web_retrieval::provider::SearchResult>> {
            if self.fails {
                return Err(WebRetrievalError::RateLimit {
                    provider: self.kind.into(),
                    retry_after_secs: Some(30),
                });
            }
            Ok(Vec::new())
        }
    }

    #[tokio::test]
    async fn preserves_partial_failures_and_empty_successes() {
        let slots = vec![
            SearchProviderSlot {
                provider: Arc::new(TestProvider {
                    kind: "exa",
                    fails: false,
                }),
                secret: None,
            },
            SearchProviderSlot {
                provider: Arc::new(TestProvider {
                    kind: "brave",
                    fails: true,
                }),
                secret: None,
            },
        ];

        let batch = search_all(slots, "query", SearchOptions::default())
            .await
            .expect("search batch");

        assert!(batch.results.is_empty());
        assert_eq!(batch.successful_providers, vec!["exa"]);
        assert_eq!(batch.issues.len(), 1);
        assert_eq!(batch.issues[0].provider, "brave");
        assert_eq!(batch.issues[0].kind, "rate_limited");
        assert_eq!(batch.issues[0].retry_after_secs, Some(30));
    }
}
