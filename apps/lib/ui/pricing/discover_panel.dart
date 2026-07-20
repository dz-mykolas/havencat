import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/widgets/app_scroll_view.dart';
import '../../domain/models/adapter_kind.dart';
import '../../domain/models/model_pricing.dart';
import '../../domain/models/provider_account.dart';
import '../chat/model_selector_viewmodel.dart';
import '../settings/settings_viewmodel.dart';
import '../settings/widgets/account_tile.dart';
import '../settings/widgets/manage_models_sheet.dart';
import '../settings/widgets/provider_picker.dart' show showProviderPicker;
import 'pricing_viewmodel.dart';
import 'pricing_format.dart';
import 'quick_add_resolver.dart';
import 'widgets/custom_endpoint_dialog.dart';
import 'widgets/model_card.dart';
import 'widgets/model_detail_sheet.dart';
import 'widgets/provider_grid.dart';
import 'widgets/quick_add_sheet.dart';

extension on PricingScope {
  String get title => switch (this) {
    PricingScope.models => 'Model catalog',
    PricingScope.providers => 'API providers',
    PricingScope.labs => 'Model labs',
    PricingScope.accounts => 'Your accounts',
  };

  IconData get icon => switch (this) {
    PricingScope.models => Icons.auto_awesome_outlined,
    PricingScope.providers => Icons.dns_outlined,
    PricingScope.labs => Icons.science_outlined,
    PricingScope.accounts => Icons.key_outlined,
  };
}

class DiscoverPanel extends ConsumerStatefulWidget {
  const DiscoverPanel({super.key});

  @override
  ConsumerState<DiscoverPanel> createState() => _DiscoverPanelState();
}

