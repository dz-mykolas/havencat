import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../../domain/models/model_pricing.dart';
import '../../domain/models/provider_definition.dart';
import '../settings/settings_viewmodel.dart';
import 'pricing_viewmodel.dart';
import 'pricing_format.dart';
import 'quick_add_resolver.dart';
import 'widgets/model_card.dart';
import 'widgets/model_detail_sheet.dart';
import 'widgets/provider_grid.dart';
import 'widgets/quick_add_sheet.dart';

/// Three-tab Discover panel embedded in Settings: **Labs** (the orgs that
/// own each model), **Models** (every model flat, formerly "Browse all"), and
/// **Providers** (hosting APIs).
///
/// All three tabs share the same cached models.dev catalog via
/// [PricingViewModel] and the same drill-in model list; the difference is the
/// top-level grouping. Each tab keeps its own search query (so "gpt" on Models
/// and "open" on Providers don't clobber each other), and the search bar is
/// always visible — on the groups grid it filters groups by name, on the model
/// list it filters models.
///
/// Tabs switch with an animated [AnimatedSwitcher]; the groups grid fades/
/// slides in. Layout is responsive: on wide screens the content is centered to
/// [AppTheme.panelMaxWidth]; tabs render as a segmented control with a
/// sliding selection indicator.
class DiscoverPanel extends ConsumerStatefulWidget {
  const DiscoverPanel({super.key});

  @override
  ConsumerState<DiscoverPanel> createState() => _DiscoverPanelState();
}

class _DiscoverPanelState extends ConsumerState<DiscoverPanel> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Sync the search field with the active scope's query whenever the scope
  /// (or its query) changes from outside the field (tab switch, clear button).
  /// Guarded so typing in the field doesn't reset the cursor mid-keystroke.
  void _syncSearchField(String query) {
    if (_search.text != query) {
      // preserveSelection keeps the caret from jumping to the start when the
      // field is focused and the VM pushes back the same text.
      _search.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final PricingViewModel vm = ref.watch(pricingViewModelProvider);
    _syncSearchField(vm.query);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppTheme.panelMaxWidth),
      child: ListenableBuilder(
        listenable: vm,
        builder: (BuildContext context, _) {
          if (vm.loading) {
            return const _PanelShell(
              tabs: _ScopeTabs(),
              search: SizedBox.shrink(),
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (vm.error != null && vm.catalog == null) {
            return _PanelShell(
              tabs: const _ScopeTabs(),
              search: const SizedBox.shrink(),
              body: _ErrorState(onRetry: vm.load),
            );
          }
          return _PanelShell(
            tabs: const _ScopeTabs(),
            search: _SearchField(
              controller: _search,
              hint: _searchHint(vm),
              onChanged: vm.setQuery,
              onClear: () {
                _search.clear();
                vm.clearQuery();
              },
            ),
            body: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.linear,
              // Only render the incoming child; the old tab's content is
              // dropped instantly so you never see two grids stacked.
              layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                return currentChild ?? const SizedBox.shrink();
              },
              // Only animate the incoming child; the outgoing tab content just
              // disappears — fading it out only delays the new tab's reveal.
              transitionBuilder: (Widget child, Animation<double> a) {
                if (a.status == AnimationStatus.reverse) return child;
                return FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(0, 0.04),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: a,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                    child: child,
                  ),
                );
              },
              child: vm.isFlatModelView
                  ? _ModelList(
                      vm: vm,
                      onOpenModel: (PricedModel m) =>
                          showModelDetailSheet(context, m),
                      key: const ValueKey<String>('models'),
                    )
                  : vm.view == PricingView.overview
                  ? _Overview(
                      vm: vm,
                      onOpenGroup: vm.openProvider,
                      key: ValueKey<String>('overview:${vm.scope}'),
                    )
                  : _ModelList(
                      vm: vm,
                      onOpenModel: (PricedModel m) =>
                          showModelDetailSheet(context, m),
                      key: ValueKey<String>('list:${vm.scope}'),
                    ),
            ),
          );
        },
      ),
    );
  }

  String _searchHint(PricingViewModel vm) {
    if (vm.isFlatModelView) return 'Search all models';
    switch (vm.view) {
      case PricingView.overview:
        final String what = vm.scope == PricingScope.providers
            ? 'providers'
            : 'labs';
        return 'Search $what';
      case PricingView.provider:
        return 'Search in ${vm.selectedGroup?.name ?? "this group"}';
      case PricingView.all:
        return 'Search all models';
    }
  }
}

/// Header tabs + always-visible search + body.
class _PanelShell extends StatelessWidget {
  const _PanelShell({
    required this.tabs,
    required this.search,
    required this.body,
  });

  final Widget tabs;
  final Widget search;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: tabs),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: search,
        ),
        Expanded(child: body),
      ],
    );
  }
}

