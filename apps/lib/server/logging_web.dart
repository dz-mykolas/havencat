import 'dart:developer' as developer;

/// Web implementation: writes log lines to the browser console.
///
/// Log level is resolved by the caller (`AppConfig` → `initLogging(level:)`),
/// so this file only handles output routing.
void writeLogLine(String line, bool isWarningOrAbove) {
  developer.log(line, level: isWarningOrAbove ? 900 : 800);
}
