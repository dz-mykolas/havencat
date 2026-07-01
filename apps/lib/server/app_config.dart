import '../data/services/web_retrieval/rust_web_retrieval_adapter.dart'
    show ProviderSlotConfig;

import 'app_config_native.dart'
    if (dart.library.html) 'app_config_web.dart'
    as platform;

/// Centralized, typed application configuration.
///
/// One schema for all config keys — defaults, types, and validation live here.
/// No more `Platform.environment['X'] ?? 'default'` scattered across files.
///
/// **Two runtimes, one class:**
///   * **Server** (`dart run bin/serve.dart`): reads `.env` file + shell env
///     vars (shell wins). See `app_config_native.dart`.
///   * **Flutter** (`flutter run`): reads compile-time `--dart-define` values
///     via `String.fromEnvironment`. See `app_config_web.dart`.
///
/// Config is read once at startup via [load] and passed around as a plain
/// object — no hot-reload, no service/provider indirection.
class AppConfig {
  const AppConfig({
    required this.port,
    required this.host,
    required this.webRoot,
    required this.logLevel,
    required this.rustLog,
    required this.searchProviders,
    required this.fetchProviders,
    required this.llmProxy,
    required this.appName,
    required this.codexClientVersion,
  });

  /// Loads config from the appropriate source for the current platform.
  factory AppConfig.load() => platform.loadAppConfig();

  /// Server listen port.
  final int port;

  /// Server bind address.
  final String host;

  /// Static files dir served by the server.
  final String webRoot;

  /// Dart log level name: debug/info/warning/severe/etc.
  final String logLevel;

  /// Rust tracing filter (e.g. `info,app_rust=debug`).
  final String rustLog;

  /// Search provider specs (e.g. `[ProviderSlotConfig(kind: 'exa')]`).
  final List<ProviderSlotConfig> searchProviders;

  /// Fetch provider specs.
  final List<ProviderSlotConfig> fetchProviders;

  /// LLM proxy base URL for browser requests (web only; native calls
  /// upstream directly). Default `/proxy` = same-origin.
  final String llmProxy;

  /// App brand name.
  final String appName;

  /// Codex protocol client version fallback.
  final String codexClientVersion;
}

/// Parses a comma-separated provider spec like
/// `searxng:https://searx.be,exa:KEY` into [ProviderSlotConfig]s.
List<ProviderSlotConfig> parseProviderSpec(String spec) {
  return spec.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).map((
    s,
  ) {
    final colon = s.indexOf(':');
    if (colon == -1) {
      return ProviderSlotConfig(kind: s);
    }
    return ProviderSlotConfig(
      kind: s.substring(0, colon),
      secret: s.substring(colon + 1),
    );
  }).toList();
}
