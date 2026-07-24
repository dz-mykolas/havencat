import 'package:logging/logging.dart';

import '../../../domain/errors/app_failure.dart';
import '../../../src/rust/api/web_retrieval.dart' as rust;
import '../../../src/rust/web_retrieval/provider.dart' as rust_types;
import 'web_retrieval.dart';
import 'web_retrieval_failure_mapper.dart';
import 'web_retrieval_provider_registry.dart';

/// Bridge adapter that delegates to the Rust web_retrieval module via FRB.
///
/// Call [configure] once at startup (e.g. from `main()`) before issuing any
/// search/fetch calls. The Rust side owns the SQLite cache + provider fan-out.
class RustWebRetrievalAdapter
    implements WebRetrievalAdapter, WebRetrievalConfigurator {
  RustWebRetrievalAdapter();

  static final Logger _log = Logger('web_retrieval.rust');
  static const WebRetrievalProviderRegistry _registry =
      WebRetrievalProviderRegistry();
  static const WebRetrievalFailureMapper _failureMapper =
      WebRetrievalFailureMapper();

  String _dbPath = '';

  /// Open the cache DB at [dbPath] (empty string = in-memory) and register
  /// the given search + fetch providers.
  Future<void> configure({
    required String dbPath,
    required List<ProviderSlotConfig> searchProviders,
    required List<ProviderSlotConfig> fetchProviders,
  }) async {
    _dbPath = dbPath;
    await configureProviders(
      searchProviders: searchProviders,
      fetchProviders: fetchProviders,
    );
  }

  @override
  Future<void> configureProviders({
    required List<ProviderSlotConfig> searchProviders,
    required List<ProviderSlotConfig> fetchProviders,
  }) async {
    final List<ProviderSlotConfig> resolvedSearch = _registry.normalizeSearch(
      searchProviders,
    );
    final List<ProviderSlotConfig> resolvedFetch = _registry.normalizeFetch(
      fetchProviders,
    );
    _log.info(
      'configure: dbPath="${_dbPath.isEmpty ? "<in-memory>" : _dbPath}" '
      'search=${resolvedSearch.map((p) => p.kind).join(',')} '
      'fetch=${resolvedFetch.map((p) => p.kind).join(',')}',
    );
    await rust.configureWebRetrieval(
      dbPath: _dbPath,
      searchProviders: resolvedSearch
          .map(
            (p) => rust.ProviderConfig(
              kind: p.kind,
              secret: p.secret,
              endpoint: p.endpoint,
            ),
          )
          .toList(),
      fetchProviders: resolvedFetch
          .map(
            (p) => rust.ProviderConfig(
              kind: p.kind,
              secret: p.secret,
              endpoint: p.endpoint,
            ),
          )
          .toList(),
    );
    _log.info('configure: done');
  }

  @override
  String get kind => 'rust';

  @override
  Future<WebSearchResponse> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  }) async {
    _log.fine('search: query="$query" num=${options.numResults}');
    try {
      final rust_types.SearchBatch batch = await rust.webSearch(
        query: query,
        numResults: options.numResults,
      );
      final List<WebSearchResult> results = batch.results.map(_toDart).toList();
      final List<WebProviderIssue> issues = batch.issues
          .map(
            (rust_types.ProviderIssue issue) => WebProviderIssue(
              provider: issue.provider,
              kind: issue.kind,
              retryAfter: issue.retryAfterSecs == null
                  ? null
                  : Duration(seconds: issue.retryAfterSecs!.toInt()),
            ),
          )
          .toList();
      _log.fine(
        'search: query="$query" → ${results.length} results, '
        '${issues.length} issue(s)',
      );
      return WebSearchResponse(
        results: results,
        issues: issues,
        successfulProviders: batch.successfulProviders,
      );
    } on Object catch (error) {
      throw _failureMapper.fromException(
        error,
        subsystem: AppSubsystem.webSearch,
        operation: 'search',
      );
    }
  }

  @override
  Future<FetchedPage> fetch(
    String url, {
    FetchFormat format = FetchFormat.markdown,
  }) async {
    _log.fine('fetch: url=$url format=${_formatName(format)}');
    try {
      final page = await rust.urlFetch(url: url, format: _formatName(format));
      _log.fine('fetch: url=$url → ${page.content.length} chars');
      return FetchedPage(
        url: page.url,
        title: page.title,
        content: page.content,
        contentType: page.contentType,
      );
    } on Object catch (error) {
      throw _failureMapper.fromException(
        error,
        subsystem: AppSubsystem.webFetch,
        operation: 'fetch',
      );
    }
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
          ? DateTime.fromMillisecondsSinceEpoch(r.publishedAt!.toInt() * 1000)
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
