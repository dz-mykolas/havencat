import 'dart:io';

import 'app_config.dart';
import 'env.dart';

/// Native (non-web) config loader: reads `.env` file + shell env vars.
///
/// Shell env vars win over `.env` values, so one-off overrides like
/// `PORT=9000 make server` still work.
AppConfig loadAppConfig() {
  final Map<String, String> dotenv = loadDotEnv();

  // Shell env wins over .env; empty strings are treated as unset.
  String read(String key, String defaultValue) {
    final String? v = Platform.environment[key] ?? dotenv[key];
    return (v == null || v.isEmpty) ? defaultValue : v;
  }

  final int port = int.parse(read('PORT', '8088'));
  final String host = read('HOST', '127.0.0.1');
  final String logLevel = read('LOG_LEVEL', 'info');
  final String rustLog = read('RUST_LOG', 'info');
  final String llmProxy = read('LLM_PROXY', '/proxy');
  final String appName = read('APP_NAME', 'HavenCat');
  final String codexClientVersion = read('CODEX_CLIENT_VERSION', '0.141.0');

  return AppConfig(
    port: port,
    host: host,
    logLevel: logLevel,
    rustLog: rustLog,
    llmProxy: llmProxy,
    appName: appName,
    codexClientVersion: codexClientVersion,
  );
}
