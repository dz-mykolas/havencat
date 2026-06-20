import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/widgets/fade_slide_in.dart';
import '../../domain/models/model_pricing.dart';
import 'pricing_format.dart';
import 'pricing_viewmodel.dart';
import 'widgets/model_card.dart';
import 'widgets/model_detail_sheet.dart';
import 'widgets/provider_grid.dart';

/// Browses the public models.dev database as a two-step Discover flow:
///
///   step 1 — providers grid (every provider, with model count + "from $x")
///   step 2 — one provider's models, per-(provider, model) cards with input/
///            output prices, context + capability chips; tap for full details.
///
/// A "Browse all" affordance collapses every provider's models into a single
/// searchable/sortable list (the global search escape hatch). The catalog is
/// fetched once (and pre-warmed at app startup), so every step after the first
/// is pure in-memory filtering — instant, no network.
class PricingScreen extends ConsumerStatefulWidget {
  const PricingScreen({super.key});

  @override
  ConsumerState<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends ConsumerState<PricingScreen> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PricingViewModel vm = ref.watch(pricingViewModelProvider);
    return Scaffold(
      appBar: AppBar(
        leading: vm.view != PricingView.overview
            ? IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: vm.backToOverview,
              )
            : null,
        title: Text(_title(vm)),
        actions: <Widget>[
          ListenableBuilder(
            listenable: vm,
            builder: (BuildContext context, _) {
              return IconButton(
                tooltip: 'Refresh',
                onPressed: vm.refreshing ? null : vm.refresh,
                icon: vm.refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppTheme.panelMaxWidth),
            child: ListenableBuilder(
              listenable: vm,
              builder: (BuildContext context, _) => _buildBody(context, vm),
            ),
          ),
        ),
      ),
    );
  }

  String _title(PricingViewModel vm) {
    switch (vm.view) {
      case PricingView.overview:
        return 'Discover';
      case PricingView.provider:
        return vm.selectedProvider?.name ?? 'Models';
      case PricingView.all:
        return 'All models';
    }
  }

  Widget _buildBody(BuildContext context, PricingViewModel vm) {
    if (vm.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (vm.error != null && vm.catalog == null) {
      return _ErrorState(onRetry: vm.load);
    }

    switch (vm.view) {
      case PricingView.overview:
        return _Overview(
          vm: vm,
          onOpenProvider: vm.openProvider,
          onBrowseAll: vm.showAll,
        );
      case PricingView.provider:
      case PricingView.all:
        return _ModelList(
          vm: vm,
          searchController: _search,
          onOpenModel: (PricedModel m) => showModelDetailSheet(context, m),
        );
    }
  }
}

class _Overview extends StatelessWidget {
  const _Overview({
    required this.vm,
    required this.onOpenProvider,
    required this.onBrowseAll,
  });

  final PricingViewModel vm;
  final ValueChanged<String> onOpenProvider;
  final VoidCallback onBrowseAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${vm.providers.length} providers · ${vm.totalCount} models'
                  '${vm.fetchedAt != null ? ' · updated ${formatRelative(vm.fetchedAt!)}' : ''}',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
              _BrowseAllButton(onTap: onBrowseAll),
            ],
          ),
        ),
        Expanded(child: ProviderGrid(providers: vm.providers, onTap: onOpenProvider)),
      ],
    );
  }
}

class _ModelList extends StatelessWidget {
  const _ModelList({
    required this.vm,
    required this.searchController,
    required this.onOpenModel,
  });

  final PricingViewModel vm;
  final TextEditingController searchController;
  final ValueChanged<PricedModel> onOpenModel;

  @override
  Widget build(BuildContext context) {
    final List<PricedModel> results = vm.results;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: _SearchField(
            controller: searchController,
            hint: vm.view == PricingView.provider
                ? 'Search in ${vm.selectedProvider?.name ?? "this provider"}'
                : 'Search all models',
            onChanged: vm.setQuery,
            onClear: () {
              searchController.clear();
              vm.clearQuery();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _statusLine(vm, results.length),
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
              _SortButton(sort: vm.sort, onSelected: vm.setSort),
            ],
          ),
        ),
        Expanded(
          child: results.isEmpty
              ? const _NoResults()
              : _ResultsGrid(results: results, onTap: onOpenModel),
        ),
      ],
    );
  }

  String _statusLine(PricingViewModel vm, int shown) {
    if (vm.query.trim().isEmpty) {
      final int total = vm.view == PricingView.provider
          ? (vm.selectedProvider?.models.length ?? 0)
          : vm.totalCount;
      return '$total models';
    }
    return '$shown matches';
  }
}

/// Responsive card grid: a lazy two-up grid on wide layouts, single column on
/// narrow ones. We pair items into rows (rather than a fixed-ratio GridView) so
/// cards keep their natural, content-driven height.
class _ResultsGrid extends StatelessWidget {
  const _ResultsGrid({required this.results, required this.onTap});

  final List<PricedModel> results;
  final ValueChanged<PricedModel> onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 560 ? 2 : 1;
        final int rowCount = (results.length / columns).ceil();
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: rowCount,
          itemBuilder: (BuildContext context, int row) {
            final List<Widget> cells = <Widget>[];
            for (int col = 0; col < columns; col++) {
              final int index = row * columns + col;
              if (col > 0) cells.add(const SizedBox(width: 12));
              if (index < results.length) {
                final PricedModel model = results[index];
                cells.add(
                  Expanded(
                    child: ModelCard(
                      model: model,
                      onTap: () => onTap(model),
                    ),
                  ),
                );
              } else {
                cells.add(const Expanded(child: SizedBox.shrink()));
              }
            }
            // Stagger only the first screenful so far-down rows appear instantly.
            final Duration delay = row < 8
                ? Duration(milliseconds: row * 45)
                : Duration.zero;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FadeSlideIn(
                delay: delay,
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: cells,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _BrowseAllButton extends StatelessWidget {
  const _BrowseAllButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.apps, size: 16, color: AppTheme.textSecondary),
            SizedBox(width: 6),
            Text(
              'Browse all',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppTheme.textSecondary),
        prefixIcon: const Icon(
          Icons.search,
          color: AppTheme.textSecondary,
          size: 20,
        ),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (BuildContext context, TextEditingValue value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close, size: 18),
              color: AppTheme.textSecondary,
              onPressed: onClear,
            );
          },
        ),
        filled: true,
        fillColor: AppTheme.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppTheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppTheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppTheme.brandViolet),
        ),
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.sort, required this.onSelected});

  final PricingSort sort;
  final ValueChanged<PricingSort> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<PricingSort>(
      tooltip: 'Sort',
      initialValue: sort,
      onSelected: onSelected,
      color: AppTheme.surfaceHigh,
      position: PopupMenuPosition.under,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<PricingSort>>[
        for (final PricingSort option in PricingSort.values)
          PopupMenuItem<PricingSort>(
            value: option,
            child: Text(
              option.label,
              style: const TextStyle(color: AppTheme.textPrimary),
            ),
          ),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.sort, size: 16, color: AppTheme.textSecondary),
            SizedBox(width: 6),
            Text(
              'Sort',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.search_off, size: 44, color: AppTheme.textSecondary),
          SizedBox(height: 12),
          Text(
            'No models match your search',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: AppTheme.textSecondary,
            ),
            const SizedBox(height: 16),
            const Text(
              "Couldn't load model pricing",
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Check your connection and try again. Data is provided by '
              'models.dev.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
