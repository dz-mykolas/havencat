import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/models/model_pricing.dart';
import '../../../domain/models/provider_definition.dart';
import '../../core/theme/app_theme.dart';
import '../../settings/settings_viewmodel.dart';
import '../pricing_format.dart';

/// Opens the Quick Add flow for [group] (a models.dev provider) using the
/// resolved [definition] from `quick_add_resolver.dart`.
///
/// Picks dialog vs drawer by viewport width:
///   * wide (>= [AppTheme.wideBreakpoint]): a centered [Dialog],
///   * narrow: a drag-handle [showModalBottomSheet] (drawer-style).
///
/// The body is shared (`_QuickAddContent`) so both presenters behave the same.
/// On successful submit the sheet is popped and the new account is persisted
/// (with its enabled-models list via [SettingsViewModel.addApiKeyAccount]).
Future<void> showQuickAdd(
  BuildContext context,
  SettingsViewModel vm,
  ProviderModels group,
  ProviderDefinition definition,
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
            child: _QuickAddContent(
              group: group,
              definition: definition,
              onSubmit:
                  ({
                    required String displayName,
                    required String apiKey,
                    required String? baseUrl,
                    required List<String> enabledModels,
                  }) async {
                    await vm.addApiKeyAccount(
                      definitionId: definition.id,
                      displayName: displayName,
                      apiKey: apiKey,
                      config: baseUrl == null
                          ? null
                          : <String, Object?>{'baseUrl': baseUrl},
                      enabledModels: enabledModels,
                    );
                  },
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
      // Pad for the on-screen keyboard when the API key field is focused.
      final double viewInsets = MediaQuery.of(ctx).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: viewInsets),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: _QuickAddContent(
              group: group,
              definition: definition,
              onSubmit:
                  ({
                    required String displayName,
                    required String apiKey,
                    required String? baseUrl,
                    required List<String> enabledModels,
                  }) async {
                    await vm.addApiKeyAccount(
                      definitionId: definition.id,
                      displayName: displayName,
                      apiKey: apiKey,
                      config: baseUrl == null
                          ? null
                          : <String, Object?>{'baseUrl': baseUrl},
                      enabledModels: enabledModels,
                    );
                  },
              onDone: () => Navigator.of(ctx).maybePop(),
            ),
          ),
        ),
      );
    },
  );
}

/// Shared form: identity + key + optional base URL + scrollable model
/// checkboxes (all start unchecked), then a submit row.
class _QuickAddContent extends StatefulWidget {
  const _QuickAddContent({
    required this.group,
    required this.definition,
    required this.onSubmit,
    required this.onDone,
  });

  final ProviderModels group;
  final ProviderDefinition definition;

  /// Persists the new account. Throws on failure; the caller shows the error
  /// inline rather than dismissing the sheet.
  final Future<void> Function({
    required String displayName,
    required String apiKey,
    required String? baseUrl,
    required List<String> enabledModels,
  })
  onSubmit;

  /// Called after a successful submit; dismisses the dialog/drawer.
  final VoidCallback onDone;

  @override
  State<_QuickAddContent> createState() => _QuickAddContentState();
}

class _QuickAddContentState extends State<_QuickAddContent> {
  late final TextEditingController _name;
  late final TextEditingController _key;
  late final TextEditingController _baseUrl;
  final Set<String> _selected = <String>{};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final String? templateBaseUrl =
        widget.definition.configTemplate['baseUrl'] as String?;
    _name = TextEditingController(text: widget.group.name);
    _key = TextEditingController();
    _baseUrl = TextEditingController(text: templateBaseUrl ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _key.dispose();
    _baseUrl.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _name.text.trim().isNotEmpty && _key.text.trim().isNotEmpty && !_saving;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final String? templateBaseUrl =
          widget.definition.configTemplate['baseUrl'] as String?;
      final bool hasUrlField = templateBaseUrl != null;
      await widget.onSubmit(
        displayName: _name.text.trim(),
        apiKey: _key.text.trim(),
        baseUrl: hasUrlField ? _baseUrl.text.trim() : null,
        enabledModels: _selected.toList(growable: false),
      );
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
    final String? templateBaseUrl =
        widget.definition.configTemplate['baseUrl'] as String?;
    final bool hasUrlField = templateBaseUrl != null;
    final String? apiKeyUrl = widget.definition.apiKeyUrl;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(title: 'Add ${widget.group.name}', apiKeyUrl: apiKeyUrl),
          const SizedBox(height: 14),
          _LabeledField(
            label: 'Display name',
            child: TextField(
              controller: _name,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
              decoration: const _FieldDecoration(),
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'API key',
            child: TextField(
              controller: _key,
              obscureText: true,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
              decoration: const _FieldDecoration(
                hintText: 'Paste your API key',
              ),
            ),
          ),
          if (hasUrlField) ...<Widget>[
            const SizedBox(height: 12),
            _LabeledField(
              label: 'Base URL',
              child: TextField(
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                ),
                decoration: const _FieldDecoration(),
              ),
            ),
          ],
          const SizedBox(height: 14),
          _ModelSection(
            models: widget.group.models,
            selected: _selected,
            onToggle: (PricedModel m) {
              setState(() {
                if (!_selected.add(m.id)) {
                  _selected.remove(m.id);
                }
              });
            },
            onSelectAll: () {
              setState(() {
                if (_selected.length == widget.group.models.length) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(widget.group.models.map((PricedModel m) => m.id));
                }
              });
            },
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
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.apiKeyUrl});

  final String title;
  final String? apiKeyUrl;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (apiKeyUrl != null)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => launchUrl(Uri.parse(apiKeyUrl!)),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.vpn_key_outlined,
                    size: 14,
                    color: AppTheme.brandBlue,
                  ),
                  SizedBox(width: 4),
                  Text(
                    'Get an API key',
                    style: TextStyle(
                      color: AppTheme.brandBlue,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

class _FieldDecoration extends InputDecoration {
  const _FieldDecoration({super.hintText});

  @override
  InputBorder get focusedBorder => OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: AppTheme.brandViolet),
  );

  @override
  InputBorder get enabledBorder => OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: AppTheme.outline),
  );
}

class _ModelSection extends StatelessWidget {
  const _ModelSection({
    required this.models,
    required this.selected,
    required this.onToggle,
    required this.onSelectAll,
  });

  final List<PricedModel> models;
  final Set<String> selected;
  final ValueChanged<PricedModel> onToggle;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final bool allSelected =
        selected.length == models.length && models.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Models (${selected.length}/${models.length} selected)',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (models.isNotEmpty)
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: onSelectAll,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    allSelected ? 'Clear' : 'Select all',
                    style: const TextStyle(
                      color: AppTheme.brandBlue,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: models.length,
            separatorBuilder: (BuildContext _, _) =>
                const Divider(height: 1, color: AppTheme.outline),
            itemBuilder: (BuildContext context, int index) {
              final PricedModel m = models[index];
              final bool on = selected.contains(m.id);
              final bool free = m.cost?.isFree ?? false;
              return InkWell(
                onTap: () => onToggle(m),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        on ? Icons.check_box : Icons.check_box_outline_blank,
                        size: 18,
                        color: on
                            ? AppTheme.brandViolet
                            : AppTheme.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              m.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              m.id,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (free)
                        _Pill(label: 'Free', color: AppTheme.brandBlue)
                      else if (m.cost?.output != null)
                        _Pill(
                          label: '${formatPricePerMillion(m.cost!.output)}/1M',
                          color: AppTheme.textSecondary,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
