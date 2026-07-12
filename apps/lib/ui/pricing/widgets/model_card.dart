import 'package:flutter/material.dart';

import '../../../domain/models/model_pricing.dart';
import '../../core/theme/app_theme.dart';
import '../pricing_format.dart';

class ModelCard extends StatelessWidget {
  const ModelCard({super.key, required this.model, required this.onTap});

  final PricedModel model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ModelCost? cost = model.cost;
    final bool free = cost?.isFree ?? false;
    return Material(
      color: context.appColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 11, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _ModelMark(reasoning: model.reasoning),
                  SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          model.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.appColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          model.providerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.appColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (free) _FreeState(),
                  SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: context.appColors.textSecondary,
                  ),
                ],
              ),
              SizedBox(height: 9),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (cost?.hasHeadlinePricing ?? false)
                    _Meta(
                      icon: model.pricingOfficial
                          ? Icons.verified_outlined
                          : Icons.storefront_outlined,
                      label:
                          '${formatPricePerMillion(cost?.input)} · '
                          '${formatPricePerMillion(cost?.output)}',
                      tooltip: _pricingTooltip(model),
                    ),
                  if (model.contextLimit != null)
                    _Meta(
                      icon: Icons.data_object_rounded,
                      label: formatTokens(model.contextLimit),
                      tooltip: 'Context window',
                    ),
                  if (model.reasoning)
                    _Capability(
                      icon: Icons.psychology_outlined,
                      tooltip: 'Reasoning',
                      color: context.appColors.brandViolet,
                    ),
                  if (model.toolCall)
                    _Capability(
                      icon: Icons.build_outlined,
                      tooltip: 'Tool calling',
                      color: context.appColors.brandBlue,
                    ),
                  if (model.supportsVision)
                    _Capability(
                      icon: Icons.image_outlined,
                      tooltip: 'Vision',
                      color: context.appColors.brandPink,
                    ),
                  if (model.openWeights)
                    _Capability(
                      icon: Icons.lock_open_outlined,
                      tooltip: 'Open weights',
                      color: context.appColors.textSecondary,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _pricingTooltip(PricedModel model) {
    final String source = model.pricingProviderName ?? model.providerName;
    final String kind = model.pricingOfficial
        ? 'Official $source pricing'
        : 'Representative pricing from $source';
    return '$kind · input · output per 1M tokens';
  }
}

class _ModelMark extends StatelessWidget {
  const _ModelMark({required this.reasoning});

  final bool reasoning;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: context.appColors.surfaceHigh,
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: Icon(
        reasoning ? Icons.psychology_outlined : Icons.auto_awesome_outlined,
        size: 17,
        color: context.appColors.brandViolet,
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.label, required this.tooltip});

  final IconData icon;
  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: context.appColors.textSecondary),
          SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: context.appColors.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _Capability extends StatelessWidget {
  const _Capability({
    required this.icon,
    required this.tooltip,
    required this.color,
  });

  final IconData icon;
  final String tooltip;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Icon(icon, size: 14, color: color),
    );
  }
}

class _FreeState extends StatelessWidget {
  const _FreeState();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Free',
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: context.appColors.brandPink.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(7),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.money_off_csred_outlined,
          size: 14,
          color: context.appColors.brandPink,
        ),
      ),
    );
  }
}
