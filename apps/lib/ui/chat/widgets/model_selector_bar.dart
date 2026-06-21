import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/llm_model.dart';
import '../../../domain/models/provider_account.dart';
import '../model_selector_viewmodel.dart';

/// Chat header control: a provider (adapter) picker that expands a second
/// picker listing the models fetched dynamically for that provider.
///
/// Selecting a provider switches the active account and triggers a fresh model
/// fetch; the model picker then lists whatever the provider returned, with the
/// default already chosen from those results (never hardcoded).
class ModelSelectorBar extends ConsumerWidget {
  const ModelSelectorBar({super.key, this.compact = false});

  /// Compact mode (phones): the provider pill collapses to an icon and pills
  /// use tighter padding so the bar fits beside the logo.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ModelSelectorViewModel vm = ref.watch(modelSelectorViewModelProvider);
    return ListenableBuilder(
      listenable: vm,
      builder: (BuildContext context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _ProviderPicker(vm: vm, compact: compact),
            const SizedBox(width: 8),
            Flexible(child: _ModelPicker(vm: vm, compact: compact)),
          ],
        );
      },
    );
  }
}

class _ProviderPicker extends StatelessWidget {
  const _ProviderPicker({required this.vm, required this.compact});

  final ModelSelectorViewModel vm;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final List<ProviderAccount> accounts = vm.accounts;
    return PopupMenuButton<String>(
      tooltip: vm.activeAccount?.displayName ?? 'Provider',
      position: PopupMenuPosition.under,
      color: AppTheme.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: vm.selectProvider,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final ProviderAccount a in accounts)
          // Accounts with no enabled models are rendered disabled (greyed,
          // non-selectable). Because `PopupMenuButton.onSelected` is set at
          // the menu level (not per item), we keep `value` on the item for
          // identification but rely on `enabled: false` to both grey it and
          // block selection — the framework simply doesn't fire `onSelected`
          // for disabled items in a PopupMenu.
          PopupMenuItem<String>(
            value: a.id,
            enabled: a.enabledModels.isNotEmpty,
            child: _MenuRow(
              label: a.displayName,
              selected: a.id == vm.activeAccountId,
              locked: a.enabledModels.isEmpty,
            ),
          ),
      ],
      child: _Chip(
        icon: Icons.account_tree_outlined,
        label: vm.activeAccount?.displayName ?? 'Provider',
        dense: compact,
        hideLabel: compact,
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.vm, required this.compact});

  final ModelSelectorViewModel vm;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (vm.isLoading) {
      return _Chip(
        icon: Icons.bubble_chart_outlined,
        label: compact ? 'Loading…' : 'Loading models…',
        showSpinner: true,
        dense: compact,
      );
    }

    if (vm.error != null) {
      return InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: vm.refresh,
        child: _Chip(
          icon: Icons.error_outline,
          label: 'Retry',
          danger: true,
          dense: compact,
        ),
      );
    }

    final List<LlmModel> models = vm.models;
    if (models.isEmpty) {
      return _Chip(
        icon: Icons.bubble_chart_outlined,
        label: 'No models',
        dense: compact,
      );
    }

    return PopupMenuButton<String>(
      tooltip: 'Model',
      position: PopupMenuPosition.under,
      color: AppTheme.surfaceHigh,
      constraints: const BoxConstraints(maxHeight: 360, minWidth: 220),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: vm.selectModel,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final LlmModel m in models)
          PopupMenuItem<String>(
            value: m.id,
            child: _MenuRow(
              label: m.label,
              selected: m.id == vm.selectedModelId,
            ),
          ),
      ],
      child: _Chip(
        icon: Icons.bubble_chart_outlined,
        label: _selectedLabel(models, vm.selectedModelId),
        dense: compact,
      ),
    );
  }

  String _selectedLabel(List<LlmModel> models, String? selectedId) {
    if (selectedId == null) return 'Select model';
    for (final LlmModel m in models) {
      if (m.id == selectedId) return m.label;
    }
    return selectedId;
  }
}

/// The pill rendered in the app bar for both pickers.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    this.showSpinner = false,
    this.danger = false,
    this.dense = false,
    this.hideLabel = false,
  });

  final IconData icon;
  final String label;
  final bool showSpinner;
  final bool danger;
  final bool dense;

  /// Render just the icon + chevron (used for the provider pill on phones).
  final bool hideLabel;

  @override
  Widget build(BuildContext context) {
    final Color fg = danger ? AppTheme.brandPink : AppTheme.textPrimary;
    final double spinner = dense ? 12 : 14;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 12,
        vertical: dense ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showSpinner)
            SizedBox(
              width: spinner,
              height: spinner,
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, size: 16, color: AppTheme.textSecondary),
          if (!hideLabel) ...<Widget>[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontSize: dense ? 12 : 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const SizedBox(width: 2),
          Icon(Icons.expand_more, size: 16, color: AppTheme.textSecondary),
        ],
      ),
    );
  }
}

/// A row inside a popup menu, with a trailing check on the selected entry and
/// a trailing lock icon when the item is disabled (no models enabled on that
/// provider).
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.label, required this.selected, this.locked = false});

  final String label;
  final bool selected;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final Color fg =
        locked ? AppTheme.textSecondary : AppTheme.textPrimary;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        if (locked)
          const Tooltip(
            message: 'No models enabled for this provider',
            child: Icon(Icons.lock_outline, size: 14, color: AppTheme.textSecondary),
          )
        else if (selected)
          const Icon(Icons.check, size: 16, color: AppTheme.brandBlue),
      ],
    );
  }
}
