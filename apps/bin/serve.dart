import 'dart:io';

import 'package:app/branding.dart';
import 'package:app/data/services/storage/conversation_store.dart';
import 'package:app/data/services/web_retrieval/rust_web_retrieval_adapter.dart';
import 'package:app/server/app_config.dart';
import 'package:app/server/conversations_api.dart';
import 'package:app/server/logging.dart';
import 'package:app/server/llm_proxy.dart';
import 'package:app/server/web_retrieval_api.dart';
import 'package:app/src/rust/api/conversations.dart' as rust_conversations;
import 'package:app/src/rust/frb_generated.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

final Logger _log = Logger('server');

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
/// Environment (any of these may also be set in a `.env` file at the repo
/// root; real shell env vars win over `.env`):
///   PORT                 listen port (default 8088)
///   HOST                 bind address (default 127.0.0.1 — local only)
///   WEB_ROOT             static files dir (default build/web)
///   LOG_LEVEL            Dart log level: debug/info/warning/severe (default info)
///   RUST_LOG              Rust tracing filter: debug/trace/web_retrieval=trace
///                         (default info)
///   SEARCH_PROVIDERS     comma-separated search providers (default exa)
///                         e.g. searxng:https://searx.be,exa:EXA_KEY
///   FETCH_PROVIDERS      comma-separated fetch providers (default direct_http,jina_reader)
///                         e.g. direct_http,jina_reader:JINA_KEY
///
/// The web app must point at this proxy. Served from here it's same-origin, so
/// the default `--dart-define=LLM_PROXY=/proxy` just works. For a hot-reload
/// dev session, run this alongside `flutter run` and build with
/// `--dart-define=LLM_PROXY=http://localhost:8088/proxy`.
Future<void> main(List<String> args) async {
  final AppConfig config = AppConfig.load();

  initLogging(level: config.logLevel);

  final int port = config.port;
  final String host = config.host;
  final String webRoot = config.webRoot;

  final Logger proxyLog = Logger('proxy');
  final Handler proxy = llmProxyHandler(
    log: (String message) => proxyLog.info(message),
  );

  // Initialize the Rust web_retrieval subsystem (SQLite cache + provider
  // fan-out). The server is the only path for the web build to reach Rust;
  // native apps call the adapter directly via FRB FFI.
  await RustLib.init();
  final RustWebRetrievalAdapter webRetrieval = RustWebRetrievalAdapter();

  await webRetrieval.configure(
    dbPath: '', // in-memory; TODO: persist to a file next to the server
    searchProviders: config.searchProviders,
    fetchProviders: config.fetchProviders,
  );
  final Handler webRetrievalApi = webRetrievalApiHandler(webRetrieval);

  // Initialize the conversations SQLite database (server-side, for web).
  // Native apps call configureConversations directly via FRB FFI.
  // Resolve relative to the script location (apps/bin → repo root) so the
  // DB lives at the repo root regardless of the working directory.
  final String repoRoot = File.fromUri(
    Uri.parse(Platform.script.toString()),
  ).parent.parent.parent.path;
  await rust_conversations.configureConversations(
    dbPath: '$repoRoot/conversations.db',
  );
  final Handler conversationsApi = conversationsApiHandler(
    RustConversationStore(),
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
    ).add(proxy).add(webRetrievalApi).add(conversationsApi).add(static).handler;
  } else {
    _log.warning(
      'WEB_ROOT "$webRoot" not found — serving the proxy only. '
      'Run `flutter build web` to serve the app too.',
    );
    handler = Cascade(
      statusCodes: const <int>{404},
    ).add(proxy).add(webRetrievalApi).add(conversationsApi).handler;
  }

  final Handler pipeline = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(handler);

  final HttpServer server = await shelf_io.serve(pipeline, host, port);
  server.autoCompress = false; // don't buffer/compress streamed SSE responses

  _log
    ..info('────────────────────────────────────────────────────────')
    ..info('$appName server ready')
    ..info('  url        http://$host:${server.port}')
    ..info('  llm proxy  http://$host:${server.port}/proxy')
    ..info('  web api    http://$host:${server.port}/api/search|fetch|cache')
    ..info('  web root   $webRoot')
    ..info('  ssrf       deny-list (private/link-local/metadata blocked)')
    ..info('  log level  ${Logger.root.level.name}')
    ..info('  requests are logged below as they arrive')
    ..info('────────────────────────────────────────────────────────');
}
