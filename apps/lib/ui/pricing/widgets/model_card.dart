import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/model_pricing.dart';
import '../pricing_format.dart';

/// A single model in the pricing list: name + provider, headline input/output
/// price, and a row of capability chips. Tapping opens the detail sheet.
class ModelCard extends StatelessWidget {
  const ModelCard({super.key, required this.model, required this.onTap});

  final PricedModel model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ModelCost? cost = model.cost;
    final bool free = cost?.isFree ?? false;

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
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          model.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          model.providerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (free) const _FreeBadge(),
                ],
              ),
              const SizedBox(height: 14),
              if (!free)
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _PricePill(
                        label: 'Input',
                        value: formatPricePerMillion(cost?.input),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _PricePill(
                        label: 'Output',
                        value: formatPricePerMillion(cost?.output),
                      ),
                    ),
                  ],
                )
              else
                Text(
                  'No usage charge',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  if (model.contextLimit != null)
                    _CapChip(
                      icon: Icons.view_column_outlined,
                      label: '${formatTokens(model.contextLimit)} ctx',
                    ),
                  if (model.reasoning)
                    const _CapChip(
                      icon: Icons.psychology_outlined,
                      label: 'Reasoning',
                    ),
                  if (model.toolCall)
                    const _CapChip(
                      icon: Icons.build_outlined,
                      label: 'Tools',
                    ),
                  if (model.supportsVision)
                    const _CapChip(
                      icon: Icons.image_outlined,
                      label: 'Vision',
                    ),
                  if (model.openWeights)
                    const _CapChip(
                      icon: Icons.lock_open_outlined,
                      label: 'Open',
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "$/M tokens" caption shared under each price pill value.
const String kPerMillionCaption = 'per 1M tokens';

class _PricePill extends StatelessWidget {
  const _PricePill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 3),
          ShaderMask(
            shaderCallback: (Rect bounds) =>
                AppTheme.brandGradient.createShader(bounds),
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 1),
          Text(
            kPerMillionCaption,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _CapChip extends StatelessWidget {
  const _CapChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: AppTheme.textSecondary),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _FreeBadge extends StatelessWidget {
  const _FreeBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Text(
        'Free',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
