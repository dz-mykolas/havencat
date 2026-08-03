import 'package:flutter/material.dart';

import '../../../domain/models/model_pricing.dart';
import '../../../domain/models/provider_account.dart';
import '../../../domain/models/provider_definition.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';
import '../../pricing/pricing_viewmodel.dart';
import '../../pricing/quick_add_resolver.dart';
import '../../pricing/widgets/custom_endpoint_dialog.dart';
import '../../pricing/widgets/quick_add_sheet.dart';
import '../settings_viewmodel.dart';
import 'chatgpt_login_dialog.dart';
import 'poe_login_dialog.dart';

Future<void> showAccountConnectionPicker(
  BuildContext context,
  SettingsViewModel settings,
  PricingViewModel pricing,
) async {
  final bool wide = MediaQuery.sizeOf(context).width >= AppTheme.wideBreakpoint;
  final _ConnectionChoice? choice;
  if (wide) {
    choice = await showDialog<_ConnectionChoice>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 540, maxHeight: 680),
          child: _AccountConnectionContent(
            settings: settings,
            pricing: pricing,
            onSelected: (choice) => Navigator.of(dialogContext).pop(choice),
          ),
        ),
      ),
    );
  } else {
    choice = await showModalBottomSheet<_ConnectionChoice>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => FractionallySizedBox(
        heightFactor: 0.88,
        child: SafeArea(
          top: false,
          child: _AccountConnectionContent(
            settings: settings,
            pricing: pricing,
            onSelected: (choice) => Navigator.of(sheetContext).pop(choice),
          ),
        ),
      ),
    );
  }
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case _SubscriptionChoice(:final definition):
      showSubscriptionLogin(context, settings, definition);
    case _ApiProviderChoice(:final provider, :final definition):
      await showQuickAdd(context, settings, provider, definition);
    case _CustomEndpointChoice():
      await showCustomEndpointDialog(context, settings);
  }
}

void showSubscriptionLogin(
  BuildContext context,
  SettingsViewModel viewModel,
  ProviderDefinition definition,
) {
  switch (definition.authMethod) {
    case ProviderAuthMethod.chatGptDeviceCode:
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) =>
            ChatGptLoginDialog(viewModel: viewModel),
      );
    case ProviderAuthMethod.poeOAuth:
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => PoeLoginDialog(viewModel: viewModel),
      );
    case ProviderAuthMethod.apiKey:
      throw StateError('${definition.id} is not a subscription provider');
  }
}

sealed class _ConnectionChoice {
  const _ConnectionChoice();
}

class _SubscriptionChoice extends _ConnectionChoice {
  const _SubscriptionChoice(this.definition);

  final ProviderDefinition definition;
}

class _ApiProviderChoice extends _ConnectionChoice {
  const _ApiProviderChoice(this.provider, this.definition);

  final ProviderModels provider;
  final ProviderDefinition definition;
}

class _CustomEndpointChoice extends _ConnectionChoice {
  const _CustomEndpointChoice();
}

class _AccountConnectionContent extends StatefulWidget {
  const _AccountConnectionContent({
    required this.settings,
    required this.pricing,
    required this.onSelected,
  });

  final SettingsViewModel settings;
  final PricingViewModel pricing;
  final ValueChanged<_ConnectionChoice> onSelected;

  @override
  State<_AccountConnectionContent> createState() =>
      _AccountConnectionContentState();
}

