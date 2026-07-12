import 'app_config.dart';

/// Web config loader: reads compile-time `--dart-define` values.
///
/// Flutter apps can't read shell env vars or files at runtime, so config is
/// baked in at build time via `--dart-define=KEY=VALUE`. The Makefile
/// forwards the relevant vars from `.env` as dart-defines.
AppConfig loadAppConfig() {
  return AppConfig(
    port: 0, // server-only; not used on web
    host: '', // server-only
    logLevel: const String.fromEnvironment('LOG_LEVEL', defaultValue: 'info'),
    rustLog: const String.fromEnvironment('RUST_LOG', defaultValue: 'info'),
    llmProxy: const String.fromEnvironment('LLM_PROXY', defaultValue: '/proxy'),
    appName: const String.fromEnvironment('APP_NAME', defaultValue: 'HavenCat'),
    codexClientVersion: const String.fromEnvironment(
      'CODEX_CLIENT_VERSION',
      defaultValue: '0.141.0',
    ),
  );
}
