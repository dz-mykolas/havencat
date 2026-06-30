import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../domain/models/llm_model.dart';
import '../../../domain/models/provider_account.dart';
import '../../repositories/provider_account_repository.dart';
import '../auth/credential_resolver.dart';
import 'adapter_registry.dart';
import 'llm_adapter.dart';

/// Caches the models each configured [ProviderAccount] exposes, fetched from
/// the provider's own "list models" endpoint.
///
/// This mirrors [ModelsDevService] for the catalog: a startup pre-warm fetches
/// models for every account so the chat header's model picker is populated
/// before the user opens a conversation, and a per-account fetch runs whenever
/// a new account is added. Results are cached to `SharedPreferences` (keyed by
/// account id) so they survive a restart and are available offline.
///
/// The chat's [ModelSelectorViewModel] reads from this cache instead of
/// fetching on every screen entry — the same pattern the Discover panel uses
/// for the models.dev catalog.
class AccountModelsService extends ChangeNotifier {
  AccountModelsService({
    this._prefs,
    required this._providers,
    required this._adapters,
    required this._credentials,
  }) {
    _providers.addListener(_onAccountsChanged);
  }

  final SharedPreferences? _prefs;
  final ProviderAccountRepository _providers;
  final AdapterRegistry _adapters;
  final CredentialResolver _credentials;

  /// accountId -> cached models. Empty list = fetched but provider returned
  /// nothing (the account should be greyed out as non-selectable). Absent
  /// key = not yet fetched (still loading).
  final Map<String, List<LlmModel>> _cache = <String, List<LlmModel>>{};

  /// accountId -> last fetch error (null on success or before first fetch).
  final Map<String, Object> _errors = <String, Object>{};

  /// accountId -> in-flight fetch guard, so concurrent calls coalesce.
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  /// accountId -> model ids the user has already acknowledged (seen in the
  /// Manage sheet or the chat picker). Drives the "+N new" badge: a model is
  /// "new" when it's in `available` but not in `enabled` and not in `seen`.
  final Map<String, Set<String>> _seen = <String, Set<String>>{};

  static const String _keyPrefix = 'account_models::v1';
  static const String _errorPrefix = 'account_models_err::v1';
  static const String _seenPrefix = 'account_models_seen::v1';

  /// The cached models for [accountId], or null if not yet fetched.
  List<LlmModel>? modelsFor(String accountId) => _cache[accountId];

  /// The last fetch error for [accountId], or null if none.
  Object? errorFor(String accountId) => _errors[accountId];

  /// Whether a fetch is currently running for [accountId].
  bool isLoading(String accountId) => _inFlight.containsKey(accountId);

  /// The set of model ids the user has acknowledged for [accountId]. Drives
  /// the "+N new" delta in the chat picker — a model is "new" when it's
  /// available but neither enabled nor seen. Mutated via [markSeen].
  Set<String> seenFor(String accountId) =>
      _seen.putIfAbsent(accountId, () => <String>{});

  /// Seeds the cache for [accountId] with [models] without a network call.
  /// Test-only helper for deterministic view-model tests.
  @visibleForTesting
  void seedForTest(String accountId, List<LlmModel> models) {
    _cache[accountId] = models;
    _errors.remove(accountId);
    notifyListeners();
  }

  /// Pre-warms the cache for every configured account. Fire-and-forget on
  /// startup — failures are swallowed here and surfaced lazily via
  /// [errorFor] when the chat header reads the cache.
  Future<void> warmAll() async {
    final List<ProviderAccount> accounts = _providers.accounts;
    await Future.wait(
      accounts.map((ProviderAccount a) => _fetch(a, silent: true)),
    );
  }

  /// Fetches models for [accountId] from the provider and updates the cache.
  /// Safe to call repeatedly — concurrent calls for the same account coalesce
  /// into one network request. Re-throws on failure so callers (e.g. the chat
  /// header's retry button) can react.
  Future<void> refresh(String accountId) async {
    final ProviderAccount? account = _lookup(accountId);
    if (account == null) return;
    await _fetch(account, silent: false);
  }

