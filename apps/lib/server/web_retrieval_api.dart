import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../data/services/web_retrieval/rust_web_retrieval_adapter.dart';
import '../data/services/web_retrieval/web_retrieval.dart';

final Logger _log = Logger('web_retrieval');

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
    // CORS: the Flutter web app may be served from a different origin than
    // this API (e.g. dev server on :8080 → API on :8088). These routes use
    // simple GET/POST with safelisted headers, so no preflight is needed,
    // but the response must carry Access-Control-Allow-Origin. OPTIONS is
    // answered directly as a defensive measure — but only for our own
    // routes, so other handlers in the Cascade (e.g. conversations_api,
    // which allows PUT/DELETE) can answer their own preflights.
    final origin = request.headers['origin'];

    // Shelf serves request.url path relative to the handler's mount point.
    // This handler is mounted at the root, so paths arrive as
    // `api/search`, `api/fetch`, etc. Strip the leading `api/` segment.
    final path = request.url.path;
    final subPath = path.startsWith('api/') ? path.substring(4) : path;

    if (request.method == 'OPTIONS' && origin != null) {
      final isOurRoute =
          subPath == 'search' ||
          subPath == 'fetch' ||
          subPath.startsWith('cache/');
      if (!isOurRoute) {
        return Response.notFound('Not a web_retrieval route.');
      }
      return Response.ok(null, headers: _corsHeaders(origin));
    }

    try {
      final Response response;
      switch (subPath) {
        case 'search':
          response = await _handleSearch(adapter, request);
        case 'fetch':
          response = await _handleFetch(adapter, request);
        case 'cache/search':
          response = await _handleCacheSearch(adapter, request);
        case 'cache/cleanup':
          if (request.method != 'POST') {
            response = Response(405);
          } else {
            await adapter.cleanupCache();
            response = Response(204);
          }
        default:
          response = Response.notFound('unknown web_retrieval route: $path');
      }
      return _withCors(response, origin);
    } catch (e, st) {
      _log.severe('request failed: ${request.method} $path', e, st);
      return _withCors(
        Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: _jsonHeaders,
        ),
        origin,
      );
    }
  };
}

Map<String, String> _corsHeaders(String origin) => <String, String>{
  'access-control-allow-origin': origin,
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-max-age': '86400',
  'vary': 'origin',
};

/// Adds CORS headers to [response] when the request came from a browser
/// (i.e. carried an `origin` header). Returns [response] unchanged otherwise.
Response _withCors(Response response, String? origin) {
  if (origin == null) return response;
  return response.change(headers: _corsHeaders(origin));
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
  _log.fine('search: q="$query" num=$numResults');
  final results = await adapter.search(
    query,
    options: WebSearchOptions(numResults: numResults),
  );
  _log.info('search: q="$query" → ${results.length} results');
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
  _log.fine('fetch: url="$url" format=$formatName');
  final page = await adapter.fetch(url, format: format);
  _log.info(
    'fetch: url="$url" → ${page.content.length} chars '
    '(${page.contentType})',
  );
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