class _AccountConnectionContentState extends State<_AccountConnectionContent> {
  final TextEditingController _search = TextEditingController();
  bool _showApiProviders = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _PickerHeader(
          title: _showApiProviders ? 'API provider' : 'Connect account',
          subtitle: _showApiProviders
              ? 'Choose the service this API key belongs to.'
              : 'Subscriptions, API keys, and local endpoints live together.',
          onBack: _showApiProviders
              ? () {
                  _search.clear();
                  setState(() => _showApiProviders = false);
                }
              : null,
        ),
        Divider(height: 1),
        Expanded(
          child: _showApiProviders
              ? _ApiProviderList(
                  pricing: widget.pricing,
                  settings: widget.settings,
                  search: _search,
                  onChanged: () => setState(() {}),
                  onSelected: (ProviderModels provider) {
                    if (connectableApiDefinitionFor(provider)
                        case final ProviderDefinition definition) {
                      widget.onSelected(
                        _ApiProviderChoice(provider, definition),
                      );
                    }
                  },
                )
              : _ConnectionKinds(
                  settings: widget.settings,
                  pricing: widget.pricing,
                  onSubscription: (ProviderDefinition definition) =>
                      widget.onSelected(_SubscriptionChoice(definition)),
                  onApiProviders: () =>
                      setState(() => _showApiProviders = true),
                  onCustomEndpoint: () =>
                      widget.onSelected(const _CustomEndpointChoice()),
                ),
        ),
      ],
    );
  }
}

