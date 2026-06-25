/// Web implementation: writes log lines via `print` (browser console).
///
/// Log level is resolved by the caller (`AppConfig` → `initLogging(level:)`),
/// so this file only handles output routing.
void writeLogLine(String line, bool isWarningOrAbove) {
  // On web, `print` goes to the browser console.
  print(line);
}
