import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/widgets/fade_slide_in.dart';
import '../../data/services/storage/app_settings.dart';
import '../../domain/models/provider_account.dart';
import '../../providers.dart';
import '../pricing/pricing_screen.dart';
import 'settings_viewmodel.dart';
import 'widgets/account_tile.dart';
import 'widgets/provider_picker.dart' show showProviderPicker;

/// Lists configured provider accounts, lets the user pick the active one,
/// and add/remove accounts. Adding an API-key account writes the key to
/// `SecretStore` via [SettingsViewModel.addApiKeyAccount].
///
/// Layout is responsive: on desktop/wide screens the content is centered in a
/// fixed-width column (so it doesn't hug the left edge); on phones it's a
/// single edge-to-edge column. Sections animate in with a soft stagger.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SettingsViewModel vm = ref.watch(settingsViewModelProvider);
    final AppSettings settings = ref.watch(appSettingsProvider);
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
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppTheme.panelMaxWidth),
            child: ListenableBuilder(
              listenable: vm,
              builder: (BuildContext context, _) {
                final List<ProviderAccount> accounts = vm.accounts;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: <Widget>[
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 20),
                      child: _Section(
                        label: 'Accounts',
                        child: accounts.isEmpty
                            ? _EmptyAccounts(
                                onAdd: () => _addAccount(context, vm),
                              )
                            : _AccountsCard(
                                accounts: accounts,
                                activeId: vm.activeAccountId,
                                onActivate: vm.setActive,
                                onDelete: (ProviderAccount a) =>
                                    _confirmDelete(context, vm, a),
                              ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 90),
                      child: _Section(
                        label: 'Discover',
                        child: const _PricingEntry(),
                      ),
                    ),
                    const SizedBox(height: 24),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 160),
                      child: _Section(
                        label: 'Preferences',
                        child: _PreferencesCard(settings: settings),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const FadeSlideIn(
                      delay: Duration(milliseconds: 230),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: _SecureStorageNote(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
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

/// A labelled group: a small caption above a content area.
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Rounded surface container used to group related controls into a "card".
class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    // A [Material] (not a plain DecoratedBox) so any ListTile/InkWell children
    // paint their background + ink on this surface rather than asserting.
    return Material(
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(6),
        child: child,
      ),
    );
  }
}

class _AccountsCard extends StatelessWidget {
  const _AccountsCard({
    required this.accounts,
    required this.activeId,
    required this.onActivate,
    required this.onDelete,
  });

  final List<ProviderAccount> accounts;
  final String? activeId;
  final ValueChanged<String> onActivate;
  final ValueChanged<ProviderAccount> onDelete;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        children: <Widget>[
          for (final ProviderAccount account in accounts)
            AccountTile(
              account: account,
              active: account.id == activeId,
              onTap: () => onActivate(account.id),
              onDelete: () => onDelete(account),
            ),
        ],
      ),
    );
  }
}

/// Tappable entry that opens the models.dev pricing browser.
class _PricingEntry extends StatelessWidget {
  const _PricingEntry();

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PricingScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: AppTheme.brandGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.payments_outlined,
                    color: Colors.white,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Model pricing',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Live cost & capabilities for every model · models.dev',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.chevron_right,
                  color: AppTheme.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreferencesCard extends StatelessWidget {
  const _PreferencesCard({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SwitchListTile(
        value: settings.showHiddenModels,
        onChanged: settings.setShowHiddenModels,
        title: const Text(
          'Show hidden models',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
        ),
        subtitle: const Text(
          "Include models providers mark as internal (e.g. ChatGPT's "
          'codex-auto-review). Off by default.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
    );
  }
}

class _EmptyAccounts extends StatelessWidget {
  const _EmptyAccounts({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      child: Center(
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
