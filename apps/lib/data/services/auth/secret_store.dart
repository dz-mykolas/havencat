import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wraps `flutter_secure_storage` so the rest of the app doesn't depend on it
/// directly. Stores API keys and OAuth tokens keyed by provider account id.
///
/// On platforms where secure storage isn't available (e.g. desktop tests),
/// falls back to an in-memory map so the app still runs.
class SecretStore {
  SecretStore({FlutterSecureStorage? storage})
    : _storage = storage,
      _fallback = storage == null ? <String, String>{} : null;

  final FlutterSecureStorage? _storage;
  final Map<String, String>? _fallback;

  Future<String?> read(String accountId) async {
    if (_storage != null) {
      return _storage.read(key: _key(accountId));
    }
    return _fallback![_key(accountId)];
  }

  Future<void> write(String accountId, String secret) async {
    if (_storage != null) {
      await _storage.write(key: _key(accountId), value: secret);
      return;
    }
    _fallback![_key(accountId)] = secret;
  }

  Future<void> delete(String accountId) async {
    if (_storage != null) {
      await _storage.delete(key: _key(accountId));
      return;
    }
    _fallback!.remove(_key(accountId));
  }

  static String _key(String accountId) => 'llm_secret::$accountId';
}

/// Riverpod-friendly: expose a single [SecretStore] for the whole app.
final SecretStore secretStore = SecretStore();
