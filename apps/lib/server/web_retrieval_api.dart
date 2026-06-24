import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../data/services/web_retrieval/rust_web_retrieval_adapter.dart';
import '../data/services/web_retrieval/web_retrieval.dart';

/// Shelf handler exposing the Rust-backed web retrieval as same-origin JSON
/// routes for the web build. The native (mobile/desktop) apps never use this —
/// they call [RustWebRetrievalAdapter] directly via FRB FFI.
///
/// Routes:
///   GET  /api/search?q=`<query>`&num=`<n>`     → JSON array of [WebSearchResult]
///   GET  /api/fetch?url=`<url>`&format=`<f>`  → JSON [FetchedPage]
///   GET  /api/cache/search?q=`<query>`&limit=`<n>` → JSON array of [FetchedPage]
///   POST /api/cache/cleanup                → empty 204
Handler webRetrievalApiHandler(RustWebRetrievalAdapter adapter) {
  return (Request request) async {
    final path = request.url.path;

    switch (path) {
      case 'search':
        return _handleSearch(adapter, request);
      case 'fetch':
        return _handleFetch(adapter, request);
      case 'cache/search':
        return _handleCacheSearch(adapter, request);
      case 'cache/cleanup':
        if (request.method != 'POST') {
          return Response(405);
        }
        await adapter.cleanupCache();
        return Response(204);
      default:
        return Response.notFound('unknown web_retrieval route: $path');
    }
  };
}

Response _badRequest(String message) =>
    Response(400, body: jsonEncode({'error': message}));

Response _jsonResponse(int status, Object body) =>
    Response(status, body: jsonEncode(body), headers: _jsonHeaders);

const Map<String, String> _jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};

Future<Response> _handleSearch(
  RustWebRetrievalAdapter adapter,
  Request request,
) async {
  if (request.method != 'GET') return Response(405);
  final query = request.url.queryParameters['q'];
  if (query == null || query.isEmpty) {
    return _badRequest('missing "q" query parameter');
  }
  final numResults =
      int.tryParse(request.url.queryParameters['num'] ?? '5') ?? 5;
  final results = await adapter.search(
    query,
    options: WebSearchOptions(numResults: numResults),
  );
  return _jsonResponse(200, results.map(_searchResultToJson).toList());
}

Future<Response> _handleFetch(
  RustWebRetrievalAdapter adapter,
  Request request,
) async {
  if (request.method != 'GET') return Response(405);
  final url = request.url.queryParameters['url'];
  if (url == null || url.isEmpty) {
    return _badRequest('missing "url" query parameter');
  }
  final formatName = request.url.queryParameters['format'] ?? 'markdown';
  final format = switch (formatName) {
    'text' || 'plain' => FetchFormat.text,
    'html' => FetchFormat.html,
    _ => FetchFormat.markdown,
  };
  final page = await adapter.fetch(url, format: format);
  return _jsonResponse(200, _fetchedPageToJson(page));
}

Future<Response> _handleCacheSearch(
  RustWebRetrievalAdapter adapter,
  Request request,
) async {
  if (request.method != 'GET') return Response(405);
  final query = request.url.queryParameters['q'];
  if (query == null || query.isEmpty) {
    return _badRequest('missing "q" query parameter');
  }
  final limit =
      int.tryParse(request.url.queryParameters['limit'] ?? '10') ?? 10;
  final pages = await adapter.cacheSearchPages(query, limit: limit);
  return _jsonResponse(200, pages.map(_fetchedPageToJson).toList());
}

Map<String, Object?> _searchResultToJson(WebSearchResult r) => {
  'title': r.title,
  'url': r.url,
  'snippet': r.snippet,
  'published_at': r.publishedAt?.millisecondsSinceEpoch,
  'provider': r.provider,
};

Map<String, Object?> _fetchedPageToJson(FetchedPage p) => {
  'url': p.url,
  'title': p.title,
  'content': p.content,
  'content_type': p.contentType,
};
