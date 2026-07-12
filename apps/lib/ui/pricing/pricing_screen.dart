import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/widgets/app_scroll_view.dart';
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
                icon: Icon(Icons.arrow_back),
                onPressed: vm.backToOverview,
              )
            : null,
        title: Text(_title(vm)),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: vm.refreshing ? null : vm.refresh,
            icon: vm.refreshing
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.refresh),
          ),
          SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: AppTheme.panelMaxWidth),
            child: _buildBody(context, vm),
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
      return Center(child: CircularProgressIndicator());
    }
    if (vm.error != null && vm.catalog == null) {
      return _ErrorState(onRetry: vm.load);
    }

    switch (vm.view) {
      case PricingView.overview:
        return _Overview(vm: vm, onOpenProvider: vm.openProvider);
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
  const _Overview({required this.vm, required this.onOpenProvider});

  final PricingViewModel vm;
  final ValueChanged<String> onOpenProvider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${vm.providers.length} providers · ${vm.totalCount} models'
                  '${vm.fetchedAt != null ? ' · updated ${formatRelative(vm.fetchedAt!)}' : ''}',
                  style: TextStyle(
                    color: context.appColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ProviderGrid(providers: vm.providers, onTap: onOpenProvider),
        ),
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
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
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
          padding: EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _statusLine(vm, results.length),
                  style: TextStyle(
                    color: context.appColors.textSecondary,
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
              ? _NoResults()
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

class _ResultsGrid extends StatelessWidget {
  const _ResultsGrid({required this.results, required this.onTap});

  final List<PricedModel> results;
  final ValueChanged<PricedModel> onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 560 ? 2 : 1;
        return AppScrollView(
          builder: (BuildContext context, AppScrollController controller) =>
              GridView.builder(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, 2, 12, 16),
                scrollCacheExtent: ScrollCacheExtent.pixels(200),
                addAutomaticKeepAlives: false,
                itemCount: results.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  mainAxisExtent: columns == 1 ? 86 : 96,
                ),
                itemBuilder: (BuildContext context, int index) {
                  final PricedModel model = results[index];
                  return ModelCard(model: model, onTap: () => onTap(model));
                },
              ),
        );
      },
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
      style: TextStyle(color: context.appColors.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: context.appColors.textSecondary),
        prefixIcon: Icon(
          Icons.search,
          color: context.appColors.textSecondary,
          size: 20,
        ),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (BuildContext context, TextEditingValue value, _) {
            if (value.text.isEmpty) return SizedBox.shrink();
            return IconButton(
              tooltip: 'Clear',
              icon: Icon(Icons.close, size: 18),
              color: context.appColors.textSecondary,
              onPressed: onClear,
            );
          },
        ),
        filled: true,
        fillColor: context.appColors.surface,
        contentPadding: EdgeInsets.symmetric(vertical: 0, horizontal: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: context.appColors.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: context.appColors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: context.appColors.brandViolet),
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
      color: context.appColors.surfaceHigh,
      position: PopupMenuPosition.under,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<PricingSort>>[
        for (final PricingSort option in PricingSort.values)
          PopupMenuItem<PricingSort>(
            value: option,
            child: Text(
              option.label,
              style: TextStyle(color: context.appColors.textPrimary),
            ),
          ),
      ],
      child: Padding(
        padding: EdgeInsets.all(8),
        child: Icon(
          Icons.swap_vert_rounded,
          size: 18,
          color: context.appColors.textSecondary,
        ),
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.search_off,
            size: 44,
            color: context.appColors.textSecondary,
          ),
          SizedBox(height: 12),
          Text(
            'No models match your search',
            style: TextStyle(
              color: context.appColors.textSecondary,
              fontSize: 14,
            ),
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
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: context.appColors.textSecondary,
            ),
            SizedBox(height: 16),
            Text(
              "Couldn't load model pricing",
              style: TextStyle(
                color: context.appColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Check your connection and try again. Data is provided by '
              'models.dev.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.appColors.textSecondary,
                fontSize: 13,
              ),
            ),
            SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh),
              label: Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
