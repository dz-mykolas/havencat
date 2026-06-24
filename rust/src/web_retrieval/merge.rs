use std::collections::HashSet;

use super::provider::SearchResult;

/// Merge results from multiple providers, deduping by URL (case-insensitive).
/// Preserves order: first provider's results first, then new URLs from the
/// second provider, etc.
pub fn merge_results(mut all: Vec<Vec<SearchResult>>) -> Vec<SearchResult> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut merged: Vec<SearchResult> = Vec::new();
    for provider_results in all.drain(..) {
        for r in provider_results {
            let key = r.url.to_lowercase();
            if seen.insert(key) {
                merged.push(r);
            }
        }
    }
    merged
}
