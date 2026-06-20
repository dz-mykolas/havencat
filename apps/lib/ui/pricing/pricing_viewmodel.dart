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

/// UI state for the model-pricing browser.
///
/// Loads the models.dev catalog via [ModelsDevService] (cached) and exposes a
/// searchable / sortable view of it. Mirrors the app's other view models:
/// a [ChangeNotifier] the view drives with a single `ListenableBuilder`.
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

  /// True during the initial load (no catalog yet to show).
  bool get loading => _loading;

  /// True while a pull-to-refresh / manual refresh is in flight.
  bool get refreshing => _refreshing;

  /// The error from the last load, if it failed with no cached fallback.
  Object? get error => _error;

  /// The raw catalog, or null before the first successful load.
  ModelsCatalog? get catalog => _catalog;

  String get query => _query;
  PricingSort get sort => _sort;

  /// When the underlying data was fetched (for the "updated X ago" label).
  DateTime? get fetchedAt => _catalog?.fetchedAt;

  /// The current query + sort applied to the catalog.
  List<PricedModel> get results {
    final ModelsCatalog? catalog = _catalog;
    if (catalog == null) return const <PricedModel>[];

    final String q = _query.trim().toLowerCase();
    final List<PricedModel> filtered = q.isEmpty
        ? List<PricedModel>.of(catalog.models)
        : catalog.models
              .where((PricedModel m) => m.searchIndex.contains(q))
              .toList();

    filtered.sort(_comparator);
    return filtered;
  }

  /// Total model count (across all providers), for the header.
  int get totalCount => _catalog?.models.length ?? 0;

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

  void setSort(PricingSort value) {
    if (value == _sort) return;
    _sort = value;
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
