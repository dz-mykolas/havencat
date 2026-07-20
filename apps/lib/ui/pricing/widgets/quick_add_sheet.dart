import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/models/adapter_kind.dart';
import '../../../domain/models/model_pricing.dart';
import '../../../domain/models/provider_definition.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';
import '../../core/widgets/credential_security_button.dart';
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
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, maxHeight: 680),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 16),
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
    builder: (BuildContext ctx) {
      // Pad for the on-screen keyboard when the API key field is focused.
      final double viewInsets = MediaQuery.of(ctx).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: viewInsets),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
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
  /// Hard cap on how many models a single account can enable. Keeps the chat
  /// picker usable for router accounts (OpenRouter serves 300+). First-party
  /// labs never hit it. TODO: drop to 20 once capability filtering lands in
  /// OpenAiCompatibleAdapter.listModels (it currently returns embeddings /
  /// whisper / tts / dall-e entries alongside chat models).
  static const int maxEnabled = 50;

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

  /// Subscription providers (ChatGPT, Poe) skip the model-pick requirement —
  /// their model list comes from the OAuth backend, not the catalog, and is
  /// auto-enabled on first fetch. Every other kind must pick at least one.
  bool get _requiresModelPick =>
      widget.definition.kind != AdapterKind.subscription;

  bool get _atCap => _selected.length >= maxEnabled;

  bool get _canSubmit =>
      _name.text.trim().isNotEmpty &&
      _key.text.trim().isNotEmpty &&
      !_saving &&
      (!_requiresModelPick || _selected.isNotEmpty);

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

    return AppScrollView(
      builder: (BuildContext context, AppScrollController controller) =>
          SingleChildScrollView(
            controller: controller,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Header(
                  title: 'Add ${widget.group.name}',
                  apiKeyUrl: apiKeyUrl,
                ),
                SizedBox(height: 14),
                _LabeledField(
                  label: 'Display name',
                  child: TextField(
                    controller: _name,
                    style: TextStyle(
                      color: context.appColors.textPrimary,
                      fontSize: 14,
                    ),
                    decoration: _FieldDecoration(),
                  ),
                ),
                SizedBox(height: 12),
                _LabeledField(
                  label: 'API key',
                  child: TextField(
                    controller: _key,
                    obscureText: true,
                    style: TextStyle(
                      color: context.appColors.textPrimary,
                      fontSize: 14,
                    ),
                    decoration: _FieldDecoration(
                      hintText: 'Paste your API key',
                      suffixIcon: CredentialSecurityButton(),
                    ),
                  ),
                ),
                if (hasUrlField) ...<Widget>[
                  SizedBox(height: 12),
                  _LabeledField(
                    label: 'Base URL',
                    child: TextField(
                      controller: _baseUrl,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      style: TextStyle(
                        color: context.appColors.textPrimary,
                        fontSize: 14,
                      ),
                      decoration: _FieldDecoration(),
                    ),
                  ),
                ],
                SizedBox(height: 14),
                _ModelSection(
                  models: widget.group.models,
                  selected: _selected,
                  maxEnabled: maxEnabled,
                  atCap: _atCap,
                  requiresPick: _requiresModelPick,
                  onToggle: (PricedModel m) {
                    setState(() {
                      if (!_selected.add(m.id)) {
                        _selected.remove(m.id);
                      }
                    });
                  },
                  onSelectAll: () {
                    setState(() {
                      final List<String> selectableIds = widget.group.models
                          .take(maxEnabled)
                          .map((PricedModel model) => model.id)
                          .toList(growable: false);
                      final bool allSelected =
                          selectableIds.isNotEmpty &&
                          selectableIds.every(_selected.contains);
                      if (allSelected) {
                        _selected.clear();
                      } else {
                        _selected
                          ..clear()
                          ..addAll(selectableIds);
                      }
                    });
                  },
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
            ),
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
            style: TextStyle(
              color: context.appColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (apiKeyUrl != null)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => launchUrl(Uri.parse(apiKeyUrl!)),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.vpn_key_outlined,
                    size: 14,
                    color: context.appColors.brandBlue,
                  ),
                  SizedBox(width: 4),
                  Text(
                    'Get an API key',
                    style: TextStyle(
                      color: context.appColors.brandBlue,
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
          style: TextStyle(
            color: context.appColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        SizedBox(height: 6),
        child,
      ],
    );
  }
}

class _FieldDecoration extends InputDecoration {
  const _FieldDecoration({super.hintText, super.suffixIcon});
}

class _ModelSection extends StatelessWidget {
  const _ModelSection({
    required this.models,
    required this.selected,
    required this.maxEnabled,
    required this.atCap,
    required this.requiresPick,
    required this.onToggle,
    required this.onSelectAll,
  });

  final List<PricedModel> models;
  final Set<String> selected;
  final int maxEnabled;
  final bool atCap;
  final bool requiresPick;
  final ValueChanged<PricedModel> onToggle;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final Iterable<String> selectableIds = models
        .take(maxEnabled)
        .map((PricedModel model) => model.id);
    final bool allSelected =
        selectableIds.isNotEmpty && selectableIds.every(selected.contains);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                requiresPick && selected.isEmpty
                    ? 'Pick at least one model (${models.length} available)'
                    : 'Models (${selected.length}/${models.length} selected'
                          '${atCap ? ' · cap $maxEnabled' : ''})',
                style: TextStyle(
                  color: requiresPick && selected.isEmpty
                      ? context.appColors.brandPink
                      : context.appColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (models.isNotEmpty)
              Tooltip(
                message: allSelected ? 'Unselect all' : 'Select all',
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: onSelectAll,
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
        SizedBox(height: 4),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: 260),
          child: AppScrollView(
            builder: (BuildContext context, AppScrollController controller) =>
                ListView.separated(
                  controller: controller,
                  shrinkWrap: true,
                  itemCount: models.length,
                  separatorBuilder: (BuildContext _, _) =>
                      Divider(height: 1, color: context.appColors.divider),
                  itemBuilder: (BuildContext context, int index) {
                    final PricedModel m = models[index];
                    final bool on = selected.contains(m.id);
                    final bool free = m.cost?.isFree ?? false;
                    final bool lockedOff = !on && atCap;
                    return InkWell(
                      onTap: lockedOff ? null : () => onToggle(m),
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
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    m.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: context.appColors.textPrimary,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    m.id,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: context.appColors.textSecondary,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (free)
                              Tooltip(
                                message: 'Free',
                                child: Icon(
                                  Icons.money_off_csred_outlined,
                                  size: 16,
                                  color: context.appColors.brandBlue,
                                ),
                              )
                            else if (m.cost?.output != null)
                              _Pill(
                                label:
                                    '${formatPricePerMillion(m.cost!.output)}/1M',
                                color: context.appColors.textSecondary,
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
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
