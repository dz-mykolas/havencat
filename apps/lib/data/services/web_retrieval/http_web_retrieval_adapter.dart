import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../../domain/errors/app_failure.dart';
import 'web_retrieval.dart';
import 'web_retrieval_failure_mapper.dart';

/// Web-only adapter that calls the local server's `/api/*` JSON routes instead
/// of Rust via FRB FFI. The server (run via `dart run bin/serve.dart`) hosts
/// the same [RustWebRetrievalAdapter] and serializes its results to JSON.
///
/// On native (mobile/desktop), the Riverpod provider returns a
/// [RustWebRetrievalAdapter] instead — this class is never used there.
class HttpWebRetrievalAdapter
    implements WebRetrievalAdapter, WebRetrievalConfigurator {
  HttpWebRetrievalAdapter({String? baseUrl, http.Client? client})
    : _baseUrl = (baseUrl ?? '').replaceAll(RegExp(r'/+$'), ''),
      _client = client ?? http.Client();

  static final Logger _log = Logger('web_retrieval.http');

  final String _baseUrl;
  final http.Client _client;
  static const WebRetrievalFailureMapper _failureMapper =
      WebRetrievalFailureMapper();

  /// Base URL of the local server. Defaults to same-origin (empty string),
  /// which works because the server serves both the web UI and the API.
  String get baseUrl => _baseUrl;

  @override
  Future<void> configureProviders({
    required List<ProviderSlotConfig> searchProviders,
    required List<ProviderSlotConfig> fetchProviders,
  }) async {
    final http.Response response = await _client.post(
      Uri.parse('$_baseUrl/api/retrieval/configure'),
      headers: const <String, String>{
        'accept': 'application/json',
        'content-type': 'application/json',
      },
      body: jsonEncode(<String, Object?>{
        'search_providers': searchProviders.map(_providerConfigToJson).toList(),
        'fetch_providers': fetchProviders.map(_providerConfigToJson).toList(),
      }),
    );
    if (response.statusCode != 204) {
      throw _failureMapper.fromHttp(
        status: response.statusCode,
        body: response.body,
        subsystem: AppSubsystem.webSearch,
        operation: 'configure',
      );
    }
  }

  @override
  String get kind => 'http';

  @override
  Future<WebSearchResponse> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  }) async {
    final uri = Uri.parse('$_baseUrl/api/search').replace(
      queryParameters: {'q': query, 'num': options.numResults.toString()},
    );
    _log.fine('search: GET $uri');
    final resp = await _client.get(uri, headers: _acceptJson);
    if (resp.statusCode != 200) {
      _log.warning(
        'search failed: ${resp.statusCode} body=${resp.body.substring(0, resp.body.length.clamp(0, 200))}',
      );
      throw _failureMapper.fromHttp(
        status: resp.statusCode,
        body: resp.body,
        subsystem: AppSubsystem.webSearch,
        operation: 'search',
      );
    }
    final Object? decoded = jsonDecode(resp.body);
    final List<dynamic> json = decoded is List
        ? decoded
        : (decoded as Map<String, dynamic>)['results'] as List<dynamic>? ??
              const <dynamic>[];
    final List<WebSearchResult> results = json
        .cast<Map<String, dynamic>>()
        .map(_searchResultFromJson)
        .toList();
    final List<WebProviderIssue> issues = decoded is Map<String, dynamic>
        ? ((decoded['issues'] as List<dynamic>?) ?? const <dynamic>[])
              .cast<Map<String, dynamic>>()
              .map(_providerIssueFromJson)
              .toList()
        : const <WebProviderIssue>[];
    final List<String> successfulProviders = decoded is Map<String, dynamic>
        ? ((decoded['successful_providers'] as List<dynamic>?) ??
                  const <dynamic>[])
              .whereType<String>()
              .toList()
        : results
              .map((WebSearchResult result) => result.provider)
              .toSet()
              .toList();
    _log.fine('search: query="$query" → ${results.length} results');
    return WebSearchResponse(
      results: results,
      issues: issues,
      successfulProviders: successfulProviders,
    );
  }

  @override
  Future<FetchedPage> fetch(
    String url, {
    FetchFormat format = FetchFormat.markdown,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/api/fetch',
    ).replace(queryParameters: {'url': url, 'format': _formatName(format)});
    _log.fine('fetch: GET $uri');
    final resp = await _client.get(uri, headers: _acceptJson);
    if (resp.statusCode != 200) {
      _log.warning(
        'fetch failed: ${resp.statusCode} url=$url body=${resp.body.substring(0, resp.body.length.clamp(0, 200))}',
      );
      throw _failureMapper.fromHttp(
        status: resp.statusCode,
        body: resp.body,
        subsystem: AppSubsystem.webFetch,
        operation: 'fetch',
      );
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final page = _fetchedPageFromJson(json);
    _log.fine('fetch: url=$url → ${page.content.length} chars');
    return page;
  }

  /// Full-text search across cached pages (BM25 ranked).
  Future<List<FetchedPage>> cacheSearchPages(
    String query, {
    int limit = 10,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/api/cache/search',
    ).replace(queryParameters: {'q': query, 'limit': limit.toString()});
    final resp = await _client.get(uri, headers: _acceptJson);
    if (resp.statusCode != 200) {
      throw _failureMapper.fromHttp(
        status: resp.statusCode,
        body: resp.body,
        subsystem: AppSubsystem.storage,
        operation: 'search_web_cache',
      );
    }
    final List<dynamic> json = jsonDecode(resp.body) as List<dynamic>;
    return json.cast<Map<String, dynamic>>().map(_fetchedPageFromJson).toList();
  }

  /// Delete cache entries older than the TTL.
  Future<void> cleanupCache() async {
    final resp = await _client.post(
      Uri.parse('$_baseUrl/api/cache/cleanup'),
      headers: _acceptJson,
    );
    if (resp.statusCode != 204) {
      throw _failureMapper.fromHttp(
        status: resp.statusCode,
        body: resp.body,
        subsystem: AppSubsystem.storage,
        operation: 'clean_web_cache',
      );
    }
  }

  static const Map<String, String> _acceptJson = {'accept': 'application/json'};

  static String _formatName(FetchFormat f) => switch (f) {
    FetchFormat.markdown => 'markdown',
    FetchFormat.text => 'text',
    FetchFormat.html => 'html',
  };

  static WebSearchResult _searchResultFromJson(Map<String, dynamic> json) {
    final publishedAt = json['published_at'] as int?;
    return WebSearchResult(
      title: json['title'] as String? ?? '',
      url: json['url'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
      publishedAt: publishedAt != null
          ? DateTime.fromMillisecondsSinceEpoch(publishedAt)
          : null,
      provider: json['provider'] as String? ?? '',
    );
  }

  static WebProviderIssue _providerIssueFromJson(Map<String, dynamic> json) {
    final int? retryAfterSeconds = (json['retry_after_seconds'] as num?)
        ?.toInt();
    return WebProviderIssue(
      provider: json['provider'] as String? ?? '',
      kind: json['kind'] as String? ?? 'unknown',
      retryAfter: retryAfterSeconds == null
          ? null
          : Duration(seconds: retryAfterSeconds),
    );
  }

  static Map<String, Object?> _providerConfigToJson(
    ProviderSlotConfig config,
  ) => <String, Object?>{
    'kind': config.kind,
    if (config.secret != null) 'secret': config.secret,
    if (config.endpoint != null) 'endpoint': config.endpoint,
  };

  static FetchedPage _fetchedPageFromJson(Map<String, dynamic> json) {
    return FetchedPage(
      url: json['url'] as String? ?? '',
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      contentType: json['content_type'] as String? ?? '',
    );
  }
}
