import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wraps `flutter_secure_storage` so the rest of the app doesn't depend on it
/// directly. Stores API keys and OAuth token bundles under caller-owned ids.
///
/// Backends, in order of preference:
///   * native (iOS/macOS/Android/Windows/Linux) — the OS keystore (Keychain,
///     Keystore/EncryptedSharedPreferences, DPAPI, libsecret). Genuinely
///     secure at rest.
///   * web — `flutter_secure_storage`'s WebCrypto + `localStorage` backend.
///     This is the best available without a backend, but note the encryption
///     key also lives in `localStorage`, so it is not a defense against XSS.
///     Keep this in mind for a fully client-side app.
///   * tests / unsupported — an in-memory map so the app still runs.
class SecretStore {
  SecretStore({FlutterSecureStorage? storage})
    : _storage = storage,
      _fallback = storage == null ? <String, String>{} : null;

  /// Builds a [SecretStore] backed by platform secure storage with sensible
  /// per-platform hardening. Call this from `main()`.
  factory SecretStore.secure() {
    return SecretStore(
      storage: const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
        mOptions: MacOsOptions(
          accessibility: KeychainAccessibility.first_unlock,
        ),
      ),
    );
  }

  final FlutterSecureStorage? _storage;
  final Map<String, String>? _fallback;

  Future<String?> read(String id) async {
    if (_storage != null) {
      return _storage.read(key: _key(id));
    }
    return _fallback![_key(id)];
  }

  Future<void> write(String id, String secret) async {
    if (_storage != null) {
      await _storage.write(key: _key(id), value: secret);
      return;
    }
    _fallback![_key(id)] = secret;
  }

  Future<void> delete(String id) async {
    if (_storage != null) {
      await _storage.delete(key: _key(id));
      return;
    }
    _fallback!.remove(_key(id));
  }

  Future<void> deleteAll() async {
    if (_storage != null) {
      await _storage.deleteAll();
      return;
    }
    _fallback!.clear();
  }

  static String _key(String id) => 'llm_secret::$id';
}
