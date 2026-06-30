import 'package:flutter/material.dart';

import '../../../domain/models/llm_model.dart';
import '../../../domain/models/provider_account.dart';
import '../../chat/model_selector_viewmodel.dart';
import '../../core/theme/app_theme.dart';
import '../settings_viewmodel.dart';

/// Opens the Manage Models flow for [account]: a scrollable list of every
/// model the provider currently serves plus any enabled-but-no-longer-served
/// (deprecated) entries, each with a checkbox bound to the account's
/// `enabledModels`. New models get a 🆕 badge, deprecated ones get ⚠️.
///
/// On submit, calls [SettingsViewModel.setAllowedModels] with the checked
/// ids and acknowledges the new ones via [ModelSelectorViewModel.acknowledgeNewModels]
/// so the chat picker's "+N new" badge clears.
///
/// Picks dialog vs drawer by viewport width, mirroring [showQuickAdd]:
///   * wide (>= [AppTheme.wideBreakpoint]): a centered [Dialog],
///   * narrow: a drag-handle [showModalBottomSheet].
Future<void> showManageModels(
  BuildContext context,
  SettingsViewModel settings,
  ModelSelectorViewModel selector,
  ProviderAccount account,
) async {
  final bool wide = MediaQuery.sizeOf(context).width >= AppTheme.wideBreakpoint;
  if (wide) {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => Dialog(
        backgroundColor: AppTheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: _ManageModelsContent(
              account: account,
              selector: selector,
              onSubmit: (List<String> ids) =>
                  settings.setAllowedModels(account.id, ids),
              onDone: () => Navigator.of(ctx).maybePop(),
            ),
          ),
        ),
      ),
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (BuildContext ctx) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: _ManageModelsContent(
            account: account,
            selector: selector,
            onSubmit: (List<String> ids) =>
                settings.setAllowedModels(account.id, ids),
            onDone: () => Navigator.of(ctx).maybePop(),
          ),
        ),
      );
    },
  );
}

class _ManageModelsContent extends StatefulWidget {
  const _ManageModelsContent({
    required this.account,
    required this.selector,
    required this.onSubmit,
    required this.onDone,
  });

  final ProviderAccount account;
  final ModelSelectorViewModel selector;

  /// Persists the new enabled-models list. Throws on failure; the caller shows
  /// the error inline rather than dismissing the sheet.
  final Future<void> Function(List<String> ids) onSubmit;

  /// Called after a successful submit; dismisses the dialog/drawer.
  final VoidCallback onDone;

  @override
  State<_ManageModelsContent> createState() => _ManageModelsContentState();
}

class _ManageModelsContentState extends State<_ManageModelsContent> {
  /// Hard cap on enabled models per account. See quick_add_sheet.dart's
  /// `_QuickAddContentState.maxEnabled` for rationale.
  static const int maxEnabled = 50;

  late Set<String> _selected;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = widget.account.enabledModels.toSet();
  }

  bool get _atCap => _selected.length >= maxEnabled;

  bool get _canSubmit => !_saving && _selected.isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_selected.toList(growable: false));
      // Acknowledge every available model so the "+N new" badge clears — the
      // user has now seen the full list.
      await widget.selector.acknowledgeNewModels();
      widget.onDone();
    } catch (error) {
      setState(() {
        _error = 'Failed to save: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<LlmModel>? available = widget.selector.availableModels;
    final Set<String> newIds = widget.selector.newModelIds;
    final Set<String> deprecatedIds = widget.selector.deprecatedModelIds;

    // Build the row list: every available model, plus any enabled-but-
    // deprecated ids that are no longer in `available` (so the user can
    // review/uncheck them).
    final List<_ModelRow> rows = <_ModelRow>[];
    if (available != null) {
      for (final LlmModel m in available) {
        rows.add(
          _ModelRow(
            id: m.id,
            label: m.label,
            isNew: newIds.contains(m.id),
            deprecated: false,
          ),
        );
      }
    }
    for (final String id in deprecatedIds) {
      if (rows.any((_ModelRow r) => r.id == id)) continue;
      rows.add(_ModelRow(id: id, label: id, isNew: false, deprecated: true));
    }
    rows.sort((_ModelRow a, _ModelRow b) {
      // Deprecated last, then alphabetical.
      if (a.deprecated != b.deprecated) return a.deprecated ? 1 : -1;
      return a.label.compareTo(b.label);
    });

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Manage models · ${widget.account.displayName}',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: widget.onDone,
                tooltip: 'Close',
              ),
            ],
          ),
        ),
        if (available == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No models available. Check the provider connection.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _selected.isEmpty
                              ? 'Pick at least one model (${rows.length} available)'
                              : '${_selected.length}/${rows.length} enabled'
                                    '${_atCap ? ' · cap $maxEnabled' : ''}',
                          style: TextStyle(
                            color: _selected.isEmpty
                                ? AppTheme.brandPink
                                : AppTheme.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: _saving
                            ? null
                            : () {
                                setState(() {
                                  if (_selected.length == rows.length) {
                                    _selected.clear();
                                  } else {
                                    _selected
                                      ..clear()
                                      ..addAll(
                                        rows
                                            .take(maxEnabled)
                                            .map((_ModelRow r) => r.id),
                                      );
                                  }
                                });
                              },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(
                            'Select all',
                            style: TextStyle(
                              color: AppTheme.brandBlue,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (BuildContext _, _) =>
                        const Divider(height: 1, color: AppTheme.outline),
                    itemBuilder: (BuildContext context, int index) {
                      final _ModelRow r = rows[index];
                      final bool on = _selected.contains(r.id);
                      final bool lockedOff = !on && _atCap;
                      return InkWell(
                        onTap: _saving || lockedOff
                            ? null
                            : () {
                                setState(() {
                                  if (on) {
                                    _selected.remove(r.id);
                                  } else {
                                    _selected.add(r.id);
                                  }
                                });
                              },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 4,
                          ),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                on
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank,
                                size: 18,
                                color: on
                                    ? AppTheme.brandViolet
                                    : AppTheme.textSecondary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  r.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: r.deprecated
                                        ? AppTheme.textSecondary
                                        : AppTheme.textPrimary,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (r.isNew)
                                const _Badge(
                                  icon: Icons.fiber_new,
                                  label: 'New',
                                  color: AppTheme.brandBlue,
                                ),
                              if (r.deprecated)
                                const _Badge(
                                  icon: Icons.warning_amber,
                                  label: 'Deprecated',
                                  color: AppTheme.brandPink,
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: const TextStyle(color: AppTheme.brandPink, fontSize: 12.5),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            TextButton(
              onPressed: _saving ? null : widget.onDone,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ModelRow {
  const _ModelRow({
    required this.id,
    required this.label,
    required this.isNew,
    required this.deprecated,
  });

  final String id;
  final String label;
  final bool isNew;
  final bool deprecated;
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
