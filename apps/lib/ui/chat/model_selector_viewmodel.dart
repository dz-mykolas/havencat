import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/provider_account_repository.dart';
import '../../data/services/llm/model_service.dart';
import '../../data/services/storage/app_settings.dart';
import '../../domain/models/llm_model.dart';
import '../../domain/models/provider_account.dart';
import '../../providers.dart';

/// UI state for the chat header's provider + model pickers.
///
/// The provider list comes from [ProviderAccountRepository] (the configured
/// accounts). The model list is fetched dynamically from the active provider
/// every time it changes — nothing is hardcoded. When the fetch lands and the
/// account has no valid model selected yet, the first available model is picked
/// and persisted, so the default always reflects what the provider actually
/// offers.
class ModelSelectorViewModel extends ChangeNotifier {
  ModelSelectorViewModel(this._providers, this._modelService, this._settings) {
    _providers.addListener(_onProvidersChanged);
    _settings.addListener(_onSettingsChanged);
    _load();
  }

  final ProviderAccountRepository _providers;
  final ModelService _modelService;
  final AppSettings _settings;

  /// Everything the provider returned, including models it marks as hidden.
  List<LlmModel> _allModels = const <LlmModel>[];
  bool _loading = false;
  Object? _error;

  /// Which account we last kicked off a fetch for, so we only refetch when the
  /// active provider actually changes (not on every unrelated notify).
  String? _loadedForAccountId;

  /// Guards against out-of-order fetch results when the user switches provider
  /// quickly: only the latest token's result is applied.
  int _fetchToken = 0;

  // --- Provider (account) side -------------------------------------------

  List<ProviderAccount> get accounts => _providers.accounts;
  ProviderAccount? get activeAccount => _providers.activeAccount;
  String? get activeAccountId => _providers.activeAccountId;

  void selectProvider(String accountId) {
    if (accountId == _providers.activeAccountId) return;
    _providers.setActive(accountId);
  }

  // --- Model side ---------------------------------------------------------

  /// Models shown in the picker: all of them when "show hidden models" is on,
  /// otherwise only the provider-visible ones.
  List<LlmModel> get models => _settings.showHiddenModels
      ? _allModels
      : _allModels.where((LlmModel m) => !m.hidden).toList();

  bool get isLoading => _loading;
  Object? get error => _error;

  String? get selectedModelId {
    final Object? model = _providers.activeAccount?.config['model'];
    return (model is String && model.isNotEmpty) ? model : null;
  }

  void selectModel(String modelId) {
    final String? accountId = _providers.activeAccountId;
    if (accountId == null) return;
    _providers.setModel(accountId, modelId);
  }

  /// Re-fetches the current provider's models (used by the retry affordance).
  Future<void> refresh() => _load();

  void _onProvidersChanged() {
    if (_providers.activeAccountId != _loadedForAccountId) {
      _load();
    } else {
      // Account list or selected model changed — just rebuild the view.
      notifyListeners();
    }
  }

  void _onSettingsChanged() {
    // The visible set changed; rebuild and make sure a visible model is picked.
    notifyListeners();
    final ProviderAccount? account = _providers.activeAccount;
    if (account != null) _ensureDefaultSelected(account);
  }

  Future<void> _load() async {
    final ProviderAccount? account = _providers.activeAccount;
    _loadedForAccountId = _providers.activeAccountId;
    if (account == null) {
      _allModels = const <LlmModel>[];
      _loading = false;
      _error = null;
      notifyListeners();
      return;
    }

    final int token = ++_fetchToken;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final List<LlmModel> models = await _modelService.list(account);
      if (token != _fetchToken) return;
      _allModels = models;
      _loading = false;
      notifyListeners();
      _ensureDefaultSelected(account);
    } catch (e) {
      if (token != _fetchToken) return;
      _allModels = const <LlmModel>[];
      _loading = false;
      _error = e;
      notifyListeners();
    }
  }

  /// Picks a default from the currently-visible models when the account has no
  /// valid selection. Default = first visible model (never hardcoded).
  void _ensureDefaultSelected(ProviderAccount account) {
    final List<LlmModel> visible = models;
    if (visible.isEmpty) return;
    final Object? current = account.config['model'];
    final bool hasValid =
        current is String &&
        current.isNotEmpty &&
        visible.any((LlmModel m) => m.id == current);
    if (!hasValid) {
      _providers.setModel(account.id, visible.first.id);
    }
  }

  @override
  void dispose() {
    _providers.removeListener(_onProvidersChanged);
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }
}

final modelServiceProvider = Provider<ModelService>((ref) {
  return ModelService(
    adapters: ref.watch(adapterRegistryProvider),
    credentials: ref.watch(credentialResolverProvider),
  );
});

final modelSelectorViewModelProvider =
    ChangeNotifierProvider<ModelSelectorViewModel>((ref) {
      return ModelSelectorViewModel(
        ref.watch(providerAccountRepositoryProvider),
        ref.watch(modelServiceProvider),
        ref.watch(appSettingsProvider),
      );
    });
