/// A single-tenant, local reverse proxy that lets the **web** build reach LLM
/// providers that don't send CORS headers (OpenAI, ChatGPT, Anthropic, …).
///
/// It's meant to run on the user's own machine, bundled in the same app
/// (`bin/serve.dart`), serving the Flutter web build from the same origin — so
/// from the browser's perspective there is no cross-origin request at all. The
/// proxy then makes the real provider call server-side, where CORS doesn't
/// exist.
///
/// The browser sends the real destination in the [upstreamHeader]; the proxy
/// forwards method, headers (minus hop-by-hop), and body, and **streams** the
/// response back untouched so SSE token deltas flow through in real time.
///
/// Safety: because it's a local relay, it only forwards to `https://` hosts on
/// an allowlist (plus `localhost`/loopback for Ollama/LM Studio). Pass
/// `allowedHosts: {'*'}` to disable the allowlist.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

/// Header carrying the real upstream URL (mirrors `LlmEndpoint.upstreamHeader`).
const String upstreamHeader = 'x-upstream-url';

/// Providers known to need a proxy on web. Extendable via [llmProxyHandler]'s
/// `allowedHosts` (or `LLM_ALLOWED_HOSTS` in `bin/serve.dart`).
const Set<String> defaultAllowedUpstreamHosts = <String>{
  'api.openai.com',
  'auth.openai.com',
  'chatgpt.com',
  'api.anthropic.com',
  'generativelanguage.googleapis.com',
  'openrouter.ai',
  'api.groq.com',
  'api.deepseek.com',
  'api.together.xyz',
  'api.mistral.ai',
  'dashscope.aliyuncs.com',
  // Used to resolve the current Codex CLI version for the version-gated
  // ChatGPT-subscription models endpoint.
  'registry.npmjs.org',
};

/// Hop-by-hop headers that must not be forwarded by a proxy (RFC 7230 §6.1),
/// plus length/encoding headers we let the server layer recompute.
const Set<String> _hopByHop = <String>{
  'host',
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'content-length',
};

