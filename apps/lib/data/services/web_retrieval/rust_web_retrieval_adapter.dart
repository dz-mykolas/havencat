import '../../../src/rust/api/web_retrieval.dart' as rust;
import '../../../src/rust/web_retrieval/provider.dart' as rust_types;
import 'web_retrieval.dart';

/// Configuration for a single provider slot, passed to [RustWebRetrievalAdapter.configure].
class ProviderSlotConfig {
  final String kind;
  final String? secret;

  const ProviderSlotConfig({required this.kind, this.secret});
}

/// Bridge adapter that delegates to the Rust web_retrieval module via FRB.
///
/// Call [configure] once at startup (e.g. from `main()`) before issuing any
/// search/fetch calls. The Rust side owns the SQLite cache + provider fan-out.
class RustWebRetrievalAdapter implements WebRetrievalAdapter {
  RustWebRetrievalAdapter();

  bool _configured = false;

  /// Open the cache DB at [dbPath] (empty string = in-memory) and register
  /// the given search + fetch providers. Idempotent — subsequent calls are
  /// no-ops after the first success.
  Future<void> configure({
    required String dbPath,
    required List<ProviderSlotConfig> searchProviders,
    required List<ProviderSlotConfig> fetchProviders,
  }) async {
    if (_configured) return;
    await rust.configureWebRetrieval(
      dbPath: dbPath,
      searchProviders: searchProviders
          .map((p) => rust.ProviderConfig(kind: p.kind, secret: p.secret))
          .toList(),
      fetchProviders: fetchProviders
          .map((p) => rust.ProviderConfig(kind: p.kind, secret: p.secret))
          .toList(),
    );
    _configured = true;
  }

  @override
  String get kind => 'rust';

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  }) async {
    final results = await rust.webSearch(
      query: query,
      numResults: options.numResults,
    );
    return results.map(_toDart).toList();
  }

  @override
  Future<FetchedPage> fetch(
    String url, {
    FetchFormat format = FetchFormat.markdown,
  }) async {
    final page = await rust.urlFetch(url: url, format: _formatName(format));
    return FetchedPage(
      url: page.url,
      title: page.title,
      content: page.content,
      contentType: page.contentType,
    );
  }

  /// Full-text search across all cached pages (BM25 ranked).
  Future<List<FetchedPage>> cacheSearchPages(
    String query, {
    int limit = 10,
  }) async {
    final pages = await rust.webCacheSearchPages(query: query, limit: limit);
    return pages
        .map(
          (p) => FetchedPage(
            url: p.url,
            title: p.title,
            content: p.content,
            contentType: p.contentType,
          ),
        )
        .toList();
  }

  /// Delete cache entries older than the TTL. Call periodically.
  Future<void> cleanupCache() => rust.webCacheCleanup();

  static WebSearchResult _toDart(rust_types.SearchResult r) {
    return WebSearchResult(
      title: r.title,
      url: r.url,
      snippet: r.snippet,
      publishedAt: r.publishedAt != null
          ? DateTime.fromMillisecondsSinceEpoch(
              r.publishedAt!.toInt() * 1000,
            )
          : null,
      provider: r.provider,
    );
  }

  static String _formatName(FetchFormat f) {
    switch (f) {
      case FetchFormat.markdown:
        return 'markdown';
      case FetchFormat.text:
        return 'text';
      case FetchFormat.html:
        return 'html';
    }
  }
}
