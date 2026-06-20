import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../domain/models/adapter_kind.dart';
import '../../../domain/models/oauth_tokens.dart';
import '../../../domain/models/provider_account.dart';
import '../../../domain/models/provider_definition.dart';
import '../services/auth/secret_store.dart';
import '../services/storage/account_store.dart';

/// Source of truth for configured [ProviderAccount]s and the "active" one.
///
/// This is the app-wide session state: which providers the user has signed
/// into, which is currently selected, and the credentials backing each.
///
/// Persistence model (fully local, no backend):
///   * Non-secret metadata (the account list + active id) is mirrored to
///     [AccountStore] on every mutation and restored by [load] on startup.
///     This is what makes a login survive a restart / browser refresh.
///   * Secrets (API keys, OAuth token bundles) go to [SecretStore]
///     (secure storage), keyed by the account's stable id — never here.
class ProviderAccountRepository extends ChangeNotifier {
  ProviderAccountRepository({
    required this._accountStore,
    required this._secretStore,
  }) {
    _seedDefault();
  }

  final AccountStore _accountStore;
  final SecretStore _secretStore;
  final List<ProviderAccount> _accounts = <ProviderAccount>[];
  String? _activeAccountId;
  bool _loaded = false;

  static const Uuid _uuid = Uuid();

  /// True once [load] has reconciled in-memory state with persisted state.
  bool get isLoaded => _loaded;

  List<ProviderAccount> get accounts => List.unmodifiable(_accounts);

  ProviderAccount? get activeAccount {
    if (_activeAccountId == null) return null;
    for (final ProviderAccount a in _accounts) {
      if (a.id == _activeAccountId) return a;
    }
    return _accounts.isEmpty ? null : _accounts.first;
  }

  String? get activeAccountId => _activeAccountId;

  /// All known provider definitions the user can add (subscription + API key).
  List<ProviderDefinition> get catalog => ProviderCatalog.all;

  /// Restores persisted accounts + active id. Call once on startup before the
  /// first frame. If nothing is persisted yet (first run), the seeded mock
  /// account is persisted so its id stays stable across launches.
  Future<void> load() async {
    final List<ProviderAccount> persisted = _accountStore.loadAccounts();
    if (persisted.isEmpty) {
      await _persist();
      _loaded = true;
      return;
    }
    _accounts
      ..clear()
      ..addAll(persisted);
    final String? storedActive = _accountStore.loadActiveAccountId();
    _activeAccountId =
        (storedActive != null && _accounts.any((a) => a.id == storedActive))
        ? storedActive
        : _accounts.first.id;
    _loaded = true;
    notifyListeners();
  }

  /// Adds a new API-key-based account. The key is written to secure storage,
  /// the non-secret config is persisted via [AccountStore].
  Future<ProviderAccount> addApiKeyAccount({
    required String definitionId,
    required String displayName,
    required String apiKey,
    Map<String, Object?>? config,
  }) async {
    final ProviderDefinition def = ProviderCatalog.byId(definitionId)!;
    final ProviderAccount account = _newAccount(def, displayName, config);
    await _secretStore.write(account.id, apiKey);
    _accounts.add(account);
    _activeAccountId ??= account.id;
    await _persist();
    notifyListeners();
    return account;
  }

  /// Adds a new subscription (OAuth) account. The full [tokens] bundle (access
  /// token + rotating refresh token + expiry) is written to secure storage;
  /// only non-secret display metadata (plan type, account id) lives in config.
  Future<ProviderAccount> addSubscriptionAccount({
    required String definitionId,
    required String displayName,
    required OAuthTokens tokens,
    Map<String, Object?>? config,
  }) async {
    final ProviderDefinition def = ProviderCatalog.byId(definitionId)!;
    final ProviderAccount account = _newAccount(def, displayName, config);
    await _secretStore.write(account.id, tokens.encode());
    _accounts.add(account);
    _activeAccountId ??= account.id;
    await _persist();
    notifyListeners();
    return account;
  }

  /// Adds a mock account (no secret needed). Used for development and as the
  /// default seed so the app is usable before any provider is configured.
  Future<ProviderAccount> addMockAccount({String displayName = 'Mock'}) async {
    final ProviderAccount account = ProviderAccount(
      id: 'acct_${_uuid.v4()}',
      kind: AdapterKind.mock,
      displayName: displayName,
      config: const <String, Object?>{},
      createdAt: DateTime.now(),
    );
    _accounts.add(account);
    _activeAccountId ??= account.id;
    await _persist();
    notifyListeners();
    return account;
  }

  Future<void> setActive(String accountId) async {
    if (_activeAccountId == accountId) return;
    _activeAccountId = accountId;
    notifyListeners();
    await _persist();
  }

  /// Sets the selected model for [accountId] (stored in non-secret config) and
  /// persists it so it survives a restart.
  Future<void> setModel(String accountId, String modelId) async {
    final int index = _accounts.indexWhere((a) => a.id == accountId);
    if (index == -1) return;
    final ProviderAccount current = _accounts[index];
    if (current.config['model'] == modelId) return;
    _accounts[index] = ProviderAccount(
      id: current.id,
      kind: current.kind,
      displayName: current.displayName,
      config: <String, Object?>{...current.config, 'model': modelId},
      createdAt: current.createdAt,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String accountId) async {
    _accounts.removeWhere((a) => a.id == accountId);
    await _secretStore.delete(accountId);
    if (_activeAccountId == accountId) {
      _activeAccountId = _accounts.isEmpty ? null : _accounts.first.id;
    }
    await _persist();
    notifyListeners();
  }

  ProviderAccount _newAccount(
    ProviderDefinition def,
    String displayName,
    Map<String, Object?>? config,
  ) {
    return ProviderAccount(
      id: 'acct_${_uuid.v4()}',
      kind: def.kind,
      displayName: displayName,
      config: <String, Object?>{...def.configTemplate, ...?config},
      createdAt: DateTime.now(),
    );
  }

  void _seedDefault() {
    _accounts.add(
      ProviderAccount(
        id: 'acct_seed_mock',
        kind: AdapterKind.mock,
        displayName: 'Mock',
        config: const <String, Object?>{},
        createdAt: DateTime.now(),
      ),
    );
    _activeAccountId = _accounts.first.id;
  }

  Future<void> _persist() async {
    await _accountStore.saveAccounts(_accounts);
    await _accountStore.saveActiveAccountId(_activeAccountId);
  }
}
