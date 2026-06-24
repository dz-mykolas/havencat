/// Single source of truth for the app's user-facing brand name.
///
/// Import [appName] instead of hardcoding the product name anywhere in the
/// UI, server logs, or tests.
///
/// Override at build time via `--dart-define=APP_NAME=...`.
const String appName = String.fromEnvironment('APP_NAME', defaultValue: 'HavenCat');
