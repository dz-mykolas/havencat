import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/services/web_retrieval/web_retrieval_provider_registry.dart';
import '../../../data/services/web_retrieval/web_retrieval_endpoint_policy.dart';
import '../../../data/services/web_retrieval/web_search_settings.dart';
import '../../../domain/errors/app_failure.dart';
import '../../../providers.dart';
import '../../core/notices/app_notice.dart';
import '../../core/notices/failure_presenter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/credential_security_button.dart';

typedef WebSearchProviderRouteCallback =
    void Function(String providerKind, {bool enableOnSave});

class WebSearchSettingsPanel extends ConsumerWidget {
  const WebSearchSettingsPanel({this.onConfigureProvider, super.key});

  final WebSearchProviderRouteCallback? onConfigureProvider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final WebSearchSettings settings = ref.watch(webSearchSettingsProvider);
    return ListView(
      padding: EdgeInsets.only(bottom: 24),
      children: <Widget>[
        Text(
          'Search providers',
          style: TextStyle(
            color: context.appColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Exa works with limited anonymous access by default. Add providers '
          'or credentials here; changes apply immediately.',
          style: TextStyle(
            color: context.appColors.textSecondary,
            fontSize: 13,
          ),
        ),
        SizedBox(height: 16),
        if (settings.lastFailure case final AppFailure failure) ...<Widget>[
          Material(
            color: context.appColors.surface,
            borderRadius: BorderRadius.circular(14),
            child: ListTile(
              leading: Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Search configuration is not active'),
              subtitle: SelectableText(failure.message),
              trailing: TextButton(
                onPressed: settings.applying
                    ? null
                    : () async {
                        try {
                          await settings.reapply();
                        } on Object catch (error) {
                          _showFailure(ref, _asFailure(error, 'web_search'));
                        }
                      },
                child: const Text('Retry'),
              ),
            ),
          ),
          SizedBox(height: 12),
        ],
        Material(
          color: context.appColors.surface,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              for (
                int index = 0;
                index < WebRetrievalProviderRegistry.searchProviders.length;
                index++
              ) ...<Widget>[
                _ProviderTile(
                  definition:
                      WebRetrievalProviderRegistry.searchProviders[index],
                  preference: settings.preferenceFor(
                    WebRetrievalProviderRegistry.searchProviders[index].kind,
                  ),
                  busy: settings.applying,
                  onConfigure: () => _configure(
                    context,
                    ref,
                    WebRetrievalProviderRegistry.searchProviders[index],
                  ),
                  onEnabled: (bool enabled) => _setEnabled(
                    context,
                    ref,
                    WebRetrievalProviderRegistry.searchProviders[index],
                    enabled,
                  ),
                ),
                if (index !=
                    WebRetrievalProviderRegistry.searchProviders.length - 1)
                  Divider(height: 1, color: context.appColors.divider),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _setEnabled(
    BuildContext context,
    WidgetRef ref,
    WebSearchProviderDefinition definition,
    bool enabled,
  ) async {
    final WebSearchSettings settings = ref.read(webSearchSettingsProvider);
    final WebSearchProviderPreference preference = settings.preferenceFor(
      definition.kind,
    );
    if (enabled &&
        ((definition.kind == 'brave' && !preference.hasApiKey) ||
            (definition.kind == 'searxng' && preference.instanceUrl == null))) {
      await _configure(context, ref, definition, enableOnSave: true);
      return;
    }
    try {
      await settings.setEnabled(definition.kind, enabled);
    } on Object catch (error) {
      _showFailure(ref, _asFailure(error, definition.kind));
    }
  }

  Future<void> _configure(
    BuildContext context,
    WidgetRef ref,
    WebSearchProviderDefinition definition, {
    bool enableOnSave = false,
  }) async {
    if (onConfigureProvider case final navigate?) {
      navigate(definition.kind, enableOnSave: enableOnSave);
      return;
    }
    final WebSearchSettings settings = ref.read(webSearchSettingsProvider);
    final WebSearchProviderPreference preference = settings.preferenceFor(
      definition.kind,
    );
    final _ProviderConfigurationResult? result =
        await showDialog<_ProviderConfigurationResult>(
          context: context,
          builder: (_) => _ProviderConfigurationDialog(
            definition: definition,
            preference: preference,
            enableOnSave: enableOnSave,
          ),
        );
    if (result == null) return;
    try {
      await settings.saveProvider(
        kind: definition.kind,
        enabled: result.enabled,
        apiKey: result.secret,
        clearApiKey: result.clearApiKey,
        instanceUrl: result.instanceUrl,
      );
      ref
          .read(noticeCenterProvider)
          .publish(
            AppNotice(
              id: 'web-search-config-${definition.kind}',
              severity: NoticeSeverity.success,
              title: '${definition.displayName} updated',
              message: 'The active web-search configuration is ready.',
              deduplicationKey: 'web-search-config:${definition.kind}',
            ),
          );
    } on Object catch (error) {
      _showFailure(ref, _asFailure(error, definition.kind));
    }
  }

  void _showFailure(WidgetRef ref, AppFailure failure) {
    ref
        .read(noticeCenterProvider)
        .publish(const FailurePresenter().present(failure));
  }

  AppFailure _asFailure(Object error, String provider) {
    if (error is AppFailure) return error;
    return AppFailure(
      kind: FailureKind.unknown,
      source: FailureSource(
        subsystem: AppSubsystem.webSearch,
        operation: 'configure',
        providerId: provider,
      ),
      message: 'The web-search configuration could not be updated.',
    );
  }
}

class WebSearchProviderConfigurationRoute extends ConsumerWidget {
  const WebSearchProviderConfigurationRoute({
    required this.providerKind,
    this.enableOnSave = false,
    super.key,
  });

  final String providerKind;
  final bool enableOnSave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final WebSearchProviderDefinition definition =
        WebRetrievalProviderRegistry.searchProviderFor(providerKind)!;
    final WebSearchSettings settings = ref.watch(webSearchSettingsProvider);
    return _ProviderConfigurationDialog(
      definition: definition,
      preference: settings.preferenceFor(definition.kind),
      enableOnSave: enableOnSave,
      onSave: (_ProviderConfigurationResult result) async {
        try {
          await settings.saveProvider(
            kind: definition.kind,
            enabled: result.enabled,
            apiKey: result.secret,
            clearApiKey: result.clearApiKey,
            instanceUrl: result.instanceUrl,
          );
          ref
              .read(noticeCenterProvider)
              .publish(
                AppNotice(
                  id: 'web-search-config-${definition.kind}',
                  severity: NoticeSeverity.success,
                  title: '${definition.displayName} updated',
                  message: 'The active web-search configuration is ready.',
                  deduplicationKey: 'web-search-config:${definition.kind}',
                ),
              );
          if (context.mounted) Navigator.of(context).pop();
        } on Object catch (error) {
          ref
              .read(noticeCenterProvider)
              .publish(
                const FailurePresenter().present(
                  _providerConfigurationFailure(error, definition.kind),
                ),
              );
        }
      },
    );
  }
}

class _ProviderConfigurationResult {
  const _ProviderConfigurationResult({
    required this.enabled,
    required this.clearApiKey,
    this.secret,
    this.instanceUrl,
  });

  final bool enabled;
  final bool clearApiKey;
  final String? secret;
  final String? instanceUrl;
}

class _ProviderConfigurationDialog extends StatefulWidget {
  const _ProviderConfigurationDialog({
    required this.definition,
    required this.preference,
    required this.enableOnSave,
    this.onSave,
  });

  final WebSearchProviderDefinition definition;
  final WebSearchProviderPreference preference;
  final bool enableOnSave;
  final Future<void> Function(_ProviderConfigurationResult result)? onSave;

  @override
  State<_ProviderConfigurationDialog> createState() =>
      _ProviderConfigurationDialogState();
}

class _ProviderConfigurationDialogState
    extends State<_ProviderConfigurationDialog> {
  late final TextEditingController _instanceUrlController;
  late final TextEditingController _secretController;
  late bool _enabled;
  late String _instanceScheme;
  late bool _instanceSchemeExplicit;
  bool _clearApiKey = false;
  bool _updatingInstanceUrl = false;
  bool _saving = false;

  bool get _usesInstanceUrl =>
      widget.definition.configuration == WebProviderConfiguration.instanceUrl;
  bool get _supportsAccessToken => widget.definition.kind == 'searxng';

  @override
  void initState() {
    super.initState();
    final _InstanceUrlParts instanceUrl = _splitInstanceUrl(
      _usesInstanceUrl ? widget.preference.instanceUrl ?? '' : '',
    );
    _instanceUrlController = TextEditingController(text: instanceUrl.address);
    _instanceScheme = instanceUrl.scheme;
    _instanceSchemeExplicit = instanceUrl.explicitScheme;
    _instanceUrlController.addListener(_handleInstanceUrlChanged);
    _secretController = TextEditingController();
    _secretController.addListener(_handleSecretChanged);
    _enabled = widget.enableOnSave || widget.preference.enabled;
  }

  @override
  void dispose() {
    _instanceUrlController.removeListener(_handleInstanceUrlChanged);
    _secretController.removeListener(_handleSecretChanged);
    _instanceUrlController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  void _handleInstanceUrlChanged() {
    if (_updatingInstanceUrl) return;
    final String value = _instanceUrlController.text;
    final RegExpMatch? explicitScheme = RegExp(
      r'^(https?)://',
      caseSensitive: false,
    ).firstMatch(value.trimLeft());
    if (explicitScheme != null) {
      final String scheme = explicitScheme.group(1)!.toLowerCase();
      final String address = value
          .trimLeft()
          .substring(explicitScheme.end)
          .trimLeft();
      _updatingInstanceUrl = true;
      _instanceUrlController.value = TextEditingValue(
        text: address,
        selection: TextSelection.collapsed(offset: address.length),
      );
      _updatingInstanceUrl = false;
      setState(() {
        _instanceScheme = scheme;
        _instanceSchemeExplicit = true;
      });
      return;
    }
    if (_instanceSchemeExplicit) {
      setState(() {});
      return;
    }
    final String inferredScheme =
        WebRetrievalEndpointPolicy.defaultSchemeForAddress(value);
    setState(() => _instanceScheme = inferredScheme);
  }

  void _handleSecretChanged() => setState(() {});

  void _selectInstanceScheme(String? scheme) {
    if (scheme == null) return;
    setState(() {
      _instanceScheme = scheme;
      _instanceSchemeExplicit = true;
    });
  }

  String _instanceUrl() {
    final String address = _instanceUrlController.text.trim();
    if (address.isEmpty) return address;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(address)) {
      return address;
    }
    return '$_instanceScheme://$address';
  }

  bool get _hasEffectiveAccessToken {
    return (_supportsAccessToken &&
            widget.preference.hasApiKey &&
            !_clearApiKey) ||
        _secretController.text.trim().isNotEmpty;
  }

  String? get _configurationError {
    if (!_usesInstanceUrl) return null;
    return WebRetrievalEndpointPolicy.validateSearxng(
      endpoint: _instanceUrl(),
      hasAccessToken: _hasEffectiveAccessToken,
    );
  }

  bool get _showInsecureLocalWarning {
    if (!_usesInstanceUrl ||
        _configurationError != null ||
        _instanceScheme != 'http') {
      return false;
    }
    final Uri? uri = Uri.tryParse(_instanceUrl());
    return uri != null &&
        WebRetrievalEndpointPolicy.classifyHost(uri.host) ==
            WebEndpointScope.privateNetwork;
  }

  Future<void> _save() async {
    final _ProviderConfigurationResult result = _ProviderConfigurationResult(
      enabled: _enabled,
      clearApiKey: _clearApiKey,
      secret:
          widget.definition.configuration == WebProviderConfiguration.apiKey ||
              _supportsAccessToken
          ? _secretController.text
          : null,
      instanceUrl: _usesInstanceUrl
          ? _instanceUrl()
          : widget.preference.instanceUrl,
    );
    if (widget.onSave case final onSave?) {
      setState(() => _saving = true);
      await onSave(result);
      if (mounted) setState(() => _saving = false);
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Configure ${widget.definition.displayName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_usesInstanceUrl)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 140,
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey<String>('instance-url-scheme'),
                      initialValue: _instanceScheme,
                      decoration: const InputDecoration(
                        labelText: 'Protocol',
                        border: OutlineInputBorder(),
                      ),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                          value: 'https',
                          child: Text('HTTPS'),
                        ),
                        DropdownMenuItem<String>(
                          value: 'http',
                          child: Text('HTTP'),
                        ),
                      ],
                      onChanged: _selectInstanceScheme,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _instanceUrlController,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: _supportsAccessToken
                          ? TextInputAction.next
                          : TextInputAction.done,
                      onEditingComplete: () {
                        if (_supportsAccessToken) {
                          FocusScope.of(context).nextFocus();
                        }
                      },
                      decoration: const InputDecoration(
                        labelText: 'Instance address',
                        hintText: 'search.example.com',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            if (_configurationError case final String error)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.error_outline_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (_showInsecureLocalWarning)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: context.appColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Local HTTP traffic is unencrypted and may be visible '
                        'to other devices on this network.',
                        style: TextStyle(
                          color: context.appColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_supportsAccessToken) const SizedBox(height: 16),
            if (!_usesInstanceUrl || _supportsAccessToken)
              TextField(
                controller: _secretController,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: _supportsAccessToken
                      ? 'Access token (optional)'
                      : widget.definition.kind == 'exa'
                      ? 'API key (optional)'
                      : 'API key',
                  hintText: widget.preference.hasApiKey
                      ? _supportsAccessToken
                            ? 'Leave blank to keep the saved token'
                            : 'Leave blank to keep the saved key'
                      : null,
                  border: const OutlineInputBorder(),
                  suffixIcon: const CredentialSecurityButton(),
                ),
              ),
            if (widget.preference.hasApiKey &&
                (!_usesInstanceUrl || _supportsAccessToken))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _supportsAccessToken
                      ? 'Remove saved access token'
                      : 'Remove saved API key',
                ),
                value: _clearApiKey,
                onChanged: (bool? value) =>
                    setState(() => _clearApiKey = value ?? false),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              value: _enabled,
              onChanged: (bool value) => setState(() => _enabled = value),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !_saving && _configurationError == null ? _save : null,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}

AppFailure _providerConfigurationFailure(Object error, String provider) {
  if (error is AppFailure) return error;
  return AppFailure(
    kind: FailureKind.unknown,
    source: FailureSource(
      subsystem: AppSubsystem.webSearch,
      operation: 'configure',
      providerId: provider,
    ),
    message: 'The web-search configuration could not be updated.',
  );
}

class _InstanceUrlParts {
  const _InstanceUrlParts({
    required this.scheme,
    required this.address,
    required this.explicitScheme,
  });

  final String scheme;
  final String address;
  final bool explicitScheme;
}

_InstanceUrlParts _splitInstanceUrl(String value) {
  final String trimmed = value.trim();
  final RegExpMatch? match = RegExp(
    r'^(https?)://',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (match == null) {
    return _InstanceUrlParts(
      scheme: WebRetrievalEndpointPolicy.defaultSchemeForAddress(trimmed),
      address: trimmed,
      explicitScheme: false,
    );
  }
  return _InstanceUrlParts(
    scheme: match.group(1)!.toLowerCase(),
    address: trimmed.substring(match.end),
    explicitScheme: true,
  );
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.definition,
    required this.preference,
    required this.busy,
    required this.onConfigure,
    required this.onEnabled,
  });

  final WebSearchProviderDefinition definition;
  final WebSearchProviderPreference preference;
  final bool busy;
  final VoidCallback onConfigure;
  final ValueChanged<bool> onEnabled;

  @override
  Widget build(BuildContext context) {
    final String subtitle = switch (definition.kind) {
      'exa' =>
        preference.hasApiKey
            ? 'API key configured'
            : 'Limited anonymous access',
      'brave' =>
        preference.hasApiKey ? 'API key configured' : 'API key required',
      'searxng' =>
        preference.instanceUrl == null
            ? 'Instance URL required'
            : preference.hasApiKey
            ? '${preference.instanceUrl} · Access token configured'
            : preference.instanceUrl!,
      _ => '',
    };
    return ListTile(
      leading: Icon(
        Icons.travel_explore_rounded,
        color: preference.enabled
            ? context.appColors.brandViolet
            : context.appColors.textSecondary,
      ),
      title: Text(definition.displayName),
      subtitle: Text(subtitle),
      onTap: busy ? null : onConfigure,
      trailing: Switch(
        value: preference.enabled,
        onChanged: busy ? null : onEnabled,
      ),
    );
  }
}