/// Builds the reverse-proxy [Handler].
///
/// [prefix] is the path it serves (default `proxy`). Non-matching requests
/// return 404 so a [Cascade] can fall through to a static file handler.
Handler llmProxyHandler({
  http.Client? client,
  Set<String>? allowedHosts,
  String prefix = 'proxy',
  void Function(String message)? log,
}) {
  final http.Client httpClient = client ?? http.Client();
  final Set<String> allowed = allowedHosts ?? defaultAllowedUpstreamHosts;
  final bool allowAny = allowed.contains('*');
  final void Function(String) trace = log ?? (_) {};

  return (Request request) async {
    if (!_isProxyPath(request, prefix)) {
      return Response.notFound('Not a proxy path.');
    }

    final String origin = request.headers['origin'] ?? '*';
    final Map<String, String> cors = _corsHeaders(origin, request);

    // CORS preflight — answer it ourselves so the browser allows the POST.
    if (request.method == 'OPTIONS') {
      trace('preflight ${request.method} from $origin');
      return Response.ok(null, headers: cors);
    }

    final String? target = request.headers[upstreamHeader];
    if (target == null || target.isEmpty) {
      trace('400 missing $upstreamHeader header');
      return Response(
        400,
        body: 'Missing $upstreamHeader header.',
        headers: cors,
      );
    }
    final Uri? upstream = Uri.tryParse(target);
    if (upstream == null || !upstream.hasScheme || !upstream.hasAuthority) {
      trace('400 invalid upstream URL: $target');
      return Response(400, body: 'Invalid upstream URL.', headers: cors);
    }
    final bool local = _isLoopback(upstream.host);
    if (!(upstream.isScheme('https') || local)) {
      trace('400 non-https upstream: $upstream');
      return Response(
        400,
        body: 'Upstream must be https (or a local loopback host).',
        headers: cors,
      );
    }
    if (!allowAny && !local && !allowed.contains(upstream.host)) {
      trace('403 host not allowed: ${upstream.host}');
      return Response(
        403,
        body: 'Upstream host not allowed: ${upstream.host}',
        headers: cors,
      );
    }

    // Build the upstream request: copy through everything except hop-by-hop
    // headers, our control header, and the browser's Origin.
    final http.Request upstreamRequest = http.Request(request.method, upstream);
    request.headers.forEach((String key, String value) {
      final String lower = key.toLowerCase();
      // Drop the browser's accept-encoding so the underlying client negotiates
      // its own (gzip) and transparently decompresses. Forwarding it lets
      // Cloudflare reply with brotli, which Dart's client can't decode — the
      // body would reach the browser still-compressed (gibberish) because we
      // also strip content-encoding below.
      if (_hopByHop.contains(lower) ||
          lower == upstreamHeader ||
          lower == 'origin' ||
          lower == 'accept-encoding') {
        return;
      }
      upstreamRequest.headers[key] = value;
    });
    upstreamRequest.bodyBytes = await _collectBody(request);

    trace('--> ${request.method} ${upstream.host}${upstream.path}');
    final Stopwatch sw = Stopwatch()..start();
    final http.StreamedResponse upstreamResponse;
    try {
      upstreamResponse = await httpClient.send(upstreamRequest);
    } on Object catch (e) {
      trace(
        'xx  ${upstream.host}${upstream.path} failed after '
        '${sw.elapsedMilliseconds}ms: $e',
      );
      return Response(502, body: 'Upstream request failed: $e', headers: cors);
    }
    trace(
      '<-- ${upstreamResponse.statusCode} ${upstream.host}${upstream.path} '
      '(${sw.elapsedMilliseconds}ms)',
    );

    // Forward the response, streaming the body so SSE flows token-by-token.
    final Map<String, String> responseHeaders = <String, String>{};
    upstreamResponse.headers.forEach((String key, String value) {
      final String lower = key.toLowerCase();
      // Drop length/encoding so the server layer can chunk the stream itself.
      if (_hopByHop.contains(lower) || lower == 'content-encoding') return;
      responseHeaders[key] = value;
    });
    responseHeaders.addAll(cors);

    // On an error status, buffer the (small) body so we can log the real
    // upstream reason — otherwise a streamed error reaches the browser opaque
    // and we're left guessing why a 4xx happened.
    if (upstreamResponse.statusCode >= 400) {
      final Uint8List bytes = await upstreamResponse.stream.toBytes();
      final String text = utf8.decode(bytes, allowMalformed: true);
      trace('!!  ${upstreamResponse.statusCode} body: ${_truncate(text, 600)}');
      return Response(
        upstreamResponse.statusCode,
        body: bytes,
        headers: responseHeaders,
      );
    }

    return Response(
      upstreamResponse.statusCode,
      body: upstreamResponse.stream,
      headers: responseHeaders,
    );
  };
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}… (${s.length} bytes)';

bool _isProxyPath(Request request, String prefix) {
  final String path = request.url.path; // shelf paths have no leading slash
  return path == prefix || path.startsWith('$prefix/');
}

bool _isLoopback(String host) =>
    host == 'localhost' || host == '127.0.0.1' || host == '::1';

Future<Uint8List> _collectBody(Request request) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  await for (final List<int> chunk in request.read()) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Map<String, String> _corsHeaders(String origin, Request request) {
  // Reflect the browser's requested headers so provider-specific ones
  // (Authorization, anthropic-*, OAI-*, x-upstream-url) are always allowed.
  final String requested =
      request.headers['access-control-request-headers'] ??
      'authorization, content-type, accept, $upstreamHeader, '
          'anthropic-version, anthropic-dangerous-direct-browser-access, '
          'oai-client-version, oai-device-id, oai-language';
  return <String, String>{
    'access-control-allow-origin': origin,
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': requested,
    'access-control-max-age': '86400',
    'vary': 'origin',
  };
}
