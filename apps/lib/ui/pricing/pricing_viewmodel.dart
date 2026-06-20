import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/pricing/models_dev_service.dart';
import '../../domain/models/model_pricing.dart';
import '../../providers.dart';

/// How the pricing list is ordered.
enum PricingSort {
  newest('Newest'),
  priceLow('Price: low'),
  priceHigh('Price: high'),
  name('Name');

  const PricingSort(this.label);

  final String label;
}

/// Where in the Discover flow the user is.
///
/// The catalog is fetched exactly once (then cached), so navigating between
/// these is pure in-memory filtering:
///   - [overview]  -> the providers grid (step 1)
///   - [provider]  -> one provider's models (step 2)
///   - [all]      -> every model across every provider (search-as-escape-hatch)
enum PricingView { overview, provider, all }

/// UI state for the model-pricing browser (Discover).
///
/// Loads the models.dev catalog via [ModelsDevService] (cached, pre-warmed at
/// app startup) and exposes a multi-step, searchable, sortable view of it:
///   step 1: providers grid ([PricingView.overview]),
///   step 2: one provider's models ([PricingView.provider]),
///   global: every model at once ([PricingView.all]).
/// Mirrors the app's other view models: a [ChangeNotifier] driven by a single
/// `ListenableBuilder`.
class PricingViewModel extends ChangeNotifier {
  PricingViewModel(this._service) {
    load();
  }

  final ModelsDevService _service;

  bool _loading = true;
  bool _refreshing = false;
  Object? _error;
  ModelsCatalog? _catalog;
  String _query = '';
  PricingSort _sort = PricingSort.newest;
  PricingView _view = PricingView.overview;

  /// The provider the user drilled into, or null in [overview]/[all].
  String? _selectedProviderId;

  bool get loading => _loading;
  bool get refreshing => _refreshing;
  Object? get error => _error;
  ModelsCatalog? get catalog => _catalog;

  String get query => _query;
  PricingSort get sort => _sort;
  PricingView get view => _view;

  /// The provider id drilled into, or null when not in [PricingView.provider].
  String? get selectedProviderId => _selectedProviderId;

  /// When the underlying data was fetched (for the "updated X ago" label).
  DateTime? get fetchedAt => _catalog?.fetchedAt;

  /// Providers for the overview grid, sorted by name. Empty until loaded.
  List<ProviderModels> get providers => _catalog?.providers ?? const [];

  /// Total model count across every provider, for the header.
  int get totalCount => _catalog?.models.length ?? 0;

  /// The provider the user drilled into (if any), resolved from the catalog.
  ProviderModels? get selectedProvider {
    final String? id = _selectedProviderId;
    if (id == null || _catalog == null) return null;
    for (final ProviderModels p in _catalog!.providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The model list for the current view, with search + sort applied.
  ///
  /// In [overview] this is unused (the grid shows [providers]); in
  /// [provider] it's [selectedProvider]'s models; in [all] it's every model.
  List<PricedModel> get results {
    final ModelsCatalog? catalog = _catalog;
    if (catalog == null) return const <PricedModel>[];

    final List<PricedModel> pool;
    switch (_view) {
      case PricingView.overview:
        pool = const <PricedModel>[];
        break;
      case PricingView.provider:
        pool = selectedProvider?.models ?? const <PricedModel>[];
        break;
      case PricingView.all:
        pool = catalog.models;
        break;
    }

    final String q = _query.trim().toLowerCase();
    final List<PricedModel> filtered = q.isEmpty
        ? List<PricedModel>.of(pool)
        : pool
              .where((PricedModel m) => m.searchIndex.contains(q))
              .toList();

    filtered.sort(_comparator);
    return filtered;
  }

  Future<void> load() async {
    _loading = _catalog == null;
    _error = null;
    notifyListeners();
    try {
      _catalog = await _service.load();
      _error = null;
    } catch (error) {
      _error = error;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    notifyListeners();
    try {
      _catalog = await _service.refresh();
      _error = null;
    } catch (error) {
      // Keep showing whatever we had; surface the error only if we have nothing.
      if (_catalog == null) _error = error;
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  void setQuery(String value) {
    if (value == _query) return;
    _query = value;
    notifyListeners();
  }

  void clearQuery() {
    if (_query.isEmpty) return;
    _query = '';
    notifyListeners();
  }

  void setSort(PricingSort value) {
    if (value == _sort) return;
    _sort = value;
    notifyListeners();
  }

  /// Drill into a provider's models (step 2). Clears any prior query.
  void openProvider(String providerId) {
    _selectedProviderId = providerId;
    _view = PricingView.provider;
    _query = '';
    notifyListeners();
  }

  /// Show every model across every provider (search-as-escape-hatch).
  void showAll() {
    _view = PricingView.all;
    notifyListeners();
  }

  /// Return to the providers grid (step 1). Keeps sort; clears query + drill-in.
  void backToOverview() {
    if (_view == PricingView.overview) return;
    _view = PricingView.overview;
    _selectedProviderId = null;
    _query = '';
    notifyListeners();
  }

  int _comparator(PricedModel a, PricedModel b) {
    switch (_sort) {
      case PricingSort.newest:
        final DateTime? ad = a.releaseDate;
        final DateTime? bd = b.releaseDate;
        if (ad != null && bd != null) return bd.compareTo(ad);
        if (ad == null && bd != null) return 1;
        if (ad != null && bd == null) return -1;
        return _byName(a, b);
      case PricingSort.priceLow:
        return _byPrice(a, b, ascending: true);
      case PricingSort.priceHigh:
        return _byPrice(a, b, ascending: false);
      case PricingSort.name:
        return _byName(a, b);
    }
  }

  int _byName(PricedModel a, PricedModel b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  int _byPrice(PricedModel a, PricedModel b, {required bool ascending}) {
    // Rank by output price (the figure that usually dominates spend), then
    // input. Models with no published price sort last regardless of direction.
    final double? ap = a.cost?.output ?? a.cost?.input;
    final double? bp = b.cost?.output ?? b.cost?.input;
    if (ap == null && bp == null) return _byName(a, b);
    if (ap == null) return 1;
    if (bp == null) return -1;
    final int cmp = ascending ? ap.compareTo(bp) : bp.compareTo(ap);
    return cmp != 0 ? cmp : _byName(a, b);
  }
}

final pricingViewModelProvider = ChangeNotifierProvider<PricingViewModel>((
  ref,
) {
  return PricingViewModel(ref.watch(modelsDevServiceProvider));
});
