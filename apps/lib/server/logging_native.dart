import 'dart:io' show stdout, stderr, IOSink;

/// Native (non-web) implementation: writes log lines to stdout/stderr.
///
/// Log level is resolved by the caller (`AppConfig` → `initLogging(level:)`),
/// so this file only handles output routing.
void writeLogLine(String line, bool isWarningOrAbove) {
  final IOSink sink = isWarningOrAbove ? stderr : stdout;
  sink.writeln(line);
}
