import 'dart:io';

import 'package:app/branding.dart';
import 'package:app/data/services/storage/conversation_store.dart';
import 'package:app/data/services/web_retrieval/rust_web_retrieval_adapter.dart';
import 'package:app/data/services/web_retrieval/web_retrieval.dart';
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

final Logger _log = Logger('server');

/// Local API server for the Flutter web development app. It provides the LLM
/// reverse proxy and Rust-backed web retrieval/conversation APIs that browsers
/// cannot access directly. Native (Android/iOS/desktop) builds don't use it.
///
/// Environment (any of these may also be set in a `.env` file at the repo
/// root; real shell env vars win over `.env`):
///   PORT                 listen port (default 8088)
///   HOST                 bind address (default 127.0.0.1 — local only)
///   LOG_LEVEL            Dart log level: debug/info/warning/severe (default info)
///   RUST_LOG              Rust tracing filter: debug/trace/web_retrieval=trace
///                         (default info)
///
/// Run this alongside `flutter run` and point the web app at it with
/// `--dart-define=LLM_PROXY=http://localhost:8088/proxy`.
Future<void> main() async {
  final AppConfig config = AppConfig.load();

  initLogging(level: config.logLevel);

  final int port = config.port;
  final String host = config.host;

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
    searchProviders: const <ProviderSlotConfig>[
      ProviderSlotConfig(kind: 'exa'),
    ],
    fetchProviders: const <ProviderSlotConfig>[
      ProviderSlotConfig(kind: 'direct_http'),
      ProviderSlotConfig(kind: 'jina_reader'),
    ],
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

  final Handler handler = Cascade(
    statusCodes: const <int>{404},
  ).add(proxy).add(webRetrievalApi).add(conversationsApi).handler;

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
    ..info('  ssrf       deny-list (private/link-local/metadata blocked)')
    ..info('  log level  ${Logger.root.level.name}')
    ..info('  requests are logged below as they arrive')
    ..info('────────────────────────────────────────────────────────');
}
