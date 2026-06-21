import 'dart:io';

import 'package:havencat/branding.dart';
import 'package:havencat/server/llm_proxy.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

/// Self-host server: one lightweight Dart process that serves the
/// built Flutter web app **and** a same-origin LLM reverse proxy. This is the
/// whole "backend" for the web build — it ships inside the app, runs on the
/// user's own machine, and exists only so the browser can reach providers that
/// don't send CORS headers. Native (Android/iOS/desktop) builds don't use it.
///
/// Build the web app first, then run this:
///   flutter build web
///   dart run bin/serve.dart            # http://localhost:8088
///
/// Environment:
///   PORT                 listen port (default 8088)
///   HOST                 bind address (default 127.0.0.1 — local only)
///   WEB_ROOT             static files dir (default build/web)
///   LLM_ALLOWED_HOSTS    comma-separated upstream allowlist, or "*" for any
///
/// The web app must point at this proxy. Served from here it's same-origin, so
/// the default `--dart-define=LLM_PROXY=/proxy` just works. For a hot-reload
/// dev session, run this alongside `flutter run` and build with
/// `--dart-define=LLM_PROXY=http://localhost:8088/proxy`.
Future<void> main(List<String> args) async {
  final int port = int.parse(Platform.environment['PORT'] ?? '8088');
  final String host = Platform.environment['HOST'] ?? '127.0.0.1';
  final String webRoot = Platform.environment['WEB_ROOT'] ?? 'build/web';

  final String? allowedEnv = Platform.environment['LLM_ALLOWED_HOSTS'];
  final Set<String>? allowedHosts = allowedEnv
      ?.split(',')
      .map((String h) => h.trim())
      .where((String h) => h.isNotEmpty)
      .toSet();

  final Handler proxy = llmProxyHandler(
    allowedHosts: allowedHosts,
    log: (String message) => stdout.writeln('[proxy] $message'),
  );

  Handler handler;
  if (Directory(webRoot).existsSync()) {
    // Try the proxy first; fall through to static files for everything else.
    final Handler static = createStaticHandler(
      webRoot,
      defaultDocument: 'index.html',
    );
    // Only fall through to static files on 404 — NOT 405 (Cascade's other
    // default), so a genuine upstream 405 from the proxy isn't masked as a
    // static 404.
    handler = Cascade(
      statusCodes: const <int>{404},
    ).add(proxy).add(static).handler;
  } else {
    stderr.writeln(
      'WEB_ROOT "$webRoot" not found — serving the proxy only. '
      'Run `flutter build web` to serve the app too.',
    );
    handler = proxy;
  }

  final Handler pipeline = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(handler);

  final HttpServer server = await shelf_io.serve(pipeline, host, port);
  server.autoCompress = false; // don't buffer/compress streamed SSE responses

  final String allowList = allowedHosts == null
      ? '${defaultAllowedUpstreamHosts.length} default hosts'
      : (allowedHosts.contains('*')
            ? 'any host (allowlist disabled)'
            : allowedHosts.join(', '));
  stdout
    ..writeln('────────────────────────────────────────────────────────')
    ..writeln('$appName server ready')
    ..writeln('  url        http://$host:${server.port}')
    ..writeln('  llm proxy  http://$host:${server.port}/proxy')
    ..writeln('  web root   $webRoot')
    ..writeln('  allowlist  $allowList')
    ..writeln('  requests are logged below as they arrive')
    ..writeln('────────────────────────────────────────────────────────');
}
