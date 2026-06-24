use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tokio_rusqlite::params;

use super::error::{Result, WebRetrievalError};
use super::provider::{FetchedPage, SearchResult};

/// Default cache TTL: 15 minutes. Overridable via the
/// `HAVENCAT_WEB_CACHE_TTL_SECS` env var (hidden from the UI for now).
pub const DEFAULT_TTL_SECS: u64 = 15 * 60;

pub fn ttl_secs() -> u64 {
    std::env::var("HAVENCAT_WEB_CACHE_TTL_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|_| true)
        .unwrap_or(DEFAULT_TTL_SECS)
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Cached search results, serialized as JSON for storage.
#[derive(Serialize, Deserialize)]
pub struct CachedSearch {
    pub results: Vec<SearchResult>,
}

/// The cache layer. Owns a clone of the DB connection handle.
#[derive(Clone)]
pub struct Cache {
    conn: tokio_rusqlite::Connection,
}

impl Cache {
    pub fn new(conn: tokio_rusqlite::Connection) -> Self {
        Self { conn }
    }

    /// Look up a cached search for `(query, provider)` if fresh within TTL.
    pub async fn get_search(
        &self,
        query: &str,
        provider: &str,
    ) -> Result<Option<Vec<SearchResult>>> {
        let query = query.to_lowercase();
        let provider = provider.to_string();
        let cutoff = now_secs() - ttl_secs() as i64;

        let row = self
            .conn
            .call(move |c| {
                let mut stmt = c.prepare(
                    "SELECT results_json FROM web_searches
                     WHERE query = ?1 AND provider = ?2 AND searched_at > ?3",
                )?;
                let mut rows = stmt.query(params![query, provider, cutoff])?;
                match rows.next()? {
                    Some(r) => Ok(Some(r.get::<_, String>(0)?)),
                    None => Ok(None),
                }
            })
            .await?;

        match row {
            None => Ok(None),
            Some(json) => {
                let cached: CachedSearch = serde_json::from_str(&json)?;
                Ok(Some(cached.results))
            }
        }
    }

    /// Store search results for `(query, provider)`.
    pub async fn put_search(
        &self,
        query: &str,
        provider: &str,
        results: &[SearchResult],
    ) -> Result<()> {
        let query = query.to_lowercase();
        let provider = provider.to_string();
        let json = serde_json::to_string(&CachedSearch {
            results: results.to_vec(),
        })?;
        let now = now_secs();

        self.conn
            .call(move |c| {
                c.execute(
                    "INSERT OR REPLACE INTO web_searches
                     (query, provider, results_json, searched_at)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![query, provider, json, now],
                )?;
                Ok(())
            })
            .await?;
        Ok(())
    }

    /// Look up a cached page for `url` if fresh within TTL.
    pub async fn get_page(&self, url: &str) -> Result<Option<FetchedPage>> {
        let url = url.to_string();
        let cutoff = now_secs() - ttl_secs() as i64;

        let row = self
            .conn
            .call(move |c| {
                let mut stmt = c.prepare(
                    "SELECT url, title, content, content_type, fetched_at
                     FROM web_pages WHERE url = ?1 AND fetched_at > ?2",
                )?;
                let mut rows = stmt.query(params![url, cutoff])?;
                if let Some(r) = rows.next()? {
                    Ok(Some(FetchedPage {
                        url: r.get::<_, String>(0)?,
                        title: r.get::<_, String>(1)?,
                        content: r.get::<_, String>(2)?,
                        content_type: r.get::<_, String>(3)?,
                    }))
                } else {
                    Ok(None)
                }
            })
            .await?;

        Ok(row)
    }

    /// Store a fetched page.
    pub async fn put_page(&self, page: &FetchedPage) -> Result<()> {
        let url = page.url.clone();
        let title = page.title.clone();
        let content = page.content.clone();
        let content_type = page.content_type.clone();
        let now = now_secs();

        self.conn
            .call(move |c| {
                c.execute(
                    "INSERT OR REPLACE INTO web_pages
                     (url, title, content, content_type, fetched_at)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![url, title, content, content_type, now],
                )?;
                Ok(())
            })
            .await?;
        Ok(())
    }

    /// Full-text search across all cached pages. Returns matching pages
    /// ordered by bm25 relevance (best first).
    pub async fn fts_search_pages(&self, query: &str, limit: i64) -> Result<Vec<FetchedPage>> {
        let query = query.to_string();
        self.conn
            .call(move |c| {
                let mut stmt = c.prepare(
                    "SELECT p.url, p.title, p.content, p.content_type
                     FROM web_pages_fts f
                     JOIN web_pages p ON p.rowid = f.rowid
                     WHERE web_pages_fts MATCH ?1
                     ORDER BY rank
                     LIMIT ?2",
                )?;
                let rows = stmt.query_map(params![query, limit], |r| {
                    Ok(FetchedPage {
                        url: r.get::<_, String>(0)?,
                        title: r.get::<_, String>(1)?,
                        content: r.get::<_, String>(2)?,
                        content_type: r.get::<_, String>(3)?,
                    })
                })?;
                rows.collect::<tokio_rusqlite::rusqlite::Result<Vec<_>>>()
            })
            .await
            .map_err(WebRetrievalError::from)
    }

    /// Full-text search across cached search results.
    pub async fn fts_search_searches(
        &self,
        query: &str,
        limit: i64,
    ) -> Result<Vec<(String, String, Vec<SearchResult>)>> {
        let query = query.to_string();
        self.conn
            .call(move |c| {
                let mut stmt = c.prepare(
                    "SELECT s.query, s.provider, s.results_json
                     FROM web_searches_fts f
                     JOIN web_searches s ON s.rowid = f.rowid
                     WHERE web_searches_fts MATCH ?1
                     ORDER BY rank
                     LIMIT ?2",
                )?;
                let rows = stmt.query_map(params![query, limit], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                })?;
                rows.collect::<tokio_rusqlite::rusqlite::Result<Vec<_>>>()
            })
            .await
            .map_err(WebRetrievalError::from)
            .and_then(|rows| {
                rows.into_iter()
                    .map(|(q, p, json)| {
                        let cached: CachedSearch = serde_json::from_str(&json)?;
                        Ok((q, p, cached.results))
                    })
                    .collect()
            })
    }

    /// Delete cache entries older than the TTL. Run periodically.
    pub async fn cleanup(&self) -> Result<()> {
        let cutoff = now_secs() - ttl_secs() as i64;
        self.conn
            .call(move |c| {
                c.execute("DELETE FROM web_pages WHERE fetched_at < ?1", params![cutoff])?;
                c.execute(
                    "DELETE FROM web_searches WHERE searched_at < ?1",
                    params![cutoff],
                )?;
                Ok(())
            })
            .await?;
        Ok(())
    }
}
