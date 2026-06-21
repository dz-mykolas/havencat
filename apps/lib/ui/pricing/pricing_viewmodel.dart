import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fuzzy/data/result.dart';
import 'package:fuzzy/fuzzy.dart';

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

/// Which top-level tab the user is browsing in the Discover panel.
///
///   - [labs]     -> the orgs that own the models (OpenAI, Anthropic, xAI…),
///                   derived from the `lab/model` id prefix on router-served
///                   entries (falling back to the provider id for first-party).
///   - [models]   -> every model across every provider, flat — the global
///                   searchable list (formerly the "Browse all" escape hatch,
///                   now a first-class tab with its own dedicated search).
///   - [providers] -> hosting APIs (OpenRouter, OpenAI, Anthropic, Qiniu…).
///
/// Each scope keeps its own search query (see [_queries]) so switching tabs
/// preserves the text the user typed — "gpt" on Models, "open" on Providers,
/// etc. — matching the "dedicated search per tab" UX.
enum PricingScope { labs, models, providers }

/// A capability/filter toggle surfaced as a chip above the model list.
///
/// [reasoning] and [nonReasoning] are mutually exclusive in intent (a model is
/// either reasoning or not); they're surfaced as separate chips rather than a
/// tri-state so the user can pick either side of the comparison.
enum PricingFilter {
  reasoning('Reasoning'),
  nonReasoning('Non-reasoning'),
  vision('Vision'),
  openWeights('Open'),
  free('Free');

  const PricingFilter(this.label);

  final String label;

  /// Whether the model satisfies this filter.
  bool matches(PricedModel m) {
    switch (this) {
      case PricingFilter.reasoning:
        return m.reasoning;
      case PricingFilter.nonReasoning:
        return !m.reasoning;
      case PricingFilter.vision:
        return m.supportsVision;
      case PricingFilter.openWeights:
        return m.openWeights;
      case PricingFilter.free:
        return m.cost?.isFree ?? false;
    }
  }
}

/// Where in the Discover flow the user is, *within* the [providers] or [labs]
/// scope. The [models] scope is always a flat list, so it ignores this and
/// renders the model list directly.
///
///   - [overview]  -> the groups grid (step 1)
///   - [provider]  -> one group's models (step 2)
///   - [all]       -> preserved for the standalone PricingScreen back-compat
///                    (the Discover panel no longer uses this since the Models
///                    tab replaced the "Browse all" affordance).
enum PricingView { overview, provider, all }

