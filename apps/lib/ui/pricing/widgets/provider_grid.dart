import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/model_pricing.dart';

/// The step-1 grid of providers. Each card shows the provider name, model count,
/// and a tiny headline derived from its models (e.g. cheapest output price).
/// Tapping a card drills into that provider's model list (step 2).
class ProviderGrid extends StatelessWidget {
  const ProviderGrid({super.key, required this.providers, required this.onTap});

  final List<ProviderModels> providers;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 640
            ? 3
            : (constraints.maxWidth >= 400 ? 2 : 1);
        final int rowCount = (providers.length / columns).ceil();
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: rowCount,
          itemBuilder: (BuildContext context, int row) {
            final List<Widget> cells = <Widget>[];
            for (int col = 0; col < columns; col++) {
              if (col > 0) cells.add(const SizedBox(width: 12));
              final int index = row * columns + col;
              if (index < providers.length) {
                final ProviderModels p = providers[index];
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