class _DiscoverPanelState extends ConsumerState<DiscoverPanel> {
  final TextEditingController _search = TextEditingController();
  bool _searchExpanded = false;

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
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 680;
        final Widget workspace = _CatalogWorkspace(
          vm: vm,
          searchController: _search,
          searchHint: _searchHint(vm),
          searchExpanded: _searchExpanded,
          onExpandSearch: _expandSearch,
          onCollapseSearch: _collapseSearch,
          onClearSearch: () {
            _search.clear();
            vm.clearQuery();
          },
        );
        return wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    width: 190,
                    child: _CatalogNavigation(
                      vm: vm,
                      onSelected: (PricingScope scope) =>
                          _selectScope(vm, scope),
                    ),
                  ),
                  VerticalDivider(width: 1),
                  Expanded(child: workspace),
                ],
              )
            : Column(
                children: <Widget>[
                  _CompactCatalogNavigation(
                    vm: vm,
                    onSelected: (PricingScope scope) => _selectScope(vm, scope),
                  ),
                  Divider(height: 1),
                  Expanded(child: workspace),
                ],
              );
      },
    );
  }

  void _expandSearch() => setState(() => _searchExpanded = true);

  void _collapseSearch() => setState(() => _searchExpanded = false);

  void _selectScope(PricingViewModel vm, PricingScope scope) {
    vm.setScope(scope);
    if (_searchExpanded) setState(() => _searchExpanded = false);
  }

  String _searchHint(PricingViewModel vm) {
    if (vm.isFlatModelView) return 'Search all models';
    switch (vm.view) {
      case PricingView.overview:
        if (vm.scope == PricingScope.accounts) return 'Search accounts';
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

class _CatalogNavigation extends StatelessWidget {
  const _CatalogNavigation({required this.vm, required this.onSelected});

  final PricingViewModel vm;
  final ValueChanged<PricingScope> onSelected;

  static const List<PricingScope> _catalog = <PricingScope>[
    PricingScope.providers,
    PricingScope.models,
    PricingScope.labs,
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _NavigationLabel('EXPLORE'),
          SizedBox(height: 8),
          for (final PricingScope scope in _catalog) ...<Widget>[
            _CatalogNavigationItem(
              scope: scope,
              selected: vm.scope == scope,
              count: _countFor(scope),
              onTap: () => onSelected(scope),
            ),
            SizedBox(height: 5),
          ],
          Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          _NavigationLabel('MY SETUP'),
          SizedBox(height: 8),
          Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              final int count = ref
                  .watch(settingsViewModelProvider)
                  .accounts
                  .length;
              return _CatalogNavigationItem(
                scope: PricingScope.accounts,
                selected: vm.scope == PricingScope.accounts,
                count: count,
                onTap: () => onSelected(PricingScope.accounts),
              );
            },
          ),
          Spacer(),
          if (vm.fetchedAt != null)
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Catalog updated\n${formatRelative(vm.fetchedAt!)}',
                style: TextStyle(
                  color: context.appColors.textSecondary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  int? _countFor(PricingScope scope) => switch (scope) {
    PricingScope.models => vm.catalog?.models.length,
    PricingScope.providers => vm.catalog?.providers.length,
    PricingScope.labs => vm.catalog?.labs.length,
    PricingScope.accounts => null,
  };
}

class _NavigationLabel extends StatelessWidget {
  const _NavigationLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 9),
      child: Text(
        label,
        style: TextStyle(
          color: context.appColors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _CatalogNavigationItem extends StatelessWidget {
  const _CatalogNavigationItem({
    required this.scope,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final PricingScope scope;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? context.appColors.surface : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          child: Row(
            children: <Widget>[
              Icon(
                scope.icon,
                size: 16,
                color: selected
                    ? context.appColors.brandViolet
                    : context.appColors.textSecondary,
              ),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  scope == PricingScope.accounts ? 'Accounts' : scope.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? context.appColors.textPrimary
                        : context.appColors.textSecondary,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (count != null)
                Text(
                  '$count',
                  style: TextStyle(
                    color: context.appColors.textSecondary,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactCatalogNavigation extends StatelessWidget {
  const _CompactCatalogNavigation({required this.vm, required this.onSelected});

  final PricingViewModel vm;
  final ValueChanged<PricingScope> onSelected;

  static const List<PricingScope> _scopes = <PricingScope>[
    PricingScope.providers,
    PricingScope.models,
    PricingScope.labs,
    PricingScope.accounts,
  ];

  @override
  Widget build(BuildContext context) {
    final int selectedIndex = _scopes.indexOf(vm.scope);
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 6),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double itemWidth = constraints.maxWidth / _scopes.length;
            return SizedBox(
              height: 56,
              child: Stack(
                children: <Widget>[
                  AnimatedPositioned(
                    key: const ValueKey<String>('compact-tab-indicator'),
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    left: itemWidth * selectedIndex,
                    top: 4,
                    bottom: 4,
                    width: itemWidth,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: context.appColors.surface,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: <Widget>[
                      for (final PricingScope scope in _scopes)
                        Expanded(
                          child: _CompactNavigationItem(
                            scope: scope,
                            selected: vm.scope == scope,
                            onTap: () => onSelected(scope),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CompactNavigationItem extends StatelessWidget {
  const _CompactNavigationItem({
    required this.scope,
    required this.selected,
    required this.onTap,
  });

  final PricingScope scope;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 56,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                scope.icon,
                size: 16,
                color: selected
                    ? context.appColors.brandViolet
                    : context.appColors.textSecondary,
              ),
              SizedBox(height: 3),
              Text(
                scope == PricingScope.accounts
                    ? 'Accounts'
                    : scope == PricingScope.providers
                    ? 'Providers'
                    : scope == PricingScope.models
                    ? 'Models'
                    : 'Labs',
                maxLines: 1,
                style: TextStyle(
                  color: selected
                      ? context.appColors.textPrimary
                      : context.appColors.textSecondary,
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CatalogWorkspace extends StatelessWidget {
  const _CatalogWorkspace({
    required this.vm,
    required this.searchController,
    required this.searchHint,
    required this.searchExpanded,
    required this.onExpandSearch,
    required this.onCollapseSearch,
    required this.onClearSearch,
  });

  final PricingViewModel vm;
  final TextEditingController searchController;
  final String searchHint;
  final bool searchExpanded;
  final VoidCallback onExpandSearch;
  final VoidCallback onCollapseSearch;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _WorkspaceToolbar(
          vm: vm,
          searchController: searchController,
          searchHint: searchHint,
          searchExpanded: searchExpanded,
          onExpandSearch: onExpandSearch,
          onCollapseSearch: onCollapseSearch,
          onClearSearch: onClearSearch,
        ),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (vm.scope == PricingScope.accounts) {
      return _AccountsView();
    }
    if (vm.loading) {
      return Center(child: CircularProgressIndicator());
    }
    if (vm.error != null && vm.catalog == null) {
      return _ErrorState(onRetry: vm.load);
    }
    if (vm.isFlatModelView) {
      return _ModelList(
        vm: vm,
        onOpenModel: (PricedModel model) =>
            showModelDetailSheet(context, model),
      );
    }
    if (vm.view == PricingView.overview) {
      return _Overview(vm: vm, onOpenGroup: vm.openProvider);
    }
    return _ModelList(
      vm: vm,
      onOpenModel: (PricedModel model) => showModelDetailSheet(context, model),
    );
  }
}

class _WorkspaceToolbar extends StatelessWidget {
  const _WorkspaceToolbar({
    required this.vm,
    required this.searchController,
    required this.searchHint,
    required this.searchExpanded,
    required this.onExpandSearch,
    required this.onCollapseSearch,
    required this.onClearSearch,
  });

  final PricingViewModel vm;
  final TextEditingController searchController;
  final String searchHint;
  final bool searchExpanded;
  final VoidCallback onExpandSearch;
  final VoidCallback onCollapseSearch;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    final ProviderModels? group = vm.selectedGroup;
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 8, 8, 8),
      child: Row(
        children: <Widget>[
          if (group != null)
            IconButton(
              tooltip: 'Back',
              onPressed: vm.backToOverview,
              icon: Icon(Icons.arrow_back_rounded),
              color: context.appColors.textSecondary,
            )
          else
            SizedBox(width: 6),
          Expanded(
            child: vm.scope == PricingScope.accounts
                ? SizedBox.shrink()
                : _AnimatedSearchControl(
                    controller: searchController,
                    hint: searchHint,
                    expanded: searchExpanded,
                    onExpand: onExpandSearch,
                    onCollapse: onCollapseSearch,
                    onChanged: vm.setQuery,
                    onClear: onClearSearch,
                  ),
          ),
          if (vm.scope == PricingScope.accounts)
            Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                final SettingsViewModel settings = ref.read(
                  settingsViewModelProvider,
                );
                return IconButton.filledTonal(
                  tooltip: 'Add account',
                  onPressed: () => showProviderPicker(context, settings),
                  icon: Icon(Icons.add_rounded),
                );
              },
            )
          else
            _AnimatedRefreshSlot(
              visible: !searchExpanded,
              refreshing: vm.refreshing,
              onRefresh: vm.refresh,
            ),
        ],
      ),
    );
  }
}

class _AnimatedSearchControl extends StatefulWidget {
  const _AnimatedSearchControl({
    required this.controller,
    required this.hint,
    required this.expanded,
    required this.onExpand,
    required this.onCollapse,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String hint;
  final bool expanded;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  State<_AnimatedSearchControl> createState() => _AnimatedSearchControlState();
}

class _AnimatedSearchControlState extends State<_AnimatedSearchControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 240),
    reverseDuration: Duration(milliseconds: 300),
    value: widget.expanded ? 1 : 0,
  );
  final FocusNode _focusNode = FocusNode();

  @override
  void didUpdateWidget(_AnimatedSearchControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    if (widget.expanded) {
      _animation.forward();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.expanded) _focusNode.requestFocus();
      });
    } else {
      _focusNode.unfocus();
      _animation.reverse();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool active = widget.controller.text.isNotEmpty;
    final String collapsedText = active ? widget.controller.text : widget.hint;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double collapsedWidth = constraints.maxWidth < 280
            ? constraints.maxWidth
            : 280;
        return AnimatedBuilder(
          animation: _animation,
          builder: (BuildContext context, Widget? child) {
            final double expansion = Curves.easeOutCubic.transform(
              _animation.value,
            );
            final double width =
                collapsedWidth +
                (constraints.maxWidth - collapsedWidth) * expansion;
            final double fieldOpacity = Interval(
              0.08,
              0.55,
              curve: Curves.easeOutCubic,
            ).transform(_animation.value);
            return Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: width,
                height: 44,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _CollapsedSearchSurface(
                      text: collapsedText,
                      active: active,
                      animation: _animation,
                      onTap: widget.onExpand,
                      ignoring: widget.expanded,
                    ),
                    IgnorePointer(
                      ignoring: !widget.expanded,
                      child: Opacity(
                        opacity: fieldOpacity,
                        child: _SearchField(
                          controller: widget.controller,
                          focusNode: _focusNode,
                          hint: '',
                          onChanged: widget.onChanged,
                          onClear: widget.onClear,
                          onCollapse: widget.onCollapse,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _CollapsedSearchSurface extends StatelessWidget {
  const _CollapsedSearchSurface({
    required this.text,
    required this.active,
    required this.animation,
    required this.onTap,
    required this.ignoring,
  });

  final String text;
  final bool active;
  final Animation<double> animation;
  final VoidCallback onTap;
  final bool ignoring;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: ignoring,
      child: Material(
        color: context.appColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          overlayColor: WidgetStatePropertyAll<Color>(Colors.transparent),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 13),
            child: Row(
              children: <Widget>[
                AnimatedBuilder(
                  animation: animation,
                  builder: (BuildContext context, _) {
                    final bool hiding =
                        animation.status == AnimationStatus.forward ||
                        animation.status == AnimationStatus.completed;
                    final double opacity = hiding
                        ? (animation.value == 0 ? 1 : 0)
                        : 1 -
                              Interval(
                                0,
                                0.25,
                                curve: Curves.easeOutCubic,
                              ).transform(animation.value);
                    return Opacity(
                      opacity: opacity,
                      child: Icon(
                        Icons.search_rounded,
                        size: 19,
                        color: active
                            ? context.appColors.brandViolet
                            : context.appColors.textSecondary,
                      ),
                    );
                  },
                ),
                SizedBox(width: 10),
                Expanded(
                  child: _StaggeredLetterFade(
                    text: text,
                    animation: animation,
                    color: active
                        ? context.appColors.textPrimary
                        : context.appColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StaggeredLetterFade extends StatelessWidget {
  const _StaggeredLetterFade({
    required this.text,
    required this.animation,
    required this.color,
  });

  final String text;
  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final List<String> letters = text.characters.toList();
    return ClipRect(
      child: AnimatedBuilder(
        animation: animation,
        builder: (BuildContext context, _) {
          final int count = letters.isEmpty ? 1 : letters.length;
          return RichText(
            maxLines: 1,
            overflow: TextOverflow.clip,
            text: TextSpan(
              children: <InlineSpan>[
                for (int index = 0; index < letters.length; index++)
                  TextSpan(
                    text: letters[index],
                    style: TextStyle(
                      color: color.withValues(
                        alpha: _letterOpacity(index, count, animation.value),
                      ),
                      fontSize: 13.5,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  double _letterOpacity(int index, int count, double value) {
    if (animation.status == AnimationStatus.forward ||
        animation.status == AnimationStatus.completed) {
      return value == 0 ? 1 : 0;
    }
    final double start = ((count - index - 1) / count) * 0.62;
    final double progress = ((value - start) / 0.20).clamp(0.0, 1.0);
    return 1 - Curves.easeOutCubic.transform(progress);
  }
}

class _AnimatedRefreshSlot extends StatelessWidget {
  const _AnimatedRefreshSlot({
    required this.visible,
    required this.refreshing,
    required this.onRefresh,
  });

  final bool visible;
  final bool refreshing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: visible ? 52 : 0,
      child: ClipRect(
        child: AnimatedOpacity(
          duration: Duration(milliseconds: 120),
          opacity: visible ? 1 : 0,
          child: Align(
            alignment: Alignment.centerRight,
            child: refreshing
                ? Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Refresh catalog',
                    onPressed: onRefresh,
                    icon: Icon(Icons.refresh_rounded),
                    color: context.appColors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.vm, required this.onOpenGroup});

  final PricingViewModel vm;
  final ValueChanged<String> onOpenGroup;

  @override
  Widget build(BuildContext context) {
    final List<ProviderModels> groups = vm.groups;
    final bool isProviders = vm.scope == PricingScope.providers;
    return Column(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, 3),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${groups.length} ${isProviders ? "providers" : "labs"}',
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
          child: ProviderGrid(
            providers: groups,
            onTap: onOpenGroup,
            // The custom-endpoint affordance only makes sense on the
            // Providers tab — Labs are orgs, not user-configurable endpoints.
            showCustomCard: isProviders,
            onAddCustom: () => _openCustomEndpoint(context),
          ),
        ),
      ],
    );
  }

  void _openCustomEndpoint(BuildContext context) {
    final SettingsViewModel settings = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(settingsViewModelProvider);
    showCustomEndpointDialog(context, settings);
  }
}

class _ModelList extends StatefulWidget {
  const _ModelList({required this.vm, required this.onOpenModel});

  final PricingViewModel vm;
  final ValueChanged<PricedModel> onOpenModel;

  @override
  State<_ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<_ModelList> {
  bool _filtersExpanded = false;

  @override
  Widget build(BuildContext context) {
    final PricingViewModel vm = widget.vm;
    final List<PricedModel> results = vm.results;
    final ProviderModels? selectedGroup = vm.selectedGroup;
    // Show the Quick Add CTA only in the Providers-scope drill-in. The
    // resolver returns one of:
    //   - Supported  -> enabled button, opens Quick Add
    //   - Uncertain  -> disabled button with a tooltip (recognised package but
    //                  models.dev doesn't give us enough to route safely)
    //   - Unsupported -> no button (labs scope, unknown npm)
    final ResolveResult? quickAdd =
        (vm.scope == PricingScope.providers &&
            vm.view == PricingView.provider &&
            selectedGroup != null)
        ? resolveDefinitionFor(selectedGroup)
        : null;
    return Column(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 6, 4),
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
              if (selectedGroup != null && quickAdd != null)
                _AddApiKeyButton(
                  label: selectedGroup.name,
                  result: quickAdd,
                  onTap: () {
                    final SettingsViewModel settings =
                        ProviderScope.containerOf(
                          context,
                          listen: false,
                        ).read(settingsViewModelProvider);
                    showQuickAdd(
                      context,
                      settings,
                      selectedGroup,
                      (quickAdd as Supported).definition,
                    );
                  },
                ),
              IconButton(
                tooltip: _filtersExpanded ? 'Hide filters' : 'Filter models',
                onPressed: () =>
                    setState(() => _filtersExpanded = !_filtersExpanded),
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Icon(Icons.filter_list_rounded, size: 19),
                    if (vm.filters.isNotEmpty)
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: context.appColors.brandViolet,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
                color: _filtersExpanded
                    ? context.appColors.brandViolet
                    : context.appColors.textSecondary,
              ),
              _SortButton(sort: vm.sort, onSelected: vm.setSort),
            ],
          ),
        ),
        AnimatedSize(
          duration: Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _filtersExpanded ? _FilterChipsRow(vm: vm) : SizedBox.shrink(),
        ),
        Expanded(
          child: results.isEmpty
              ? _NoResults()
              : _ResultsGrid(results: results, onTap: widget.onOpenModel),
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
      return SizedBox.shrink();
    }
    final bool any = vm.filters.isNotEmpty;
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(12, 2, 12, 4),
        children: <Widget>[
          for (final PricingFilter f in PricingFilter.values)
            Padding(
              padding: EdgeInsets.only(right: 6),
              child: _FilterChip(
                filter: f,
                selected: vm.filters.contains(f),
                onTap: () => vm.toggleFilter(f),
              ),
            ),
          if (any)
            _FilterIconButton(
              icon: Icons.filter_alt_off_outlined,
              tooltip: 'Clear filters',
              onTap: vm.clearFilters,
            ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.filter,
    required this.selected,
    required this.onTap,
  });

  final PricingFilter filter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: filter.label,
      child: Material(
        color: selected
            ? context.appColors.brandViolet
            : context.appColors.surface,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(
              _iconFor(filter),
              size: 15,
              color: selected
                  ? Theme.of(context).colorScheme.onPrimary
                  : context.appColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(PricingFilter filter) => switch (filter) {
    PricingFilter.reasoning => Icons.psychology_outlined,
    PricingFilter.nonReasoning => Icons.text_fields_rounded,
    PricingFilter.vision => Icons.image_outlined,
    PricingFilter.openWeights => Icons.lock_open_outlined,
    PricingFilter.free => Icons.money_off_csred_outlined,
  };
}

class _FilterIconButton extends StatelessWidget {
  const _FilterIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(icon, size: 15, color: context.appColors.textSecondary),
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

/// "Add API key" CTA in the model list header. Opens the Quick Add flow for
/// the currently drilled-in provider.
///
/// Renders enabled when [result] is [Supported]; grayed out and non-tappable
/// when [Uncertain] (with a tooltip explaining why and linking the provider's
/// docs).
class _AddApiKeyButton extends StatelessWidget {
  const _AddApiKeyButton({
    required this.label,
    required this.result,
    required this.onTap,
  });

  final String label;
  final ResolveResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ResolveResult r = result;
    final bool enabled = r is Supported;
    String? tooltip;
    String? docsUrl;
    if (r is Uncertain) {
      tooltip = r.reason;
      docsUrl = r.docsUrl;
    }
    return Tooltip(
      message: tooltip ?? '',
      waitDuration: Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: enabled
                ? context.appColors.brandViolet.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                docsUrl != null ? Icons.help_outline : Icons.vpn_key_outlined,
                size: 14,
                color: enabled
                    ? context.appColors.brandViolet
                    : context.appColors.textSecondary,
              ),
              SizedBox(width: 6),
              Text(
                enabled ? 'Add API key' : 'Add API key',
                style: TextStyle(
                  color: enabled
                      ? context.appColors.brandViolet
                      : context.appColors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
    required this.onClear,
    this.onCollapse,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: (_) => onCollapse?.call(),
      onTapOutside: (_) {
        FocusManager.instance.primaryFocus?.unfocus();
        onCollapse?.call();
      },
      style: TextStyle(color: context.appColors.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: context.appColors.textSecondary),
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
        padding: EdgeInsets.all(10),
        child: Icon(
          Icons.swap_vert_rounded,
          size: 19,
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
              "Couldn't load model catalog",
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

/// The Accounts tab body: lists configured accounts (reusing [AccountTile]
/// from settings), with an "Add account" affordance at the bottom that opens
/// the provider picker (subscriptions + API keys + custom endpoint).
///
/// This is the same data the Settings screen used to show in its "Accounts"
/// section, now consolidated into Discover so all account management lives
/// in one place.
class _AccountsView extends StatelessWidget {
  const _AccountsView();

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (BuildContext context, WidgetRef ref, _) {
        final SettingsViewModel settings = ref.watch(settingsViewModelProvider);
        final List<ProviderAccount> accounts = settings.accounts;
        if (accounts.isEmpty) {
          return _EmptyAccounts(onAdd: () => _addAccount(context, settings));
        }
        return AppScrollView(
          builder: (BuildContext context, AppScrollController controller) =>
              ListView(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, 2, 12, 12),
                children: <Widget>[
                  Material(
                    color: context.appColors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: <Widget>[
                        for (
                          int index = 0;
                          index < accounts.length;
                          index++
                        ) ...[
                          AccountTile(
                            account: accounts[index],
                            onDelete: () => _confirmDelete(
                              context,
                              settings,
                              accounts[index],
                            ),
                            onManageModels:
                                accounts[index].kind == AdapterKind.mock
                                ? null
                                : () {
                                    final ModelSelectorViewModel selector =
                                        ProviderScope.containerOf(
                                          context,
                                          listen: false,
                                        ).read(modelSelectorViewModelProvider);
                                    showManageModels(
                                      context,
                                      settings,
                                      selector,
                                      accounts[index],
                                    );
                                  },
                          ),
                          if (index != accounts.length - 1) SizedBox(height: 2),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
        );
      },
    );
  }

  void _addAccount(BuildContext context, SettingsViewModel settings) {
    showProviderPicker(context, settings);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    SettingsViewModel settings,
    ProviderAccount account,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Remove account?'),
          content: Text(
            'Remove "${account.displayName}" and its stored API key? '
            'This cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Remove'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await settings.remove(account.id);
    }
  }
}

class _EmptyAccounts extends StatelessWidget {
  const _EmptyAccounts({required this.onAdd});

  final VoidCallback onAdd;

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
              'No provider accounts yet',
              style: TextStyle(
                color: context.appColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Add an API key or sign in to start chatting.',
              style: TextStyle(
                color: context.appColors.textSecondary,
                fontSize: 14,
              ),
            ),
            SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: Icon(Icons.add),
              label: Text('Add account'),
            ),
          ],
        ),
      ),
    );
  }
}
