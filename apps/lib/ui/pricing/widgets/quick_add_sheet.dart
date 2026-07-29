import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/services/web_retrieval/web_retrieval_endpoint_policy.dart';
import '../../../domain/models/model_pricing.dart';
import '../../../domain/models/provider_definition.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';
import '../../core/widgets/credential_security_button.dart';
import '../../settings/settings_viewmodel.dart';
import '../pricing_format.dart';

Future<void> showQuickAdd(
  BuildContext context,
  SettingsViewModel vm,
  ProviderModels group,
  ProviderDefinition definition,
) async {
  Future<void> submit({
    required String displayName,
    required String apiKey,
    required String? baseUrl,
    required List<String> enabledModels,
  }) {
    return vm.addApiKeyAccount(
      definitionId: definition.id,
      displayName: displayName,
      apiKey: apiKey,
      config: <String, Object?>{
        'catalogProviderId': group.id,
        'providerName': group.name,
        'baseUrl': ?baseUrl,
      },
      enabledModels: enabledModels,
    );
  }

  final bool wide = MediaQuery.sizeOf(context).width >= AppTheme.wideBreakpoint;
  if (wide) {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560, maxHeight: 720),
          child: _QuickAddContent(
            group: group,
            definition: definition,
            onSubmit: submit,
            onDone: () => Navigator.of(dialogContext).maybePop(),
          ),
        ),
      ),
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      final MediaQueryData media = MediaQuery.of(sheetContext);
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: (media.size.height - media.viewInsets.bottom) * 0.90,
            ),
            child: _QuickAddContent(
              group: group,
              definition: definition,
              onSubmit: submit,
              onDone: () => Navigator.of(sheetContext).maybePop(),
            ),
          ),
        ),
      );
    },
  );
}

class _QuickAddContent extends StatefulWidget {
  const _QuickAddContent({
    required this.group,
    required this.definition,
    required this.onSubmit,
    required this.onDone,
  });

  final ProviderModels group;
  final ProviderDefinition definition;
  final Future<void> Function({
    required String displayName,
    required String apiKey,
    required String? baseUrl,
    required List<String> enabledModels,
  })
  onSubmit;
  final VoidCallback onDone;

  @override
  State<_QuickAddContent> createState() => _QuickAddContentState();
}

class _QuickAddContentState extends State<_QuickAddContent> {
  static const int maxEnabled = 50;

