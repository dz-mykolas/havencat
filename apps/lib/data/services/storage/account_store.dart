import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../domain/models/provider_account.dart';

/// Persists the *non-secret* session state: which provider accounts exist and
/// which one is active. This is what was missing before — accounts lived only
/// in memory, so a browser refresh or app restart wiped them.
///
/// Secrets never touch this layer; API keys and OAuth token bundles go through
/// `SecretStore` (secure storage). Here we only store display + endpoint
/// metadata, which is safe to keep in `SharedPreferences` (backed by
/// `localStorage` on web, `NSUserDefaults`/`SharedPreferences` on native).
///
/// Falls back to an in-memory map when no [SharedPreferences] is injected
/// (e.g. widget tests) so the app still runs without the plugin.
class AccountStore {
  AccountStore({SharedPreferences? prefs})
    : _prefs = prefs,
      _fallback = prefs == null ? <String, String>{} : null;

  final SharedPreferences? _prefs;
  final Map<String, String>? _fallback;

  static const String _accountsKey = 'provider_accounts::v1';
  static const String _activeKey = 'active_account_id::v1';

  /// Whether an account list has ever been persisted for this installation.
  ///
  /// This distinguishes a fresh install from a valid, intentionally empty
  /// list after the user removes their final account.
  bool get hasStoredAccounts =>
      _prefs?.containsKey(_accountsKey) ?? _fallback!.containsKey(_accountsKey);

  /// Reads the persisted accounts. Returns null only on first run.
  List<ProviderAccount>? loadAccounts() {
    final String? raw = _getString(_accountsKey);
    if (raw == null) return null;
    if (raw.isEmpty) {
      throw const FormatException('Stored provider accounts are empty.');
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Stored provider accounts are not a list.');
    }
    return decoded
        .map((Object? value) {
          if (value is! Map) {
            throw const FormatException(
              'Stored provider account is not an object.',
            );
          }
          return ProviderAccount.fromJson(Map<String, Object?>.from(value));
        })
        .toList(growable: false);
  }

  String? loadActiveAccountId() => _getString(_activeKey);

  Future<void> saveAccounts(List<ProviderAccount> accounts) async {
    final String raw = jsonEncode(
      accounts.map((ProviderAccount a) => a.toJson()).toList(),
    );
    await _setString(_accountsKey, raw);
  }

  Future<void> saveActiveAccountId(String? id) async {
    if (id == null) {
      await _remove(_activeKey);
      return;
    }
    await _setString(_activeKey, id);
  }

  String? _getString(String key) {
    if (_prefs != null) return _prefs.getString(key);
    return _fallback![key];
  }

  Future<void> _setString(String key, String value) async {
    if (_prefs != null) {
      await _prefs.setString(key, value);
      return;
    }
    _fallback![key] = value;
  }

  Future<void> _remove(String key) async {
    if (_prefs != null) {
      await _prefs.remove(key);
      return;
    }
    _fallback!.remove(key);
  }
}
