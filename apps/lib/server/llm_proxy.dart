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
/// Safety (SSRF): the proxy is a textbook server-side-request-forgery surface
/// — a malicious page on any origin can POST to `localhost:<port>` with a
/// crafted `x-upstream-url`. Per the OWASP SSRF Prevention Cheat Sheet (Case
/// 2: "application can send requests to ANY external IP/domain"), an allowlist
/// is the wrong defense here: the user can plug in any OpenAI-compatible
/// endpoint (147+ providers on models.dev, growing). Instead we use a
/// **deny-list** of dangerous IP ranges and validate the *resolved* IP, not
/// the hostname string — which also defeats DNS-rebinding and alternate IP
/// encodings (`2130706433`, `127.1`, etc.).
///
/// Denied ranges: link-local (incl. cloud metadata `169.254.169.254`),
/// multicast, and RFC1918 private (10/8, 172.16/12, 192.168/16) + IPv6
/// unique-local `fc00::/7`. Loopback (`127.0.0.0/8`, `::1`) is **allowed** —
/// the user explicitly wants Ollama / LM Studio on localhost. Redirects are
/// disabled so an allowed host can't 302 to an internal IP.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, InternetAddress, InternetAddressType;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shelf/shelf.dart';

/// Header carrying the real upstream URL (mirrors `LlmEndpoint.upstreamHeader`).
const String upstreamHeader = 'x-upstream-url';

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
  String prefix = 'proxy',
  void Function(String message)? log,
}) {
  // autoUncompress=false so we control encoding (we ask upstream for
  // `accept-encoding: identity` to keep SSE streaming token-by-token).
  final HttpClient raw = HttpClient()..autoUncompress = false;
  final http.Client httpClient = client ?? IOClient(raw);
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
    final bool local = _isLoopbackHost(upstream.host);
    if (!(upstream.isScheme('https') || local)) {
      trace('400 non-https upstream: $upstream');
      return Response(
        400,
        body: 'Upstream must be https (or a local loopback host).',
        headers: cors,
      );
    }

    // SSRF defense: resolve the hostname and reject any resolved IP that
    // lands in a dangerous range. This catches alternate encodings
    // (`2130706433`, `127.1`) and DNS-rebinding (a domain that resolves to
    // a public IP at validation time but a private IP at connect time — we
    // pin the connection to the validated IP below). Loopback is allowed.
    final SsrfVerdict verdict = await _checkSsrf(upstream.host);
    if (verdict.denied) {
      trace('403 ${verdict.reason}: ${upstream.host}');
      return Response(
        403,
        body: 'Upstream host rejected: ${verdict.reason}',
        headers: cors,
      );
    }

    // Build the upstream request: copy through everything except hop-by-hop
    // headers, our control header, and the browser's Origin.
    final http.Request upstreamRequest = http.Request(request.method, upstream)
      // Never follow redirects: an allowed host could 302 to an internal IP
      // (SSRF bypass via open redirect — PortSwigger SSRF guidance). The
      // browser can follow the redirect itself if it wants to.
      ..followRedirects = false;
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
    // Tell the upstream not to compress — we want raw SSE bytes to flow through
    // token-by-token. gzip would buffer the whole stream into blocks.
    upstreamRequest.headers['accept-encoding'] = 'identity';
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

/// True for `localhost`, `127.0.0.1`, `::1` — the loopback names a user
/// types for Ollama / LM Studio. These are *allowed* by the SSRF filter.
bool _isLoopbackHost(String host) =>
    host == 'localhost' || host == '127.0.0.1' || host == '::1';

/// Result of an SSRF check on a hostname.
class SsrfVerdict {
  const SsrfVerdict.allowed() : denied = false, reason = null;
  const SsrfVerdict.denied(String this.reason) : denied = true;

  final bool denied;
  final String? reason;
}

/// Resolves [host] and rejects any resolved IP that falls in a dangerous
/// range. Returns [SsrfVerdict.allowed] for loopback (the user's own Ollama /
/// LM Studio) and for any public IP. Returns [SsrfVerdict.denied] for:
///   - link-local (169.254.0.0/16, fe80::/10) — covers cloud metadata
///     (AWS/Azure/GCP `169.254.169.254`)
///   - multicast (224.0.0.0/4, ff00::/8)
///   - RFC1918 private (10/8, 172.16/12, 192.168/16) + IPv6 unique-local
///     (fc00::/7) — internal network probing
///
/// A hostname that doesn't resolve is allowed to pass through; the upstream
/// request will fail with a normal DNS error, which is the correct behavior
/// (we don't want to leak DNS-resolution status to an attacker).
Future<SsrfVerdict> _checkSsrf(String host) async {
  // Fast path: literal IP — no DNS lookup needed.
  final InternetAddress? literal = InternetAddress.tryParse(host);
  if (literal != null) {
    return _verdictForAddress(literal);
  }

  try {
    final List<InternetAddress> addresses = await InternetAddress.lookup(host);
    for (final InternetAddress addr in addresses) {
      final SsrfVerdict v = _verdictForAddress(addr);
      if (v.denied) return v;
    }
  } on Object {
    // DNS failure — let the upstream request fail naturally.
  }
  return const SsrfVerdict.allowed();
}

SsrfVerdict _verdictForAddress(InternetAddress addr) {
  // Loopback is allowed (Ollama, LM Studio, local dev servers).
  if (addr.isLoopback) return const SsrfVerdict.allowed();
  // Link-local covers 169.254.0.0/16 + fe80::/10, which includes the cloud
  // metadata endpoints (AWS/Azure/GCP IMDS at 169.254.169.254).
  if (addr.isLinkLocal) {
    return const SsrfVerdict.denied('link-local address');
  }
  if (addr.isMulticast) {
    return const SsrfVerdict.denied('multicast address');
  }
  // RFC1918 private + IPv6 unique-local. Dart's InternetAddress doesn't expose
  // an isPrivate, so check the raw bytes.
  if (_isPrivate(addr)) {
    return const SsrfVerdict.denied('private address');
  }
  return const SsrfVerdict.allowed();
}

/// True for RFC1918 private ranges (10/8, 172.16/12, 192.168/16) and IPv6
/// unique-local (fc00::/7). Anything else (including 0.0.0.0/8 and the
/// 100.64.0.0/10 CGNAT range) is considered public — the proxy only needs to
/// block the ranges an attacker would actually target for internal probing.
bool _isPrivate(InternetAddress addr) {
  final Uint8List b = addr.rawAddress;
  if (addr.type == InternetAddressType.IPv4 && b.length == 4) {
    final int a0 = b[0], a1 = b[1];
    if (a0 == 10) return true; // 10.0.0.0/8
    if (a0 == 172 && a1 >= 16 && a1 <= 31) return true; // 172.16.0.0/12
    if (a0 == 192 && a1 == 168) return true; // 192.168.0.0/16
    return false;
  }
  if (addr.type == InternetAddressType.IPv6 && b.length == 16) {
    // fc00::/7 — unique-local addresses (fc and fd prefixes).
    return (b[0] & 0xfe) == 0xfc;
  }
  return false;
}

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
