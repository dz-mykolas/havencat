import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/provider_definition.dart';
import '../settings_viewmodel.dart';
import 'add_account_dialog.dart';
import 'chatgpt_login_dialog.dart';

/// A bottom sheet that lists every addable provider.
///
/// Subscription logins (ChatGPT, Poe) are listed first. Each subscription can
/// only be connected once — when an account already exists for a definition,
/// its tile is greyed out and shows "Already connected" so the user knows why
/// it's disabled. API-key providers (OpenAI-compatible, Anthropic, Gemini)
/// are added via the Discover panel's Providers tab (the "Custom endpoint"
/// card) or the Quick-Add flow, so they don't appear here.
///
/// Tapping an available subscription entry launches the ChatGPT device-code
/// flow via [ChatGptLoginDialog].
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
                  // A subscription can only be connected once. Grey out the
                  // tile when an account for this definition already exists.
                  disabled: viewModel.hasAccountForDefinition(d.id),
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
  const _ProviderTile({
    required this.definition,
    required this.onTap,
    this.disabled = false,
  });

  final ProviderDefinition definition;
  final VoidCallback onTap;

  /// When true, the tile renders greyed out and non-tappable. Used for
  /// subscription providers that already have a connected account.
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final Color fg =
        disabled ? AppTheme.textSecondary : AppTheme.textPrimary;
    final Color iconColor = disabled
        ? AppTheme.textSecondary
        : AppTheme.textSecondary;
    return ListTile(
      onTap: disabled ? null : onTap,
      leading: Icon(
        definition.requiresOAuth
            ? Icons.workspace_premium_outlined
            : Icons.key_outlined,
        color: iconColor,
        size: 22,
      ),
      title: Text(
        definition.displayName,
        style: TextStyle(
          color: fg,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        disabled ? 'Already connected' : definition.description,
        style: TextStyle(
          color: disabled ? AppTheme.textSecondary : AppTheme.textSecondary,
          fontSize: 12,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: disabled
          ? const Tooltip(
              message: 'You can only connect one account per subscription',
              child: Icon(
                Icons.lock_outline,
                color: AppTheme.textSecondary,
                size: 18,
              ),
            )
          : const Icon(
              Icons.chevron_right,
              color: AppTheme.textSecondary,
              size: 20,
            ),
    );
  }
}
