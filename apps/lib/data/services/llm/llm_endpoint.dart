import 'package:flutter/foundation.dart' show kIsWeb;

/// Decides where an adapter actually sends its HTTP request.
///
/// The problem this solves: in a **browser** the same-origin policy (CORS)
/// blocks direct calls to `api.openai.com` / `chatgpt.com`, which don't send
/// `Access-Control-Allow-Origin`. On **native** (Android/iOS/desktop) there is
/// no browser and no CORS, so the call goes straight to the provider.
///
/// So:
///   * native → talk to the upstream URL directly (zero overhead).
///   * web    → talk to our own bundled Shelf proxy (same-origin, so no CORS),
///              carrying the real destination in the `X-Upstream-Url` header.
///              The proxy makes the actual provider call server-side.
///
/// The proxy base is compile-time configurable via
/// `--dart-define=LLM_PROXY=...`. The default `/proxy` is same-origin, which is
/// what you get when the app is served by `bin/serve.dart`. For a hot-reload
/// dev workflow (Flutter dev server on one port, proxy on another) pass an
/// absolute URL, e.g. `--dart-define=LLM_PROXY=http://localhost:8088/proxy`.
class LlmEndpoint {
  const LlmEndpoint({this.proxyBase});

  /// Where browser requests are routed. Null means "call upstream directly"
  /// (the native case).
  final String? proxyBase;

  /// Picks the right behavior for the current platform.
  factory LlmEndpoint.fromPlatform() {
    if (kIsWeb) return const LlmEndpoint(proxyBase: _envProxyBase);
    return const LlmEndpoint();
  }

  static const String _envProxyBase = String.fromEnvironment(
    'LLM_PROXY',
    defaultValue: '/proxy',
  );

  bool get usesProxy => proxyBase != null && proxyBase!.isNotEmpty;

  /// Header the proxy reads to learn the real destination.
  static const String upstreamHeader = 'X-Upstream-Url';

  /// Rewrites a request so it goes directly to [upstreamUrl] (native) or via
  /// the proxy with the destination in [upstreamHeader] (web).
  ResolvedRequest resolve(String upstreamUrl, Map<String, String> headers) {
    if (!usesProxy) {
      return ResolvedRequest(url: upstreamUrl, headers: headers);
    }
    return ResolvedRequest(
      url: proxyBase!,
      headers: <String, String>{...headers, upstreamHeader: upstreamUrl},
    );
  }
}

/// The concrete URL + headers an adapter should send after [LlmEndpoint] has
/// decided between direct and proxied transport.
class ResolvedRequest {
  const ResolvedRequest({required this.url, required this.headers});

  final String url;
  final Map<String, String> headers;
}