  Future<void> _fetch(ProviderAccount account, {required bool silent}) async {
    final String id = account.id;
    // Coalesce concurrent fetches for the same account.
    final Future<void>? existing = _inFlight[id];
    if (existing != null) return existing;

    final Completer<void> completer = Completer<void>();
    _inFlight[id] = completer.future;
    notifyListeners();

    try {
      final LlmAdapter adapter = _adapters.resolve(account.kind);
      final String? secret = await _credentials.resolve(account);
      final List<LlmModel> models = await adapter.listModels(
        account: account,
        secret: secret,
      );
      _cache[id] = models;
      _errors.remove(id);
      await _persist(id, models);
      // Seed the "seen" set on first successful fetch so a freshly-connected
      // account doesn't immediately flag every model as new. Subsequent
      // fetches that add models will surface those as "+N new" until the user
      // opens the picker / Manage sheet (which calls markSeen).
      if (!_seen.containsKey(id) || _seen[id]!.isEmpty) {
        _seen[id] = models.map((LlmModel m) => m.id).toSet();
        await _persistSeen(id);
      }
      // Auto-enable models when the account has none selected yet, so the
      // account is selectable in the chat picker immediately after connect.
      await _autoEnableModels(account, models);
    } catch (e) {
      _errors[id] = e;
      // Keep any previously-cached models so the picker stays usable offline.
      if (!_cache.containsKey(id)) _cache[id] = const <LlmModel>[];
      await _persistError(id, e);
      if (!silent) rethrow;
    } finally {
      _inFlight.remove(id);
      completer.complete();
      notifyListeners();
    }
  }

  /// When [account] has no enabled models and the fetch returned a non-empty
  /// list, enable all of them (mirroring the Quick-Add flow's "select all"
  /// default). This makes a freshly-connected account immediately usable
  /// without forcing the user to pick models first.
  Future<void> _autoEnableModels(
    ProviderAccount account,
    List<LlmModel> models,
  ) async {
    if (models.isEmpty) return;
    if (account.enabledModels.isNotEmpty) return;
    final List<String> ids = models.map((LlmModel m) => m.id).toList();
    await _providers.setAllowedModels(account.id, ids);
  }

  ProviderAccount? _lookup(String accountId) {
    for (final ProviderAccount a in _providers.accounts) {
      if (a.id == accountId) return a;
    }
    return null;
  }

  void _onAccountsChanged() {
    // Drop cache entries for removed accounts and fetch any new ones.
    final Set<String> live = _providers.accounts.map((a) => a.id).toSet();
    _cache.removeWhere((String id, _) => !live.contains(id));
    _errors.removeWhere((String id, _) => !live.contains(id));
    _seen.removeWhere((String id, _) => !live.contains(id));
    for (final ProviderAccount a in _providers.accounts) {
      if (!_cache.containsKey(a.id)) {
        unawaited(_fetch(a, silent: true));
      }
    }
    notifyListeners();
  }

  /// Marks [ids] as acknowledged for [accountId] and persists them. Called
  /// when the user opens the Manage sheet or the chat picker (so the "+N new"
  /// badge clears once the user has actually looked at the list).
  Future<void> markSeen(String accountId, Iterable<String> ids) async {
    if (ids.isEmpty) return;
    seenFor(accountId).addAll(ids);
    notifyListeners();
    await _persistSeen(accountId);
  }

  Future<void> _persistSeen(String accountId) async {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return;
    final Set<String>? set = _seen[accountId];
    if (set == null) return;
    await prefs.setString(
      '$_seenPrefix::$accountId',
      jsonEncode(set.toList()),
    );
  }

  Future<void> _persist(String accountId, List<LlmModel> models) async {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return;
    final String json = jsonEncode(
      models
          .map(
            (LlmModel m) => <String, Object?>{
              'id': m.id,
              if (m.displayName != null) 'displayName': m.displayName,
              'hidden': m.hidden,
            },
          )
          .toList(),
    );
    await prefs.setString('$_keyPrefix::$accountId', json);
  }

  Future<void> _persistError(String accountId, Object error) async {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString('$_errorPrefix::$accountId', '$error');
  }

  /// Loads cached models for [accountId] from disk into the in-memory cache.
  /// Called on startup for each account before the network fetch lands.
  Future<void> loadCached(String accountId) async {
    if (_cache.containsKey(accountId)) return;
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return;
    final String? json = prefs.getString('$_keyPrefix::$accountId');
    if (json != null) {
      try {
        final List<dynamic> decoded = jsonDecode(json) as List<dynamic>;
        _cache[accountId] = decoded
            .map(
              (dynamic m) => LlmModel(
                id: m['id'] as String,
                displayName: m['displayName'] as String?,
                hidden: (m['hidden'] as bool?) ?? false,
              ),
            )
            .toList();
      } catch (_) {
        // Corrupt cache — ignore, the network fetch will repopulate.
      }
    }
    final String? err = prefs.getString('$_errorPrefix::$accountId');
    if (err != null) _errors[accountId] = err;
    await _loadSeen(accountId);
  }

  Future<void> _loadSeen(String accountId) async {
    if (_seen.containsKey(accountId)) return;
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return;
    final String? raw = prefs.getString('$_seenPrefix::$accountId');
    if (raw == null) return;
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      _seen[accountId] = list.whereType<String>().toSet();
    } catch (_) {
      // Corrupt — ignore; next markSeen repopulates.
    }
  }

  @override
  void dispose() {
    _providers.removeListener(_onAccountsChanged);
    super.dispose();
  }
}
