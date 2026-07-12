import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/services/web_retrieval/web_retrieval_provider_registry.dart';
import '../../../data/services/web_retrieval/web_search_settings.dart';
import '../../../domain/errors/app_failure.dart';
import '../../../providers.dart';
import '../../core/notices/app_notice.dart';
import '../../core/notices/failure_presenter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/credential_security_button.dart';

class WebSearchSettingsPanel extends ConsumerWidget {
  const WebSearchSettingsPanel({super.key});

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
              subtitle: Text(failure.message),
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
    final WebSearchSettings settings = ref.read(webSearchSettingsProvider);
    final WebSearchProviderPreference preference = settings.preferenceFor(
      definition.kind,
    );
    final TextEditingController valueController = TextEditingController(
      text: definition.configuration == WebProviderConfiguration.instanceUrl
          ? preference.instanceUrl ?? ''
          : '',
    );
    bool enabled = enableOnSave || preference.enabled;
    bool clearApiKey = false;
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AlertDialog(
          title: Text('Configure ${definition.displayName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (definition.configuration ==
                  WebProviderConfiguration.instanceUrl)
                TextField(
                  controller: valueController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Instance URL',
                    hintText: 'https://search.example.com',
                    border: OutlineInputBorder(),
                  ),
                )
              else
                TextField(
                  controller: valueController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: definition.kind == 'exa'
                        ? 'API key (optional)'
                        : 'API key',
                    hintText: preference.hasApiKey
                        ? 'Leave blank to keep the saved key'
                        : null,
                    border: const OutlineInputBorder(),
                    suffixIcon: const CredentialSecurityButton(),
                  ),
                ),
              if (preference.hasApiKey &&
                  definition.configuration == WebProviderConfiguration.apiKey)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Remove saved API key'),
                  value: clearApiKey,
                  onChanged: (bool? value) =>
                      setState(() => clearApiKey = value ?? false),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enabled'),
                value: enabled,
                onChanged: (bool value) => setState(() => enabled = value),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) {
      valueController.dispose();
      return;
    }
    try {
      await settings.saveProvider(
        kind: definition.kind,
        enabled: enabled,
        apiKey: definition.configuration == WebProviderConfiguration.apiKey
            ? valueController.text
            : null,
        clearApiKey: clearApiKey,
        instanceUrl:
            definition.configuration == WebProviderConfiguration.instanceUrl
            ? valueController.text
            : preference.instanceUrl,
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
    } finally {
      valueController.dispose();
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
      'searxng' => preference.instanceUrl ?? 'Instance URL required',
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
