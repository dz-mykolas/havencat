import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../../domain/models/provider_account.dart';
import 'settings_viewmodel.dart';
import 'widgets/account_tile.dart';
import 'widgets/provider_picker.dart' show showProviderPicker;

/// Lists configured provider accounts, lets the user pick the active one,
/// and add/remove accounts. Adding an API-key account writes the key to
/// `SecretStore` via [SettingsViewModel.addApiKeyAccount].
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SettingsViewModel vm = ref.watch(settingsViewModelProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Add account',
            icon: const Icon(Icons.person_add_alt_1_outlined),
            onPressed: () => _addAccount(context, vm),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: vm,
        builder: (BuildContext context, _) {
          final List<ProviderAccount> accounts = vm.accounts;
          if (accounts.isEmpty) {
            return _EmptyAccounts(onAdd: () => _addAccount(context, vm));
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: <Widget>[
              const _SectionLabel('Accounts'),
              for (final ProviderAccount account in accounts)
                AccountTile(
                  account: account,
                  active: account.id == vm.activeAccountId,
                  onTap: () => vm.setActive(account.id),
                  onDelete: () => _confirmDelete(context, vm, account),
                ),
              const SizedBox(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: _SecureStorageNote(),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  void _addAccount(BuildContext context, SettingsViewModel vm) {
    showProviderPicker(context, vm);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    SettingsViewModel vm,
    ProviderAccount account,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Remove account?'),
          content: Text(
            'Remove "${account.displayName}" and its stored API key? '
            'This cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await vm.remove(account.id);
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _EmptyAccounts extends StatelessWidget {
  const _EmptyAccounts({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.cloud_off_outlined,
            size: 48,
            color: AppTheme.textSecondary,
          ),
          const SizedBox(height: 16),
          const Text(
            'No provider accounts yet',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Add an API key to start chatting.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add account'),
          ),
        ],
      ),
    );
  }
}

class _SecureStorageNote extends StatelessWidget {
  const _SecureStorageNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.lock_outline, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            "API keys are stored in this device's secure storage and never "
            'leave it except to call the provider directly.',
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
