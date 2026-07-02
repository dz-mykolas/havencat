import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/adapter_kind.dart';
import '../../../domain/models/provider_account.dart';

/// A single row in the accounts list: kind icon, display name + kind label,
/// and action buttons (manage models, remove).
///
/// This tile is purely for account management — selecting the active account
/// happens in the chat header's provider picker, not here. The remove button
/// removes the account (the caller is responsible for confirming).
class AccountTile extends StatelessWidget {
  const AccountTile({
    super.key,
    required this.account,
    required this.onDelete,
    this.onManageModels,
  });

  final ProviderAccount account;
  final VoidCallback onDelete;

  /// Opens the Manage Models sheet for this account. When null, the manage
  /// button is hidden (e.g. for the mock seed account, which has no real
  /// provider behind it).
  final VoidCallback? onManageModels;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(
              _iconFor(account.kind),
              size: 20,
              color: AppTheme.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    account.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _labelFor(account.kind),
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (onManageModels != null)
                  IconButton(
                    icon: const Icon(Icons.tune, size: 18),
                    tooltip: 'Manage models',
                    onPressed: onManageModels,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'Remove account',
                  onPressed: onDelete,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(AdapterKind kind) {
    switch (kind) {
      case AdapterKind.subscription:
        return Icons.workspace_premium_outlined;
      case AdapterKind.openaiCompatible:
      case AdapterKind.anthropic:
      case AdapterKind.geminiNative:
        return Icons.cloud_outlined;
      case AdapterKind.onDevice:
        return Icons.phone_android_outlined;
      case AdapterKind.mock:
        return Icons.science_outlined;
    }
  }

  static String _labelFor(AdapterKind kind) {
    switch (kind) {
      case AdapterKind.subscription:
        return 'Subscription';
      case AdapterKind.openaiCompatible:
        return 'OpenAI-compatible · API key';
      case AdapterKind.anthropic:
        return 'Anthropic · API key';
      case AdapterKind.geminiNative:
        return 'Gemini · API key';
      case AdapterKind.onDevice:
        return 'On-device';
      case AdapterKind.mock:
        return 'Mock · no key needed';
    }
  }
}
