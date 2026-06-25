//! FRB-exposed web retrieval API.
//!
//! These functions are surfaced to Flutter via flutter_rust_bridge. They hold
//! a process-global `SharedDb` (opened lazily on first use) and a set of
//! provider slots configured from Dart via `configure_web_retrieval`.

use std::sync::Arc;

use once_cell::sync::OnceCell;

use crate::web_retrieval::cache::Cache;
use crate::web_retrieval::db::{Db, SharedDb};
use crate::web_retrieval::error::{Result, WebRetrievalError};
use crate::web_retrieval::orchestrator::{
    fetch_all, search_all, FetchProviderSlot, SearchProviderSlot,
};
use crate::web_retrieval::provider::{
    FetchFormat, FetchOptions, FetchedPage, SearchOptions, SearchResult,
};
use crate::web_retrieval::providers::direct_http::DirectHttpProvider;
use crate::web_retrieval::providers::exa_mcp::ExaMcpProvider;
use crate::web_retrieval::providers::jina_reader::JinaReaderProvider;
use crate::web_retrieval::providers::searxng::SearxngProvider;

static DB: OnceCell<SharedDb> = OnceCell::new();
static SEARCH_SLOTS: OnceCell<Vec<SearchProviderSlot>> = OnceCell::new();
static FETCH_SLOTS: OnceCell<Vec<FetchProviderSlot>> = OnceCell::new();

/// Provider kind for configuration from Dart.
#[derive(Clone)]
pub struct ProviderConfig {
    pub kind: String,
    pub secret: Option<String>,
}

/// Initialize the web-retrieval subsystem: open the DB at `db_path`, run
/// migrations, and register the given search + fetch providers.
///
/// `db_path` of empty string opens an in-memory database.
#[flutter_rust_bridge::frb]
pub async fn configure_web_retrieval(
    db_path: String,
    search_providers: Vec<ProviderConfig>,
    fetch_providers: Vec<ProviderConfig>,
) -> Result<()> {
    let db = if db_path.is_empty() {
        Db::open_in_memory().await?
    } else {
        Db::open(&db_path).await?
    };
    db.configure_pragmas().await?;
    db.migrate().await?;

    let _ = DB.set(Arc::new(db));

    let search_slots: Vec<SearchProviderSlot> = search_providers
        .into_iter()
        .map(|c| build_search_slot(&c.kind, c.secret))
        .collect();
    let fetch_slots: Vec<FetchProviderSlot> = fetch_providers
        .into_iter()
        .map(|c| build_fetch_slot(&c.kind, c.secret))
        .collect();

    let _ = SEARCH_SLOTS.set(search_slots);
    let _ = FETCH_SLOTS.set(fetch_slots);
    Ok(())
}

/// Run a web search across all configured providers. Returns merged, deduped
/// results. Checks the cache first; caches per-provider results on miss.
#[flutter_rust_bridge::frb]
pub async fn web_search(query: String, num_results: u32) -> Result<Vec<SearchResult>> {
    let db = db()?;
    let cache = Cache::new(db.conn());
    let slots = search_slots()?;

    // Cache lookup is per-provider, so we fan out cache reads alongside live
    // calls. For simplicity here: if ALL providers have a fresh cache hit for
    // this query, return the merged cached set; otherwise query all live and
    // store per-provider.
    let mut cached_all: Vec<Vec<SearchResult>> = Vec::new();
    let mut missed: Vec<SearchProviderSlot> = Vec::new();
    for slot in slots.iter() {
        if let Some(results) = cache.get_search(&query, slot.provider.kind()).await? {
            cached_all.push(results);
        } else {
            missed.push(slot.clone());
        }
    }

    let options = SearchOptions {
        num_results: num_results as usize,
    };
    let live = if missed.is_empty() {
        Vec::new()
    } else {
        let results = search_all(missed.clone(), &query, options).await?;
        // Cache each provider's results. We re-run per-provider here would be
        // wasteful; instead, partition by `provider` field on each result.
        let mut by_provider: std::collections::HashMap<&str, Vec<SearchResult>> =
            std::collections::HashMap::new();
        for r in &results {
            by_provider
                .entry(r.provider.as_str())
                .or_default()
                .push(r.clone());
        }
        for (provider, results) in by_provider {
            cache.put_search(&query, provider, &results).await?;
        }
        results
    };

    let mut all = cached_all;
    all.push(live);
    Ok(crate::web_retrieval::merge::merge_results(all))
}

/// Fetch a single URL across all configured fetch providers. Returns the
/// first successful result. Checks the cache first.
#[flutter_rust_bridge::frb]
pub async fn url_fetch(url: String, format: String) -> Result<FetchedPage> {
    let db = db()?;
    let cache = Cache::new(db.conn());
    let slots = fetch_slots()?;

    if let Some(page) = cache.get_page(&url).await? {
        return Ok(page);
    }

    let fmt = match format.as_str() {
        "text" | "plain" => FetchFormat::Text,
        "html" => FetchFormat::Html,
        _ => FetchFormat::Markdown,
    };
    let options = FetchOptions { format: fmt };
    let page = fetch_all(slots.clone(), &url, options).await?;
    cache.put_page(&page).await?;
    Ok(page)
}

/// Full-text search across all cached pages (BM25 ranked).
#[flutter_rust_bridge::frb]
pub async fn web_cache_search_pages(query: String, limit: u32) -> Result<Vec<FetchedPage>> {
    let db = db()?;
    let cache = Cache::new(db.conn());
    cache.fts_search_pages(&query, limit as i64).await
}

/// Delete cache entries older than the TTL. Call periodically.
#[flutter_rust_bridge::frb]
pub async fn web_cache_cleanup() -> Result<()> {
    let db = db()?;
    let cache = Cache::new(db.conn());
    cache.cleanup().await
}

fn db() -> Result<&'static SharedDb> {
    DB.get().ok_or_else(|| {
        WebRetrievalError::Other(
            "web_retrieval not configured; call configure_web_retrieval first".into(),
        )
    })
}

fn search_slots() -> Result<&'static Vec<SearchProviderSlot>> {
    SEARCH_SLOTS
        .get()
        .ok_or_else(|| WebRetrievalError::Other("no search providers configured".into()))
}

fn fetch_slots() -> Result<&'static Vec<FetchProviderSlot>> {
    FETCH_SLOTS
        .get()
        .ok_or_else(|| WebRetrievalError::Other("no fetch providers configured".into()))
}

fn build_search_slot(kind: &str, secret: Option<String>) -> SearchProviderSlot {
    let provider: Arc<dyn crate::web_retrieval::provider::WebSearchProvider> = match kind {
        "exa" => Arc::new(ExaMcpProvider::new()),
        "searxng" => Arc::new(SearxngProvider::new()),
        _ => Arc::new(ExaMcpProvider::new()),
    };
    SearchProviderSlot { provider, secret }
}

fn build_fetch_slot(kind: &str, secret: Option<String>) -> FetchProviderSlot {
    let provider: Arc<dyn crate::web_retrieval::provider::UrlFetchProvider> = match kind {
        "exa" => Arc::new(ExaMcpProvider::new()),
        "jina_reader" => Arc::new(JinaReaderProvider::new()),
        "direct_http" => Arc::new(DirectHttpProvider::new()),
        _ => Arc::new(DirectHttpProvider::new()),
    };
    FetchProviderSlot { provider, secret }
}
