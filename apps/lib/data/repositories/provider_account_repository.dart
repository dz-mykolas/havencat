import 'package:flutter/foundation.dart';

import '../../../domain/models/adapter_kind.dart';
import '../../../domain/models/provider_account.dart';
import '../../../domain/models/provider_definition.dart';
import '../services/auth/secret_store.dart';

/// Source of truth for configured [ProviderAccount]s and the "active" one.
///
/// This is the app-wide session state the Flutter architecture guide says
/// belongs in a repository: which provider the user has signed into, which is
/// currently selected, and the credentials backing each.
///
/// In-memory for now — structured so a drift-backed implementation can drop in
/// later by re-implementing the same surface against SQLite. Secrets never
/// touch this layer; they go through [SecretStore].
class ProviderAccountRepository extends ChangeNotifier {
  ProviderAccountRepository({required this._secretStore}) {
    // Seed a mock account so the app works out of the box with no config.
    _accounts.add(_seedMockAccount());
    _activeAccountId = _accounts.first.id;
  }

  final SecretStore _secretStore;
  final List<ProviderAccount> _accounts = <ProviderAccount>[];
  String? _activeAccountId;
  int _counter = 0;

  List<ProviderAccount> get accounts => List.unmodifiable(_accounts);

  ProviderAccount? get activeAccount =>
      _accounts.firstWhere((a) => a.id == _activeAccountId);

  String? get activeAccountId => _activeAccountId;

  /// All known provider definitions the user can add (subscription + API key).
  List<ProviderDefinition> get catalog => ProviderCatalog.all;

  /// Adds a new API-key-based account. The key is written to secure storage,
  /// the non-secret config stays in memory.
  Future<ProviderAccount> addApiKeyAccount({
    required String definitionId,
    required String displayName,
    required String apiKey,
    Map<String, Object?>? config,
  }) async {
    final ProviderDefinition def = ProviderCatalog.byId(definitionId)!;
    final String id = _newId();
    final ProviderAccount account = ProviderAccount(
      id: id,
      kind: def.kind,
      displayName: displayName,
      config: <String, Object?>{...def.configTemplate, ...?config},
      createdAt: DateTime.now(),
    );
    _accounts.add(account);
    await _secretStore.write(id, apiKey);
    _activeAccountId ??= id;
    notifyListeners();
    return account;
  }

  /// Adds a new subscription (OAuth) account. The OAuth access token is the
  /// "secret" stored in secure storage. Stub for now — the OAuth flow itself
  /// is implemented per-provider in a later phase.
  Future<ProviderAccount> addSubscriptionAccount({
    required String definitionId,
    required String displayName,
    required String accessToken,
    Map<String, Object?>? config,
  }) async {
    final ProviderDefinition def = ProviderCatalog.byId(definitionId)!;
    final String id = _newId();
    final ProviderAccount account = ProviderAccount(
      id: id,
      kind: def.kind,
      displayName: displayName,
      config: <String, Object?>{...def.configTemplate, ...?config},
      createdAt: DateTime.now(),
    );
    _accounts.add(account);
    await _secretStore.write(id, accessToken);
    _activeAccountId ??= id;
    notifyListeners();
    return account;
  }

  /// Adds a mock account (no secret needed). Used for development and as the
  /// default seed so the app is usable before any provider is configured.
  Future<ProviderAccount> addMockAccount({String displayName = 'Mock'}) async {
    final String id = _newId();
    final ProviderAccount account = ProviderAccount(
      id: id,
      kind: AdapterKind.mock,
      displayName: displayName,
      config: const <String, Object?>{},
      createdAt: DateTime.now(),
    );
    _accounts.add(account);
    _activeAccountId ??= id;
    notifyListeners();
    return account;
  }

  void setActive(String accountId) {
    if (_activeAccountId == accountId) return;
    _activeAccountId = accountId;
    notifyListeners();
  }

  Future<void> remove(String accountId) async {
    _accounts.removeWhere((a) => a.id == accountId);
    await _secretStore.delete(accountId);
    if (_activeAccountId == accountId) {
      _activeAccountId = _accounts.isEmpty ? null : _accounts.first.id;
    }
    notifyListeners();
  }

  String _newId() =>
      'acct_${DateTime.now().microsecondsSinceEpoch}_${_counter++}';

  ProviderAccount _seedMockAccount() {
    return ProviderAccount(
      id: 'acct_seed_mock',
      kind: AdapterKind.mock,
      displayName: 'Mock',
      config: const <String, Object?>{},
      createdAt: DateTime.now(),
    );
  }
}