/// Segmented "Labs / Models / Providers" tab control with a sliding brand-
/// gradient indicator behind the selected label. Reads the current scope from
/// the view model and calls [PricingViewModel.setScope] on tap.
class _ScopeTabs extends StatelessWidget {
  const _ScopeTabs();

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (BuildContext context, WidgetRef ref, _) {
        final PricingViewModel vm = ref.watch(pricingViewModelProvider);
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.outline),
          ),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double tabWidth = (c.maxWidth - 8) / 3;
              final int index = vm.scope.index;
              return Stack(
                children: <Widget>[
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    left: 4 + tabWidth * index,
                    top: 0,
                    bottom: 0,
                    width: tabWidth,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 2),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: AppTheme.brandGradient,
                          borderRadius: BorderRadius.all(Radius.circular(10)),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _TabLabel(
                          label: 'Labs',
                          selected: vm.scope == PricingScope.labs,
                          onTap: () => vm.setScope(PricingScope.labs),
                        ),
                      ),
                      Expanded(
                        child: _TabLabel(
                          label: 'Models',
                          selected: vm.scope == PricingScope.models,
                          onTap: () => vm.setScope(PricingScope.models),
                        ),
                      ),
                      Expanded(
                        child: _TabLabel(
                          label: 'Providers',
                          selected: vm.scope == PricingScope.providers,
                          onTap: () => vm.setScope(PricingScope.providers),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            color: selected ? Colors.white : AppTheme.textSecondary,
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
          child: Center(child: Text(label)),
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.vm, required this.onOpenGroup, super.key});

  final PricingViewModel vm;
  final ValueChanged<String> onOpenGroup;

  @override
  Widget build(BuildContext context) {
    final List<ProviderModels> groups = vm.groups;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${groups.length} '
                  '${vm.scope == PricingScope.providers ? "providers" : "labs"}'
                  '${vm.fetchedAt != null ? ' · updated ${formatRelative(vm.fetchedAt!)}' : ''}',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
              if (vm.view == PricingView.provider)
                _BackToOverviewButton(onTap: vm.backToOverview),
            ],
          ),
        ),
        Expanded(
          child: ProviderGrid(providers: groups, onTap: onOpenGroup),
        ),
      ],
    );
  }
}

class _ModelList extends StatelessWidget {
  const _ModelList({required this.vm, required this.onOpenModel, super.key});

  final PricingViewModel vm;
  final ValueChanged<PricedModel> onOpenModel;

  @override
  Widget build(BuildContext context) {
    final List<PricedModel> results = vm.results;
    final ProviderModels? selectedGroup = vm.selectedGroup;
    // Show the Quick Add CTA only in the Providers-scope drill-in, and only
    // when the resolver found an adapter for this group (null = no Add button,
    // e.g. labs scope or any group without a known API adapter).
    final ProviderDefinition? quickAddDef =
        (vm.scope == PricingScope.providers &&
            vm.view == PricingView.provider &&
            selectedGroup != null)
        ? resolveDefinitionFor(selectedGroup)
        : null;
    return Column(
      children: <Widget>[
        _FilterChipsRow(vm: vm),
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
              if (quickAddDef != null && selectedGroup != null)
                _AddApiKeyButton(
                  label: selectedGroup.name,
                  onTap: () {
                    final SettingsViewModel settings =
                        ProviderScope.containerOf(
                          context,
                          listen: false,
                        ).read(settingsViewModelProvider);
                    showQuickAdd(context, settings, selectedGroup, quickAddDef);
                  },
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
    if (vm.isFlatModelView) {
      if (vm.query.trim().isEmpty && vm.filters.isEmpty) {
        return '${vm.totalCount} models';
      }
      return '$shown matches';
    }
    if (vm.query.trim().isEmpty && vm.filters.isEmpty) {
      final int total = vm.view == PricingView.provider
          ? (vm.selectedGroup?.models.length ?? 0)
          : vm.totalCount;
      return '$total models';
    }
    return '$shown matches';
  }
}

/// Horizontally-scrolling row of capability filter chips plus a "clear" affordance.
class _FilterChipsRow extends StatelessWidget {
  const _FilterChipsRow({required this.vm});

  final PricingViewModel vm;

  @override
  Widget build(BuildContext context) {
    // Filters apply to the model list only: hide on the groups grid overview,
    // and on the models tab they always apply (it's always a model list).
    if (!vm.isFlatModelView && vm.view == PricingView.overview) {
      return const SizedBox.shrink();
    }
    final bool any = vm.filters.isNotEmpty;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        children: <Widget>[
          for (final PricingFilter f in PricingFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _FilterChip(
                label: f.label,
                selected: vm.filters.contains(f),
                onTap: () => vm.toggleFilter(f),
              ),
            ),
          if (any)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _FilterChip(
                label: 'Clear',
                selected: false,
                subtle: true,
                onTap: vm.clearFilters,
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtle = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool subtle;

  @override
  Widget build(BuildContext context) {
    final Color bg = selected
        ? AppTheme.brandViolet
        : (subtle ? Colors.transparent : AppTheme.surface);
    final Color fg = selected
        ? Colors.white
        : (subtle ? AppTheme.textSecondary : AppTheme.textPrimary);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? Colors.transparent : AppTheme.outline,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Responsive card grid: a lazy two-up grid on wide layouts, single column on
/// narrow ones. Reused for both the Provider and Lab model lists.
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
                    child: ModelCard(model: model, onTap: () => onTap(model)),
                  ),
                );
              } else {
                cells.add(const Expanded(child: SizedBox.shrink()));
              }
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: cells,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// "Add API key" CTA in the model list header. Opens the Quick Add flow for
/// the currently drilled-in provider.
class _AddApiKeyButton extends StatelessWidget {
  const _AddApiKeyButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: AppTheme.brandGradient,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.vpn_key_outlined, size: 14, color: Colors.white),
            SizedBox(width: 6),
            Text(
              'Add API key',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Back to overview" affordance, shown in the header row when drilled into a
/// single group (so the user can return to the groups grid).
class _BackToOverviewButton extends StatelessWidget {
  const _BackToOverviewButton({required this.onTap});

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
            Icon(Icons.arrow_back, size: 16, color: AppTheme.textSecondary),
            SizedBox(width: 6),
            Text(
              'Back',
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
              "Couldn't load model catalog",
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
