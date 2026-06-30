import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/provider_account_repository.dart';
import '../../data/services/llm/account_models_service.dart';
import '../../data/services/storage/app_settings.dart';
import '../../domain/models/llm_model.dart';
import '../../domain/models/provider_account.dart';
import '../../providers.dart';

/// UI state for the chat header's provider + model pickers.
///
/// The provider list comes from [ProviderAccountRepository] (the configured
/// accounts). The model list is read from [AccountModelsService]'s cache,
/// which is pre-warmed on startup (and refreshed when an account is added) —
/// the same pattern the Discover panel uses for the models.dev catalog. The
/// chat header never blocks first-frame on a network fetch; it shows cached
/// models immediately and updates when a background refresh lands.
class ModelSelectorViewModel extends ChangeNotifier {
  ModelSelectorViewModel(this._providers, this._accountModels, this._settings) {
    _providers.addListener(_onProvidersChanged);
    _accountModels.addListener(_onModelsChanged);
    _settings.addListener(_onSettingsChanged);
    // Defer the initial default-model pick to a microtask. Calling
    // _ensureDefaultSelected directly would call _providers.setModel(), which
    // notifies the repository, which notifies AccountModelsService — all
    // during this provider's initialization, which Riverpod forbids.
    scheduleMicrotask(() {
      if (_disposed) return;
      final ProviderAccount? account = _providers.activeAccount;
      if (account != null) _ensureDefaultSelected(account);
    });
  }

  final ProviderAccountRepository _providers;
  final AccountModelsService _accountModels;
  final AppSettings _settings;

  bool _disposed = false;

  // --- Provider (account) side -------------------------------------------

  List<ProviderAccount> get accounts => _providers.accounts;
  ProviderAccount? get activeAccount => _providers.activeAccount;
  String? get activeAccountId => _providers.activeAccountId;

  void selectProvider(String accountId) {
    if (accountId == _providers.activeAccountId) return;
    _providers.setActive(accountId);
  }

  // --- Model side ---------------------------------------------------------

  /// Models shown in the picker for the active account: all of them when
  /// "show hidden models" is on, otherwise only the provider-visible ones.
  /// Read straight from the [AccountModelsService] cache — no per-screen
  /// fetch. Null while the cache is still loading for this account.
  List<LlmModel>? get models {
    final String? id = _providers.activeAccountId;
    if (id == null) return const <LlmModel>[];
    final List<LlmModel>? cached = _accountModels.modelsFor(id);
    if (cached == null) return null;
    return _settings.showHiddenModels
        ? cached
        : cached.where((LlmModel m) => !m.hidden).toList();
  }

  /// True when a background fetch is running for the active account.
  bool get isLoading {
    final String? id = _providers.activeAccountId;
    return id != null && _accountModels.isLoading(id);
  }

  /// Last fetch error for the active account, or null.
  Object? get error {
    final String? id = _providers.activeAccountId;
    return id == null ? null : _accountModels.errorFor(id);
  }

  String? get selectedModelId {
    final Object? model = _providers.activeAccount?.config['model'];
    return (model is String && model.isNotEmpty) ? model : null;
  }

  void selectModel(String modelId) {
    final String? accountId = _providers.activeAccountId;
    if (accountId == null) return;
    _providers.setModel(accountId, modelId);
  }

  // --- Model availability deltas -----------------------------------------

  /// Models the provider currently serves (live `/listModels` cache), or null
  /// while the cache is still loading for the active account. This is the
  /// "available" set the deltas below are derived from.
  List<LlmModel>? get availableModels {
    final String? id = _providers.activeAccountId;
    if (id == null) return null;
    return _accountModels.modelsFor(id);
  }

  /// Ids the user has already acknowledged for the active account (seen in
  /// the picker or Manage sheet). A model is "new" when it's available but
  /// neither enabled nor seen.
  Set<String> get seenModelIds {
    final String? id = _providers.activeAccountId;
    if (id == null) return const <String>{};
    return _accountModels.seenFor(id);
  }

  /// New (unacknowledged, not-yet-enabled) model ids for the active account.
  /// Drives the "+N new" badge in the chat picker's provider column.
  Set<String> get newModelIds {
    final List<LlmModel>? avail = availableModels;
    if (avail == null) return const <String>{};
    final Set<String> enabled =
        _providers.activeAccount?.enabledModels.toSet() ?? const <String>{};
    final Set<String> seen = seenModelIds;
    return avail
        .map((LlmModel m) => m.id)
        .where((String id) => !enabled.contains(id) && !seen.contains(id))
        .toSet();
  }

  /// Enabled ids the provider no longer serves (deprecated or inaccessible).
  /// Drives the ⚠️ indicator in the Manage sheet and next to the selected
  /// model in the chat picker. These models are NOT disabled — the user can
  /// still pick them; failures surface in chat.
  Set<String> get deprecatedModelIds {
    final List<LlmModel>? avail = availableModels;
    final Set<String> availableIds = avail == null
        ? const <String>{}
        : avail.map((LlmModel m) => m.id).toSet();
    final Set<String> enabled =
        _providers.activeAccount?.enabledModels.toSet() ?? const <String>{};
    return enabled.difference(availableIds);
  }

