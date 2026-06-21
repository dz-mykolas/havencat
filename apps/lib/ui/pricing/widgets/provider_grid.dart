import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/model_pricing.dart';

/// The step-1 grid of providers. Each card shows the provider name, model count,
/// and a tiny headline derived from its models (e.g. cheapest output price).
/// Tapping a card drills into that provider's model list (step 2).
///
/// A leading [_CustomCard] (gradient-bordered, "Configure your own") is
/// prepended to the grid so users can wire up a custom endpoint without
/// digging into Settings. It only renders when [showCustomCard] is true —
/// callers that don't want it (e.g. the Labs tab) pass false.
class ProviderGrid extends StatelessWidget {
  const ProviderGrid({
    super.key,
    required this.providers,
    required this.onTap,
    this.showCustomCard = false,
    this.onAddCustom,
  });

  final List<ProviderModels> providers;
  final ValueChanged<String> onTap;

  /// Whether to render the leading "Custom endpoint" affordance.
  final bool showCustomCard;

  /// Invoked when the custom card is tapped. Required when [showCustomCard]
  /// is true.
  final VoidCallback? onAddCustom;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 640
            ? 3
            : (constraints.maxWidth >= 400 ? 2 : 1);
        // +1 row slot for the custom card when enabled.
        final int total = providers.length + (showCustomCard ? 1 : 0);
        final int rowCount = (total / columns).ceil();
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: rowCount,
          itemBuilder: (BuildContext context, int row) {
            final List<Widget> cells = <Widget>[];
            for (int col = 0; col < columns; col++) {
              if (col > 0) cells.add(const SizedBox(width: 12));
              final int index = row * columns + col;
              if (showCustomCard && index == 0) {
                cells.add(Expanded(child: _CustomCard(onTap: onAddCustom!)));
                continue;
              }
              final int providerIndex = showCustomCard ? index - 1 : index;
              if (providerIndex < providers.length) {
                final ProviderModels p = providers[providerIndex];
                cells.add(
                  Expanded(
                    child: _ProviderCard(provider: p, onTap: () => onTap(p.id)),
                  ),
                );
              } else {
                cells.add(const Expanded(child: SizedBox.shrink()));
              }
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: cells,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Leading affordance in the Providers grid: a gradient-bordered card that
/// opens the custom-endpoint dialog. Distinct from [_ProviderCard] so it
/// stands out as an action rather than a catalog entry.
class _CustomCard extends StatelessWidget {
  const _CustomCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.transparent),
            gradient: LinearGradient(
              colors: <Color>[
                AppTheme.brandBlue.withValues(alpha: 0.35),
                AppTheme.brandViolet.withValues(alpha: 0.35),
                AppTheme.brandPink.withValues(alpha: 0.35),
              ],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppTheme.brandViolet.withValues(alpha: 0.6),
              width: 1.5,
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.add_circle_outline,
                    size: 18,
                    color: AppTheme.brandViolet.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Custom endpoint',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Configure your own',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({required this.provider, required this.onTap});

  final ProviderModels provider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.outline),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      provider.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    color: AppTheme.textSecondary,
                    size: 20,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${provider.models.length} model${provider.models.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