  late final TextEditingController _name;
  late final TextEditingController _key;
  late final TextEditingController _baseUrl;
  final Set<String> _selected = <String>{};
  bool _showEndpoint = false;
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
    _name.addListener(_onFieldChanged);
    _key.addListener(_onFieldChanged);
    _baseUrl.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _name.dispose();
    _key.dispose();
    _baseUrl.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (mounted) setState(() => _error = null);
  }

  bool get _requiresModelPick => !widget.definition.requiresOAuth;

  bool get _atCap => _selected.length >= maxEnabled;

  bool get _hasUrlField =>
      widget.definition.configTemplate['baseUrl'] is String;

  String? get _endpointError {
    if (!_hasUrlField) return null;
    final Uri? uri = Uri.tryParse(_baseUrl.text.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        !(uri.isScheme('https') || uri.isScheme('http'))) {
      return 'Enter a full HTTP or HTTPS URL.';
    }
    final WebEndpointScope scope = WebRetrievalEndpointPolicy.classifyHost(
      uri.host,
    );
    if (scope == WebEndpointScope.invalid) {
      return 'Enter a valid endpoint URL.';
    }
    if (uri.isScheme('https')) return null;
    if (scope == WebEndpointScope.publicNetwork) {
      return 'Public endpoints require HTTPS.';
    }
    if (_key.text.trim().isNotEmpty && scope != WebEndpointScope.loopback) {
      return 'API keys require HTTPS outside this device.';
    }
    return null;
  }

  bool get _canSubmit =>
      _name.text.trim().isNotEmpty &&
      _key.text.trim().isNotEmpty &&
      !_saving &&
      _endpointError == null &&
      (!_requiresModelPick || _selected.isNotEmpty);

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit(
        displayName: _name.text.trim(),
        apiKey: _key.text.trim(),
        baseUrl: _hasUrlField ? _baseUrl.text.trim() : null,
        enabledModels: _selected.toList(growable: false),
      );
      if (mounted) widget.onDone();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not add account: $error');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toggle(PricedModel model) {
    setState(() {
      if (!_selected.add(model.id)) _selected.remove(model.id);
    });
  }

  void _toggleAll() {
    final List<String> selectable = widget.group.models
        .take(maxEnabled)
        .map((PricedModel model) => model.id)
        .toList(growable: false);
    final bool allSelected =
        selectable.isNotEmpty && selectable.every(_selected.contains);
    setState(() {
      if (allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(selectable);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ProviderHero(
          group: widget.group,
          apiKeyUrl: widget.definition.apiKeyUrl,
        ),
        Expanded(
          child: AppScrollView(
            builder: (BuildContext context, AppScrollController controller) {
              return CustomScrollView(
                controller: controller,
                slivers: <Widget>[
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(18, 16, 18, 8),
                    sliver: SliverToBoxAdapter(
                      child: _CredentialFields(
                        name: _name,
                        apiKey: _key,
                        baseUrl: _baseUrl,
                        hasUrlField: _hasUrlField,
                        showEndpoint: _showEndpoint,
                        endpointError: _endpointError,
                        onToggleEndpoint: () =>
                            setState(() => _showEndpoint = !_showEndpoint),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(18, 8, 18, 7),
                    sliver: SliverToBoxAdapter(
                      child: _ModelSelectionHeader(
                        total: widget.group.models.length,
                        selected: _selected.length,
                        atCap: _atCap,
                        maxEnabled: maxEnabled,
                        requiresPick: _requiresModelPick,
                        allSelected:
                            widget.group.models.isNotEmpty &&
                            widget.group.models
                                .take(maxEnabled)
                                .every(
                                  (PricedModel model) =>
                                      _selected.contains(model.id),
                                ),
                        onToggleAll: _toggleAll,
                      ),
                    ),
                  ),
                  if (widget.group.models.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyModels(),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(14, 0, 14, 16),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate((
                          BuildContext context,
                          int index,
                        ) {
                          final PricedModel model = widget.group.models[index];
                          final bool selected = _selected.contains(model.id);
                          final bool disabled = !selected && _atCap;
                          return Padding(
                            padding: EdgeInsets.only(bottom: 6),
                            child: _SelectableModel(
                              model: model,
                              selected: selected,
                              enabled: !disabled,
                              onTap: () => _toggle(model),
                            ),
                          );
                        }, childCount: widget.group.models.length),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        if (_error != null)
          Padding(
            padding: EdgeInsets.fromLTRB(18, 8, 18, 0),
            child: Text(
              _error!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        _ActionBar(
          selectedCount: _selected.length,
          saving: _saving,
          canSubmit: _canSubmit,
          onCancel: widget.onDone,
          onSubmit: _submit,
        ),
      ],
    );
  }
}

class _ProviderHero extends StatelessWidget {
  const _ProviderHero({required this.group, required this.apiKeyUrl});

  final ProviderModels group;
  final String? apiKeyUrl;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final BorderRadius borderRadius = BorderRadius.only(
      topLeft: Radius.circular(24),
      topRight: Radius.circular(24),
      bottomLeft: Radius.circular(24),
      bottomRight: Radius.circular(10),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 14, 14, 0),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 15, 12, 15),
          child: Row(
            children: <Widget>[
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.key_rounded,
                  color: colors.onPrimary,
                  size: 22,
                ),
              ),
              SizedBox(width: 13),
              Expanded(
                child: Text(
                  'Connect ${group.name}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
              if (apiKeyUrl != null) ...<Widget>[
                SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Get an API key',
                  onPressed: () => launchUrl(Uri.parse(apiKeyUrl!)),
                  icon: Icon(Icons.key_rounded, size: 18),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CredentialFields extends StatelessWidget {
  const _CredentialFields({
    required this.name,
    required this.apiKey,
    required this.baseUrl,
    required this.hasUrlField,
    required this.showEndpoint,
    required this.endpointError,
    required this.onToggleEndpoint,
  });

  final TextEditingController name;
  final TextEditingController apiKey;
  final TextEditingController baseUrl;
  final bool hasUrlField;
  final bool showEndpoint;
  final String? endpointError;
  final VoidCallback onToggleEndpoint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: name,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Account name',
            prefixIcon: Icon(Icons.badge_outlined, size: 19),
          ),
        ),
        SizedBox(height: 10),
        TextField(
          controller: apiKey,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'API key',
            prefixIcon: Icon(Icons.password_rounded, size: 19),
            suffixIcon: CredentialSecurityButton(),
          ),
        ),
        if (hasUrlField) ...<Widget>[
          SizedBox(height: 5),
          Row(
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Text(
                    _endpointSummary(baseUrl.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onToggleEndpoint,
                icon: Icon(
                  showEndpoint ? Icons.expand_less_rounded : Icons.tune_rounded,
                  size: 17,
                ),
                label: Text(showEndpoint ? 'Hide endpoint' : 'Edit endpoint'),
              ),
            ],
          ),
          AnimatedSize(
            duration: Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: showEndpoint
                ? Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: TextField(
                      controller: baseUrl,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'Base URL',
                        errorText: endpointError,
                        prefixIcon: Icon(Icons.link_rounded, size: 19),
                      ),
                    ),
                  )
                : SizedBox.shrink(),
          ),
        ],
      ],
    );
  }

  String _endpointSummary(String value) {
    final Uri? uri = Uri.tryParse(value.trim());
    final String host = uri?.host ?? '';
    return host.isEmpty ? 'Default endpoint' : 'Endpoint · $host';
  }
}

class _ModelSelectionHeader extends StatelessWidget {
  const _ModelSelectionHeader({
    required this.total,
    required this.selected,
    required this.atCap,
    required this.maxEnabled,
    required this.requiresPick,
    required this.allSelected,
    required this.onToggleAll,
  });

  final int total;
  final int selected;
  final bool atCap;
  final int maxEnabled;
  final bool requiresPick;
  final bool allSelected;
  final VoidCallback onToggleAll;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool showStatus = (requiresPick && selected == 0) || atCap;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('Models', style: theme.textTheme.titleMedium),
                  SizedBox(width: 8),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: ShapeDecoration(
                      color: selected == 0
                          ? theme.colorScheme.surfaceContainerHigh
                          : theme.colorScheme.primary,
                      shape: StadiumBorder(),
                    ),
                    child: Text(
                      '$selected/$total',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: selected == 0
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 2),
              SizedBox(
                height: 20,
                child: AnimatedOpacity(
                  opacity: showStatus ? 1 : 0,
                  duration: Durations.short2,
                  child: Text(
                    atCap
                        ? 'Selection limit reached ($maxEnabled)'
                        : 'Choose at least one',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: atCap
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.tertiary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (total > 0)
          TextButton(
            onPressed: onToggleAll,
            child: Text(allSelected ? 'Clear' : 'Select all'),
          ),
      ],
    );
  }
}

class _SelectableModel extends StatelessWidget {
  const _SelectableModel({
    required this.model,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final PricedModel model;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final Color selectedColor = Color.alphaBlend(
      colors.primary.withValues(alpha: 0.15),
      colors.surfaceContainerHigh,
    );
    final bool free = model.cost?.isFree ?? false;
    final String price = free
        ? 'Free'
        : model.cost?.output == null
        ? ''
        : '${formatPricePerMillion(model.cost?.output)} per million tokens';
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Semantics(
        container: true,
        label: <String>[
          model.displayName,
          model.id,
          price,
        ].where((value) => value.isNotEmpty).join(', '),
        checked: selected,
        enabled: enabled,
        onTap: enabled ? onTap : null,
        child: ExcludeSemantics(
          child: Material(
            color: selected ? selectedColor : colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(selected ? 18 : 13),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onTap : null,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: 58),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(4, 5, 10, 5),
                  child: Row(
                    children: <Widget>[
                      Checkbox(
                        value: selected,
                        onChanged: enabled ? (_) => onTap() : null,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              model.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 1),
                            Text(
                              model.id,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (free || model.cost?.output != null) ...<Widget>[
                        SizedBox(width: 8),
                        _PriceBadge(
                          label: free
                              ? 'Free'
                              : '${formatPricePerMillion(model.cost?.output)}/1M',
                          emphasized: free,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PriceBadge extends StatelessWidget {
  const _PriceBadge({required this.label, required this.emphasized});

  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: ShapeDecoration(
        color: emphasized
            ? theme.colorScheme.tertiary
            : theme.colorScheme.surfaceContainerHighest,
        shape: StadiumBorder(),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: emphasized
              ? theme.colorScheme.onTertiary
              : theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyModels extends StatelessWidget {
  const _EmptyModels();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'No models available',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.selectedCount,
    required this.saving,
    required this.canSubmit,
    required this.onCancel,
    required this.onSubmit,
  });

  final int selectedCount;
  final bool saving;
  final bool canSubmit;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxWidth < 420;
          return Padding(
            padding: EdgeInsets.fromLTRB(16, 11, 16, 13),
            child: Row(
              children: <Widget>[
                if (!compact)
                  Text(
                    selectedCount == 1 ? '1 model' : '$selectedCount models',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                Spacer(),
                TextButton(
                  onPressed: saving ? null : onCancel,
                  child: Text('Cancel'),
                ),
                SizedBox(width: 7),
                FilledButton.icon(
                  onPressed: canSubmit ? onSubmit : null,
                  icon: saving
                      ? SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.add_rounded, size: 18),
                  label: Text(compact ? 'Add' : 'Add account'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
