import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/llm_model.dart';
import '../../../domain/models/provider_account.dart';
import '../model_selector_viewmodel.dart';
import 'model_selector_panel.dart';

/// A single chip in the app bar that opens a two-column provider/model picker.
///
/// On wide screens it opens a centered [Dialog]; on narrow screens it opens a
/// bottom [Drawer]. Both host the same [ModelSelectorPanel].
class ModelSelectorBar extends ConsumerWidget {
  const ModelSelectorBar({super.key, this.compact = false});

  /// Compact mode (phones): the chip collapses to an icon so it fits beside
  /// the logo.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ModelSelectorViewModel vm = ref.watch(modelSelectorViewModelProvider);
    final String label = _label(vm);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _open(context, vm),
      child: _Chip(
        icon: Icons.bubble_chart_outlined,
        label: label,
        dense: compact,
        hideLabel: compact,
      ),
    );
  }

  String _label(ModelSelectorViewModel vm) {
    final ProviderAccount? account = vm.activeAccount;
    if (account == null) return 'Select model';
    final String? modelId = vm.selectedModelId;
    if (modelId == null) return account.displayName;
    final List<LlmModel>? models = vm.models;
    if (models == null) return account.displayName;
    for (final LlmModel m in models) {
      if (m.id == modelId) return '${account.displayName} · ${m.label}';
    }
    return account.displayName;
  }

  void _open(BuildContext context, ModelSelectorViewModel vm) {
    final bool wide =
        MediaQuery.of(context).size.width >= AppTheme.wideBreakpoint;
    if (wide) {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) {
          return Dialog(
            backgroundColor: AppTheme.surface,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: SizedBox(
              width: 560,
              height: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                    child: Row(
                      children: <Widget>[
                        const Text(
                          'Select model',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: vm,
                      builder: (BuildContext context, _) {
                        return ModelSelectorPanel(vm: vm);
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } else {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppTheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
          ),
        ),
        builder: (BuildContext context) {
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                  child: Row(
                    children: <Widget>[
                      const Text(
                        'Select model',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListenableBuilder(
                    listenable: vm,
                    builder: (BuildContext context, _) {
                      return ModelSelectorPanel(vm: vm);
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
  }
}

/// The pill rendered in the app bar.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    this.dense = false,
    this.hideLabel = false,
  });

  final IconData icon;
  final String label;
  final bool dense;
  final bool hideLabel;

  @override
  Widget build(BuildContext context) {
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
          Icon(icon, size: 16, color: AppTheme.textSecondary),
          if (!hideLabel) ...<Widget>[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textPrimary,
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
