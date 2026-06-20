import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/fade_slide_in.dart';
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
                    child: _ProviderCard(
                      provider: p,
                      onTap: () => onTap(p.id),
                    ),
                  ),
                );
              } else {
                cells.add(const Expanded(child: SizedBox.shrink()));
              }
            }
            // Stagger only the first screenful so far-down cards are instant.
            final Duration delay = row < 6
                ? Duration(milliseconds: row * 50)
                : Duration.zero;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FadeSlideIn(
                delay: delay,
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: cells,
                  ),
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
              const SizedBox(height: 12),
              _Headline(models: provider.models),
            ],
          ),
        ),
      ),
    );
  }
}

/// A one-line summary derived from a provider's models: the cheapest non-free
/// output price ("from $X") or "Free" if every model is free, or "—" if no
/// prices are published. Gives the card something scannable without a full list.
class _Headline extends StatelessWidget {
  const _Headline({required this.models});

  final List<PricedModel> models;

  @override
  Widget build(BuildContext context) {
    double? cheapest;
    bool anyFree = false;
    for (final PricedModel m in models) {
      final ModelCost? cost = m.cost;
      if (cost == null) continue;
      if (cost.isFree) {
        anyFree = true;
        continue;
      }
      final double? price = cost.output ?? cost.input;
      if (price != null && (cheapest == null || price < cheapest)) {
        cheapest = price;
      }
    }

    final String text;
    if (cheapest != null) {
      text = 'from \$${_trim(cheapest, cheapest < 1 ? 3 : 2)} / 1M';
    } else if (anyFree) {
      text = 'Free';
    } else {
      text = 'No pricing';
    }

    return ShaderMask(
      shaderCallback: (Rect bounds) =>
          AppTheme.brandGradient.createShader(bounds),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static String _trim(double value, int decimals) {
    final String s = value.toStringAsFixed(decimals);
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}