  /// True when the currently-selected model is no longer served by the
  /// provider. Drives the ⚠️ indicator next to the selected model chip in the
  /// chat picker.
  bool get isSelectedModelDeprecated {
    final String? selected = selectedModelId;
    if (selected == null) return false;
    return deprecatedModelIds.contains(selected);
  }

  /// Per-account "new" count for the provider column badge. Returns 0 when
  /// the cache hasn't loaded yet (no false positives).
  int newCountFor(String accountId) {
    final List<LlmModel>? avail = _accountModels.modelsFor(accountId);
    if (avail == null) return 0;
    ProviderAccount? account;
    for (final ProviderAccount a in _providers.accounts) {
      if (a.id == accountId) {
        account = a;
        break;
      }
    }
    final Set<String> enabled =
        account?.enabledModels.toSet() ?? const <String>{};
    final Set<String> seen = _accountModels.seenFor(accountId);
    return avail
        .where((LlmModel m) => !enabled.contains(m.id) && !seen.contains(m.id))
        .length;
  }

  /// Marks every currently-available model as acknowledged for the active
  /// account, clearing the "+N new" badge. Called when the user opens the
  /// chat picker or the Manage sheet.
  Future<void> acknowledgeNewModels() async {
    final String? id = _providers.activeAccountId;
    if (id == null) return;
    final List<LlmModel>? avail = _accountModels.modelsFor(id);
    if (avail == null) return;
    await _accountModels.markSeen(id, avail.map((LlmModel m) => m.id));
  }

  /// Re-fetches the active account's models from the provider (used by the
  /// retry affordance). Delegates to [AccountModelsService.refresh].
  Future<void> refresh() async {
    final String? id = _providers.activeAccountId;
    if (id == null) return;
    try {
      await _accountModels.refresh(id);
    } catch (_) {
      // Error is already captured in the service; the view reads it via
      // [error]. Swallow here so the retry button doesn't throw uncaught.
    }
    _ensureDefaultSelected();
  }

  void _onProvidersChanged() {
    // Active provider changed — ensure a fetch is in flight (the service
    // coalesces duplicates) and pick a default model from whatever's cached.
    // The fetch is deferred to a microtask so we don't trigger
    // notifyListeners on AccountModelsService during a provider build (which
    // Riverpod forbids).
    final String? id = _providers.activeAccountId;
    if (id != null && _accountModels.modelsFor(id) == null) {
      scheduleMicrotask(() {
        if (!_disposed) _accountModels.refresh(id);
      });
    }
    notifyListeners();
    final ProviderAccount? account = _providers.activeAccount;
    if (account != null) _ensureDefaultSelected(account);
  }

  void _onModelsChanged() {
    // Cache updated (background fetch landed) — rebuild and ensure a default
    // model is picked from the now-available list.
    notifyListeners();
    final ProviderAccount? account = _providers.activeAccount;
    if (account != null) _ensureDefaultSelected(account);
  }

  void _onSettingsChanged() {
    // The visible set changed; rebuild and make sure a visible model is picked.
    notifyListeners();
    final ProviderAccount? account = _providers.activeAccount;
    if (account != null) _ensureDefaultSelected(account);
  }

  /// Picks a default from the currently-visible models when the account has
  /// no selection at all. Default = first visible model (never hardcoded).
  ///
  /// Does NOT auto-correct a selection that's merely absent from the visible
  /// list (e.g. the provider dropped the model since it was selected). Those
  /// deprecated selections are left intact so the user sees the ⚠️ indicator
  /// and can choose to switch — failures surface in chat rather than being
  /// silently papered over.
  void _ensureDefaultSelected([ProviderAccount? account]) {
    account ??= _providers.activeAccount;
    if (account == null) return;
    final List<LlmModel>? visible = models;
    if (visible == null || visible.isEmpty) return;
    final Object? current = account.config['model'];
    final bool hasSelection = current is String && current.isNotEmpty;
    if (!hasSelection) {
      _providers.setModel(account.id, visible.first.id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _providers.removeListener(_onProvidersChanged);
    _accountModels.removeListener(_onModelsChanged);
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }
}

final modelSelectorViewModelProvider =
    ChangeNotifierProvider<ModelSelectorViewModel>((ref) {
      // ref.read (not ref.watch): ModelSelectorViewModel listens to all three
      // ChangeNotifiers via addListener. ref.watch would recreate the VM on
      // every notifyListeners(), losing its listener subscriptions mid-flight.
      return ModelSelectorViewModel(
        ref.read(providerAccountRepositoryProvider),
        ref.read(accountModelsServiceProvider),
        ref.read(appSettingsProvider),
      );
    });
