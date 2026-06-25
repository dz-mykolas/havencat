import 'dart:io';

/// Minimal `.env` file loader for the Dart server entrypoint.
///
/// Reads a file of `KEY=VALUE` lines (one per line) and returns them as a map.
/// Used by `app_config_native.dart`. Shell env vars win over `.env` values
/// (enforced in `app_config_native.dart`).
///
/// Rules:
///   - Lines starting with `#` are comments.
///   - Blank lines are ignored.
///   - Values may be quoted with `"..."` or `'...'`; surrounding quotes are
///     stripped.
///   - No variable interpolation, no `export` keyword, no multiline values —
///     this is intentionally tiny. Use a real dotenv package if you need more.
///
/// Example `.env`:
///   PORT=8088
///   LOG_LEVEL=debug
///   SEARCH_PROVIDERS=exa:your-key-here
Map<String, String> loadDotEnv([String path = '.env']) {
  final File f = File(path);
  if (!f.existsSync()) {
    // Not found — the Makefile exports vars from the root .env into the
    // shell environment, so Platform.environment already has them. This
    // file lookup only matters for direct `dart run bin/serve.dart` from
    // the repo root.
    return <String, String>{};
  }

  final Map<String, String> parsed = <String, String>{};
  for (final String rawLine in f.readAsLinesSync()) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    final int eq = line.indexOf('=');
    if (eq <= 0) continue;

    final String key = line.substring(0, eq).trim();
    String value = line.substring(eq + 1).trim();

    // Strip matching surrounding quotes.
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }

    parsed[key] = value;
  }
  return parsed;
}
