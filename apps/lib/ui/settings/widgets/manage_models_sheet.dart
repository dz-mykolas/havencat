import 'package:flutter/material.dart';

import '../../../domain/models/llm_model.dart';
import '../../../domain/models/provider_account.dart';
import '../../chat/model_selector_viewmodel.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';
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
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, maxHeight: 680),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 16),
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
    builder: (BuildContext ctx) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
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
      // user has now seen the full list. Scope the acknowledgement to the
      // tapped account (which may differ from the active one).
      await widget.selector.acknowledgeNewModelsFor(widget.account.id);
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
    final String accountId = widget.account.id;
    final List<LlmModel>? available = widget.selector.availableModelsFor(
      accountId,
    );
    final Set<String> newIds = widget.selector.newModelIdsFor(accountId);
    final Set<String> deprecatedIds = widget.selector.deprecatedModelIdsFor(
      accountId,
    );

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
    final List<String> selectableIds = rows
        .take(maxEnabled)
        .map((_ModelRow row) => row.id)
        .toList(growable: false);
    final bool allSelected =
        selectableIds.isNotEmpty && selectableIds.every(_selected.contains);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Manage models · ${widget.account.displayName}',
                  style: TextStyle(
                    color: context.appColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, size: 20),
                onPressed: widget.onDone,
                tooltip: 'Close',
              ),
            ],
          ),
        ),
        if (available == null)
          Padding(
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
          Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No models available. Check the provider connection.',
                style: TextStyle(
                  color: context.appColors.textSecondary,
                  fontSize: 13,
                ),
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
                  padding: EdgeInsets.symmetric(vertical: 4),
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
                                ? context.appColors.brandPink
                                : context.appColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: allSelected ? 'Unselect all' : 'Select all',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(7),
                          onTap: _saving
                              ? null
                              : () {
                                  setState(() {
                                    if (allSelected) {
                                      _selected.clear();
                                    } else {
                                      _selected
                                        ..clear()
                                        ..addAll(selectableIds);
                                    }
                                  });
                                },
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: Icon(
                              allSelected
                                  ? Icons.deselect_rounded
                                  : Icons.select_all_rounded,
                              size: 17,
                              color: context.appColors.brandBlue,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 360),
                  child: AppScrollView(
                    builder:
                        (
                          BuildContext context,
                          AppScrollController controller,
                        ) => ListView.separated(
                          controller: controller,
                          shrinkWrap: true,
                          itemCount: rows.length,
                          separatorBuilder: (BuildContext _, _) => Divider(
                            height: 1,
                            color: context.appColors.divider,
                          ),
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
                                padding: EdgeInsets.symmetric(
                                  vertical: 6,
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
                                          ? context.appColors.brandViolet
                                          : context.appColors.textSecondary,
                                    ),
                                    SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        r.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: r.deprecated
                                              ? context.appColors.textSecondary
                                              : context.appColors.textPrimary,
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    if (r.isNew)
                                      _Badge(
                                        icon: Icons.fiber_new,
                                        label: 'New',
                                        color: context.appColors.brandBlue,
                                      ),
                                    if (r.deprecated)
                                      _Badge(
                                        icon: Icons.warning_amber,
                                        label: 'Deprecated',
                                        color: context.appColors.brandPink,
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                  ),
                ),
              ],
            ),
          ),
        if (_error != null) ...<Widget>[
          SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(
              color: context.appColors.brandPink,
              fontSize: 12.5,
            ),
          ),
        ],
        SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            TextButton(
              onPressed: _saving ? null : widget.onDone,
              child: Text('Cancel'),
            ),
            SizedBox(width: 8),
            FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: _saving
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ModelRow {
  _ModelRow({
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
      padding: EdgeInsets.only(left: 6),
      child: Tooltip(
        message: label,
        child: Icon(icon, size: 14, color: color),
      ),
    );
  }
}