class _PickerHeader extends StatelessWidget {
  const _PickerHeader({
    required this.title,
    required this.subtitle,
    this.onBack,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(onBack == null ? 20 : 8, 16, 20, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (onBack != null) ...<Widget>[
            IconButton(
              tooltip: 'Back',
              onPressed: onBack,
              icon: Icon(Icons.arrow_back_rounded),
              style: context.navigationButtonStyle,
            ),
            SizedBox(width: 2),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: context.appColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: context.appColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionKinds extends StatelessWidget {
  const _ConnectionKinds({
    required this.settings,
    required this.pricing,
    required this.onSubscription,
    required this.onApiProviders,
    required this.onCustomEndpoint,
  });

  final SettingsViewModel settings;
  final PricingViewModel pricing;
  final ValueChanged<ProviderDefinition> onSubscription;
  final VoidCallback onApiProviders;
  final VoidCallback onCustomEndpoint;

  @override
  Widget build(BuildContext context) {
    return AppScrollView(
      builder: (BuildContext context, AppScrollController controller) =>
          ListView(
            controller: controller,
            padding: EdgeInsets.fromLTRB(12, 8, 12, 18),
            children: <Widget>[
              _SectionLabel('SUBSCRIPTIONS'),
              for (final ProviderDefinition definition
                  in settings.subscriptionCatalog)
                _ConnectionTile(
                  icon: Icons.workspace_premium_outlined,
                  title: definition.displayName,
                  subtitle: definition.description,
                  connectedCount: _connectedCount(
                    settings.accounts,
                    definition,
                  ),
                  onTap: () => onSubscription(definition),
                ),
              _SectionLabel('API & LOCAL'),
              ListenableBuilder(
                listenable: pricing,
                builder: (BuildContext context, _) {
                  final int supported =
                      (pricing.catalog?.providers ?? const <ProviderModels>[])
                          .where(
                            (ProviderModels provider) =>
                                connectableApiDefinitionFor(provider) != null,
                          )
                          .length;
                  return _ConnectionTile(
                    icon: Icons.key_outlined,
                    title: 'API provider',
                    subtitle: pricing.loading && supported == 0
                        ? 'Provider catalog is loading…'
                        : pricing.error != null && supported == 0
                        ? 'Provider catalog unavailable'
                        : 'Choose from $supported supported providers',
                    onTap: onApiProviders,
                  );
                },
              ),
              _ConnectionTile(
                icon: Icons.lan_outlined,
                title: 'Custom endpoint',
                subtitle: 'Connect a compatible hosted or local model server.',
                onTap: onCustomEndpoint,
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(10, 14, 10, 0),
                child: Text(
                  'You can connect the same service more than once.',
                  style: TextStyle(
                    color: context.appColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
    );
  }

  int _connectedCount(
    List<ProviderAccount> accounts,
    ProviderDefinition definition,
  ) {
    return accounts
        .where(
          (ProviderAccount account) =>
              account.config['definitionId'] == definition.id,
        )
        .length;
  }
}

class _ApiProviderList extends StatelessWidget {
  const _ApiProviderList({
    required this.pricing,
    required this.settings,
    required this.search,
    required this.onChanged,
    required this.onSelected,
  });

  final PricingViewModel pricing;
  final SettingsViewModel settings;
  final TextEditingController search;
  final VoidCallback onChanged;
  final ValueChanged<ProviderModels> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: pricing,
      builder: (BuildContext context, _) {
        final String query = search.text.trim().toLowerCase();
        final List<ProviderModels> providers =
            (pricing.catalog?.providers ?? const <ProviderModels>[])
                .where(
                  (ProviderModels provider) =>
                      connectableApiDefinitionFor(provider) != null,
                )
                .where(
                  (ProviderModels provider) =>
                      query.isEmpty ||
                      provider.name.toLowerCase().contains(query) ||
                      provider.id.toLowerCase().contains(query),
                )
                .toList()
              ..sort(
                (ProviderModels a, ProviderModels b) =>
                    a.name.toLowerCase().compareTo(b.name.toLowerCase()),
              );

        return Column(
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: TextField(
                controller: search,
                autofocus: true,
                onChanged: (_) => onChanged(),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search providers',
                  prefixIcon: Icon(Icons.search_rounded, size: 19),
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          onPressed: () {
                            search.clear();
                            onChanged();
                          },
                          icon: Icon(Icons.close_rounded, size: 18),
                        ),
                  filled: true,
                  fillColor: context.appColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: pricing.loading && providers.isEmpty
                  ? Center(child: CircularProgressIndicator())
                  : pricing.error != null && providers.isEmpty
                  ? _CatalogError(onRetry: pricing.load)
                  : providers.isEmpty
                  ? Center(
                      child: Text(
                        query.isEmpty
                            ? 'No supported API providers found'
                            : 'No providers match your search',
                        style: TextStyle(
                          color: context.appColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : AppScrollView(
                      builder:
                          (
                            BuildContext context,
                            AppScrollController controller,
                          ) => ListView.builder(
                            controller: controller,
                            padding: EdgeInsets.fromLTRB(12, 4, 12, 18),
                            itemCount: providers.length,
                            itemBuilder: (BuildContext context, int index) {
                              final ProviderModels provider = providers[index];
                              return _ConnectionTile(
                                icon: Icons.cloud_outlined,
                                title: provider.name,
                                subtitle:
                                    '${provider.models.length} available models',
                                connectedCount: settings.accounts
                                    .where(
                                      (ProviderAccount account) =>
                                          account.config['catalogProviderId'] ==
                                          provider.id,
                                    )
                                    .length,
                                onTap: () => onSelected(provider),
                              );
                            },
                          ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _CatalogError extends StatelessWidget {
  const _CatalogError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.cloud_off_outlined,
            color: context.appColors.textSecondary,
            size: 28,
          ),
          SizedBox(height: 8),
          Text(
            "Couldn't load providers",
            style: TextStyle(
              color: context.appColors.textPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 8),
          TextButton.icon(
            onPressed: onRetry,
            icon: Icon(Icons.refresh_rounded, size: 17),
            label: Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 14, 10, 5),
      child: Text(
        text,
        style: TextStyle(
          color: context.appColors.textSecondary,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.connectedCount = 0,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final int connectedCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 5),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: context.appColors.surface,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    icon,
                    size: 18,
                    color: context.appColors.brandViolet,
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.appColors.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (connectedCount > 0) ...<Widget>[
                            SizedBox(width: 7),
                            Text(
                              '$connectedCount connected',
                              style: TextStyle(
                                color: context.appColors.textSecondary,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ],
                      ),
                      SizedBox(height: 1),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.appColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: context.appColors.textSecondary,
                  size: 19,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