/// UI state for the model-pricing browser (Discover).
///
/// Loads the models.dev catalog via [ModelsDevService] (cached, pre-warmed at
/// app startup) and exposes a three-tab, searchable, sortable, filterable
/// view of it:
///   - **Labs** tab: groups grid ([PricingView.overview]) of the orgs that
///     own each model, drill into one lab's models ([PricingView.provider]).
///   - **Models** tab: every model across every provider, flat — search filters
///     the list directly (no drill-in).
///   - **Providers** tab: groups grid of hosting APIs, drill into one
///     provider's models.
///
/// Each tab carries its own search query; the search bar is always visible.
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
  PricingSort _sort = PricingSort.newest;
  PricingView _view = PricingView.overview;
  PricingScope _scope = PricingScope.providers;
  final Set<PricingFilter> _filters = <PricingFilter>{};

  /// Per-scope search query. Switching tabs swaps which entry is active (see
  /// [query]/[setQuery]), so each tab keeps the text the user typed into it.
  final Map<PricingScope, String> _queries = <PricingScope, String>{
    for (final PricingScope s in PricingScope.values) s: '',
  };

  /// The group the user drilled into, or null in [overview]/[models].
  String? _selectedGroupId;

  /// Fuzzy search index over the catalog's provider/lab groups, rebuilt
  /// alongside every catalog load. Searches the group's display name + id.
  /// The model list is searched via [_buildModelIndex] instead — it's built
  /// per-query so it covers whichever pool is active (canonical registry for
  /// the Models tab, or one provider's serving entries when drilled in).
  Fuzzy<ProviderModels>? _groupIndex;

  /// Builds a fuzzy search index over [models] (name/id/provider/lab, weighted
  /// toward the display name). `tokenize: true` + `matchAllTokens: true` so
  /// multi-word queries like "gpt 5.5" require BOTH tokens to match — "gpt"
  /// alone won't surface `gpt-5.5 Instant`, and "5.4" won't surface `GLM-5.2`
  /// (no "gpt" token). `shouldNormalize: true` strips diacritics. Threshold
  /// 0.3 is strict enough that `5.4` won't match `5.5`/`5.2` (1-char
  /// substitution in a 3-char token = 0.33 > 0.3) while still tolerating
  /// missing separators (`gpt5.5` → `gpt-5.5` = 1 insertion / 6 chars = 0.17).
  static Fuzzy<PricedModel> _buildModelIndex(List<PricedModel> models) {
    return Fuzzy<PricedModel>(
      models,
      options: FuzzyOptions<PricedModel>(
        keys: <WeightedKey<PricedModel>>[
          WeightedKey(
            name: 'name',
            getter: (PricedModel m) => m.name,
            weight: 0.7,
          ),
          WeightedKey(name: 'id', getter: (PricedModel m) => m.id, weight: 0.5),
          WeightedKey(
            name: 'provider',
            getter: (PricedModel m) => m.providerName,
            weight: 0.3,
          ),
          WeightedKey(
            name: 'lab',
            getter: (PricedModel m) => m.labId,
            weight: 0.3,
          ),
        ],
        threshold: 0.3,
        tokenize: true,
        matchAllTokens: true,
        isCaseSensitive: false,
        shouldNormalize: true,
      ),
    );
  }

  /// Rebuilds the groups fuzzy index from the current catalog. Called after
  /// every [load]/[refresh] so the search reflects the latest data.
  void _rebuildIndexes() {
    final ModelsCatalog? catalog = _catalog;
    if (catalog == null) {
      _groupIndex = null;
      return;
    }
    final List<ProviderModels> allGroups = <ProviderModels>[
      ...catalog.providers,
      ...catalog.labs,
    ];
    _groupIndex = Fuzzy<ProviderModels>(
      allGroups,
      options: FuzzyOptions<ProviderModels>(
        keys: <WeightedKey<ProviderModels>>[
          WeightedKey(
            name: 'name',
            getter: (ProviderModels g) => g.name,
            weight: 0.7,
          ),
          WeightedKey(
            name: 'id',
            getter: (ProviderModels g) => g.id,
            weight: 0.5,
          ),
        ],
        threshold: 0.3,
        tokenize: true,
        matchAllTokens: true,
        isCaseSensitive: false,
        shouldNormalize: true,
      ),
    );
  }

  bool get loading => _loading;
  bool get refreshing => _refreshing;
  Object? get error => _error;
  ModelsCatalog? get catalog => _catalog;

  /// The active scope's search query. Each scope keeps its own, so switching
  /// tabs swaps in that tab's last-typed text.
  String get query => _queries[_scope] ?? '';

  PricingSort get sort => _sort;
  PricingView get view => _view;
  PricingScope get scope => _scope;

  /// Whether the current scope renders a flat model list (no groups grid).
  /// True only for [PricingScope.models].
  bool get isFlatModelView => _scope == PricingScope.models;

  Set<PricingFilter> get filters => Set<PricingFilter>.unmodifiable(_filters);

  /// The group id drilled into, or null when not in [PricingView.provider].
  String? get selectedGroupId => _selectedGroupId;

  /// When the underlying data was fetched (for the "updated X ago" label).
  DateTime? get fetchedAt => _catalog?.fetchedAt;

  /// Groups for the overview grid, based on the current [scope], filtered by
  /// the active scope's search query. Empty until loaded.
  List<ProviderModels> get groups {
    final List<ProviderModels> source = switch (_scope) {
      PricingScope.providers => _catalog?.providers ?? const [],
      PricingScope.labs => _catalog?.labs ?? const [],
      PricingScope.models => const <ProviderModels>[],
    };
    final String q = query.trim();
    Iterable<ProviderModels> stream = source;
    if (q.isNotEmpty) {
      // Fuzzy match across the scope's groups (name + id). Falls back to the
      // full scope list if the index isn't built yet (catalog still loading).
      final Fuzzy<ProviderModels>? index = _groupIndex;
      if (index == null) {
        stream = stream.where(
          (ProviderModels g) =>
              g.name.toLowerCase().contains(q.toLowerCase()) ||
              g.id.toLowerCase().contains(q.toLowerCase()),
        );
      } else {
        final Set<ProviderModels> matches = index
            .search(q)
            .map((Result<ProviderModels> r) => r.item)
            .toSet();
        stream = stream.where(matches.contains);
      }
    }
    return stream.toList();
  }

  /// Compatibility alias for the providers grouping (unfiltered by query).
  /// Kept so the standalone PricingScreen's overview keeps working unchanged.
  List<ProviderModels> get providers => _catalog?.providers ?? const [];

  /// Total model count across every provider, for the header.
  int get totalCount => _catalog?.models.length ?? 0;

  /// The group the user drilled into (if any), resolved from the current
  /// scope's group list. Looks up against the *unfiltered* list (not [groups])
  /// so a search query that filters the grid doesn't drop the group the user
  /// is already viewing — typing "gpt" while inside OpenAI filters models, not
  /// the OpenAI group itself.
  ProviderModels? get selectedGroup {
    final String? id = _selectedGroupId;
    if (id == null || _catalog == null) return null;
    final List<ProviderModels> source = switch (_scope) {
      PricingScope.providers => _catalog!.providers,
      PricingScope.labs => _catalog!.labs,
      PricingScope.models => const <ProviderModels>[],
    };
    for (final ProviderModels p in source) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Backwards-compat alias for [selectedGroup].
  ProviderModels? get selectedProvider => selectedGroup;

  /// The model list for the current view, with search, filters, and sort
  /// applied.
  ///
  /// - [PricingScope.models]: every model in the catalog.
  /// - [PricingView.provider] (providers/labs scope): the drilled-in group's
  ///   models.
  /// - [PricingView.overview]: empty (the grid shows [groups] instead).
  /// - [PricingView.all] (standalone PricingScreen only): every model.
  List<PricedModel> get results {
    final ModelsCatalog? catalog = _catalog;
    if (catalog == null) return const <PricedModel>[];

    final List<PricedModel> pool;
    if (isFlatModelView) {
      pool = catalog.models;
    } else {
      switch (_view) {
        case PricingView.overview:
          pool = const <PricedModel>[];
          break;
        case PricingView.provider:
          pool = selectedGroup?.models ?? const <PricedModel>[];
          break;
        case PricingView.all:
          pool = catalog.models;
          break;
      }
    }

    final String q = query.trim();
    Iterable<PricedModel> stream = pool;
    if (q.isNotEmpty) {
      // Fuzzy match across name/id/provider/lab. We search the pool itself
      // (not a global index) so the provider drill-in view matches the
      // provider's serving entries rather than the canonical registry.
      // Pools are small (≤220 canonical models, or one provider's entries),
      // so building the index per query is cheap.
      final Fuzzy<PricedModel> index = _buildModelIndex(pool);
      final Set<PricedModel> matches = index
          .search(q)
          .map((Result<PricedModel> r) => r.item)
          .toSet();
      stream = stream.where(matches.contains);
    }
    if (_filters.isNotEmpty) {
      stream = stream.where(
        (PricedModel m) => _filters.every((PricingFilter f) => f.matches(m)),
      );
    }

    final List<PricedModel> filtered = stream.toList();
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
      _rebuildIndexes();
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
      _rebuildIndexes();
    } catch (error) {
      // Keep showing whatever we had; surface the error only if we have nothing.
      if (_catalog == null) _error = error;
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  /// Updates the active scope's search query. Each scope keeps its own query,
  /// so this only affects the currently-selected tab.
  void setQuery(String value) {
    if (value == (_queries[_scope] ?? '')) return;
    _queries[_scope] = value;
    notifyListeners();
  }

  /// Clears the active scope's search query.
  void clearQuery() {
    final String current = _queries[_scope] ?? '';
    if (current.isEmpty) return;
    _queries[_scope] = '';
    notifyListeners();
  }

  void setSort(PricingSort value) {
    if (value == _sort) return;
    _sort = value;
    notifyListeners();
  }

  /// Switch tabs. The new tab's own search query is restored (so the text the
  /// user typed there previously reappears). For the providers/labs scopes we
  /// return to the overview grid; the [models] scope is always a flat list so
  /// [view] is irrelevant there.
  ///
  /// Tapping the already-active tab is treated as a "pop to overview" — it
  /// clears any drill-in (selected group / provider view) so the user lands
  /// back on that tab's top-level grid.
  void setScope(PricingScope value) {
    if (value == _scope) {
      if (_view == PricingView.overview && _selectedGroupId == null) return;
      _view = PricingView.overview;
      _selectedGroupId = null;
      notifyListeners();
      return;
    }
    _scope = value;
    _view = PricingView.overview;
    _selectedGroupId = null;
    notifyListeners();
  }

  /// Toggle a filter chip. Only affects the model list (not the overview grid).
  ///
  /// [PricingFilter.reasoning] and [PricingFilter.nonReasoning] are mutually
  /// exclusive — activating one clears the other so the result set can't go
  /// empty by accident.
  void toggleFilter(PricingFilter filter) {
    if (!_filters.add(filter)) {
      _filters.remove(filter);
    } else if (filter == PricingFilter.reasoning) {
      _filters.remove(PricingFilter.nonReasoning);
    } else if (filter == PricingFilter.nonReasoning) {
      _filters.remove(PricingFilter.reasoning);
    }
    notifyListeners();
  }

  void clearFilters() {
    if (_filters.isEmpty) return;
    _filters.clear();
    notifyListeners();
  }

  /// Drill into a group's models (step 2). Clears the active scope's query —
  /// the query on the groups grid ("open" matching provider names) doesn't
  /// carry the same intent as a query on this group's models, so we reset it
  /// rather than re-target it. Switching tabs still preserves each tab's own
  /// query (see [setScope]).
  void openProvider(String providerId) {
    _selectedGroupId = providerId;
    _view = PricingView.provider;
    _queries[_scope] = '';
    notifyListeners();
  }

  /// Show every model across every provider (standalone PricingScreen only).
  /// The Discover panel's Models tab replaces this affordance.
  void showAll() {
    _view = PricingView.all;
    notifyListeners();
  }

  /// Return to the groups grid (step 1). Keeps sort + the active scope's query
  /// (so the user's filter on the groups grid is preserved across a drill-in).
  void backToOverview() {
    if (_view == PricingView.overview) return;
    _view = PricingView.overview;
    _selectedGroupId = null;
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
      a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());

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
