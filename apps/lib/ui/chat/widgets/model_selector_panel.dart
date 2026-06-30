import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/llm_model.dart';
import '../../../domain/models/provider_account.dart';
import '../model_selector_viewmodel.dart';

/// Two-column model selector: providers on the left, models for the active
/// provider on the right. Used both inside a desktop [Dialog] and a mobile
/// [Drawer] — the host decides the chrome, this widget just renders the
/// columns.
///
/// Receives the [vm] from its host (the [ModelSelectorBar]) so it doesn't
/// depend on `ref.watch` — that way it rebuilds reliably inside a `Dialog`
/// or `Drawer` via the parent's `ListenableBuilder`.
class ModelSelectorPanel extends StatelessWidget {
  const ModelSelectorPanel({super.key, required this.vm});

  final ModelSelectorViewModel vm;

  @override
  Widget build(BuildContext context) {
    final List<ProviderAccount> accounts = vm.accounts;
    final String? activeAccountId = vm.activeAccountId;
    final List<LlmModel>? models = vm.models;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: _ProviderColumn(
            vm: vm,
            accounts: accounts,
            activeId: activeAccountId,
            onSelect: vm.selectProvider,
          ),
        ),
        Container(width: 1, color: AppTheme.outline),
        Expanded(
          child: _ModelColumn(vm: vm, models: models),
        ),
      ],
    );
  }
}

class _ProviderColumn extends StatelessWidget {
  const _ProviderColumn({
    required this.vm,
    required this.accounts,
    required this.activeId,
    required this.onSelect,
  });

  final ModelSelectorViewModel vm;
  final List<ProviderAccount> accounts;
  final String? activeId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return const Center(
        child: Text(
          'No providers configured',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: accounts.length,
      itemBuilder: (BuildContext context, int index) {
        final ProviderAccount a = accounts[index];
        final bool selected = a.id == activeId;
        final bool locked = a.enabledModels.isEmpty;
        return ListTile(
          dense: true,
          selected: selected,
          enabled: !locked,
          leading: Icon(
            Icons.account_tree_outlined,
            size: 18,
            color: selected ? AppTheme.brandBlue : AppTheme.textSecondary,
          ),
          title: Text(
            a.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: locked ? AppTheme.textSecondary : AppTheme.textPrimary,
            ),
          ),
          trailing: locked
              ? const Tooltip(
                  message: 'No models enabled',
                  child: Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: AppTheme.textSecondary,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (vm.newCountFor(a.id) > 0)
                      _NewCountBadge(count: vm.newCountFor(a.id)),
                    if (selected)
                      const Icon(
                        Icons.check,
                        size: 16,
                        color: AppTheme.brandBlue,
                      ),
                  ],
                ),
          onTap: locked ? null : () => onSelect(a.id),
        );
      },
    );
  }
}

class _ModelColumn extends StatelessWidget {
  const _ModelColumn({required this.vm, required this.models});

  final ModelSelectorViewModel vm;
  final List<LlmModel>? models;

  @override
  Widget build(BuildContext context) {
    if (vm.isLoading || models == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (vm.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, color: AppTheme.brandPink),
            const SizedBox(height: 8),
            TextButton(onPressed: vm.refresh, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (models == null || models!.isEmpty) {
      return const Center(
        child: Text(
          'No models',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: models!.length,
      itemBuilder: (BuildContext context, int index) {
        final LlmModel m = models![index];
        final bool selected = m.id == vm.selectedModelId;
        return ListTile(
          dense: true,
          selected: selected,
          leading: Icon(
            Icons.bubble_chart_outlined,
            size: 18,
            color: selected ? AppTheme.brandBlue : AppTheme.textSecondary,
          ),
          title: Text(
            m.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          trailing: selected
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (vm.isSelectedModelDeprecated)
                      const Tooltip(
                        message: 'Provider no longer lists this model',
                        child: Icon(
                          Icons.warning_amber,
                          size: 14,
                          color: AppTheme.brandPink,
                        ),
                      ),
                    const Icon(Icons.check, size: 16, color: AppTheme.brandBlue),
                  ],
                )
              : null,
          onTap: () => vm.selectModel(m.id),
        );
      },
    );
  }
}

/// Small "+N new" pill shown next to a provider in the chat picker when the
/// provider has added models the user hasn't acknowledged yet. Tapping the
/// provider row opens the picker (which calls acknowledgeNewModels), clearing
/// the badge on next open.
class _NewCountBadge extends StatelessWidget {
  const _NewCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.brandBlue.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.brandBlue.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.fiber_new,
            size: 11,
            color: AppTheme.brandBlue,
          ),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: const TextStyle(
              color: AppTheme.brandBlue,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
