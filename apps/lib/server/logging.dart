import 'package:logging/logging.dart';

import 'logging_native.dart'
    if (dart.library.html) 'logging_web.dart'
    as platform;

/// Initializes the Dart `logging` package with a hierarchical logger that
/// writes structured records to stdout/stderr (native) or `print` (web).
///
/// This is the standard Dart logging convention: `logging` is the de-facto
/// logging package (already a transitive dependency via `shelf`), and a single
/// root-level listener captures all log records — including shelf's built-in
/// `logRequests()` middleware, which logs to `Logger('shelf')`.
///
/// Level is controlled by the `LOG_LEVEL` env var (e.g. `LOG_LEVEL=debug`,
/// `LOG_LEVEL=warning`), loaded via `AppConfig`. Defaults to `Level.INFO`.
///
/// Output format:
///   `2026-06-24T19:15:11.947  INFO  shelf  GET [200] /api/search 12ms`
///   `2026-06-24T19:15:11.947  WARN  web_retrieval  search provider failed ...`
///
/// WARNING/SEVERE records go to stderr; everything else to stdout. This
/// follows the Unix convention so that `2>` can capture just errors.
/// On web, all output goes through `print` (browser console).
void initLogging({String? level}) {
  final String levelStr = (level ?? 'info').toLowerCase();

  final Level logLevel = switch (levelStr) {
    'all' => Level.ALL,
    'debug' => Level.FINE,
    'fine' => Level.FINE,
    'info' => Level.INFO,
    'warning' => Level.WARNING,
    'warn' => Level.WARNING,
    'error' => Level.SEVERE,
    'severe' => Level.SEVERE,
    'off' => Level.OFF,
    _ => Level.INFO,
  };

  Logger.root.level = logLevel;

  Logger.root.onRecord.listen((LogRecord record) {
    final String timestamp = record.time.toIso8601String().substring(0, 23);

    final String levelName = record.level.name.padRight(5);

    final String loggerName = record.loggerName;

    final StringBuffer buf = StringBuffer()
      ..write(timestamp)
      ..write('  ')
      ..write(levelName)
      ..write('  ')
      ..write(loggerName);

    if (record.message.isNotEmpty) {
      buf.write('  ');
      buf.write(record.message);
    }

    if (record.error != null) {
      buf.write('  ');
      buf.write(record.error);
    }

    if (record.stackTrace != null && record.level >= Level.SEVERE) {
      buf.write('\n');
      buf.write(record.stackTrace);
    }

    platform.writeLogLine(buf.toString(), record.level >= Level.WARNING);
  });
}

/// Convenience for obtaining a logger named after the calling module.
Logger logger(String name) => Logger(name);
