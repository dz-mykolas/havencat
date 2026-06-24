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
    FetchOptions, FetchedPage, SearchOptions, SearchResult, UrlFetchProvider, WebSearchProvider,
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
) -> Result<Vec<SearchResult>> {
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
                    Ok(results) => (kind, Some(results)),
                    Err(e) => {
                        tracing::warn!(provider = kind, error = %e, "search provider failed");
                        (kind, None)
                    }
                }
            }
        })
        .collect();

    let outcomes = join_all(futures).await;
    let all_results: Vec<Vec<SearchResult>> = outcomes
        .iter()
        .filter_map(|(_, r)| r.clone())
        .collect();

    if all_results.is_empty() {
        let failed: Vec<&str> = outcomes.iter().map(|(k, _)| *k).collect();
        return Err(WebRetrievalError::AllProvidersFailed(format!(
            "all search providers failed: {}",
            failed.join(", ")
        )));
    }
    Ok(merge_results(all_results))
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
                        tracing::warn!(provider = kind, error = %e, "fetch provider failed");
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
        .ok_or_else(|| {
            WebRetrievalError::AllProvidersFailed("all fetch providers failed".into())
        })
}
