import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/provider_definition.dart';
import '../settings_viewmodel.dart';
import 'add_account_dialog.dart';
import 'chatgpt_login_dialog.dart';

/// A bottom sheet / dialog that lists every addable provider, grouped into
/// "Subscription logins" and "API keys" sections.
///
/// Tapping a subscription entry (requiresOAuth) launches the ChatGPT device-code
/// flow via [ChatGptLoginDialog]. Tapping an API-key entry launches the
/// [AddAccountDialog] with that provider pre-selected.
///
/// This is the single entry point for adding any account — the settings
/// screen's "Add account" button opens this.
void showProviderPicker(BuildContext context, SettingsViewModel viewModel) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext sheetContext) {
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  'Add account',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Divider(height: 1),
              _SectionLabel('Subscription logins'),
              for (final ProviderDefinition d in viewModel.subscriptionCatalog)
                _ProviderTile(
                  definition: d,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _launch(context, viewModel, d);
                  },
                ),
              const SizedBox(height: 8),
              _SectionLabel('API keys'),
              for (final ProviderDefinition d in viewModel.apiKeyCatalog)
                _ProviderTile(
                  definition: d,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _launch(context, viewModel, d);
                  },
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    },
  );
}

void _launch(
  BuildContext context,
  SettingsViewModel viewModel,
  ProviderDefinition definition,
) {
  if (definition.requiresOAuth) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) =>
          ChatGptLoginDialog(viewModel: viewModel),
    );
    return;
  }
  showDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        AddAccountDialog(viewModel: viewModel, initialDefinition: definition),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({required this.definition, required this.onTap});

  final ProviderDefinition definition;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(
        definition.requiresOAuth
            ? Icons.workspace_premium_outlined
            : Icons.key_outlined,
        color: AppTheme.textSecondary,
        size: 22,
      ),
      title: Text(
        definition.displayName,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        definition.description,
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(
        Icons.chevron_right,
        color: AppTheme.textSecondary,
        size: 20,
      ),
    );
  }
}
