import 'package:flutter/material.dart';

import '../../../domain/models/model_pricing.dart';
import '../pricing_format.dart';

class ModelCard extends StatelessWidget {
  const ModelCard({super.key, required this.model, required this.onTap});

  final PricedModel model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final ModelCost? cost = model.cost;
    final bool free = cost?.isFree ?? false;
    final BorderRadius borderRadius = BorderRadius.circular(18);
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 11, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _ModelMark(reasoning: model.reasoning),
                  SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          model.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 1),
                        Text(
                          model.providerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (free) ...<Widget>[
                    _Badge(
                      label: 'Free',
                      color: colors.tertiary,
                      foreground: colors.onTertiary,
                    ),
                    SizedBox(width: 5),
                  ],
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 17,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
              SizedBox(height: 9),
              Row(
                children: <Widget>[
                  if (cost?.hasHeadlinePricing ?? false)
                    Expanded(
                      child: _Fact(
                        icon: model.pricingOfficial
                            ? Icons.verified_outlined
                            : Icons.storefront_outlined,
                        text:
                            '${formatPricePerMillion(cost?.input)} in  ·  '
                            '${formatPricePerMillion(cost?.output)} out',
                        tooltip: _pricingTooltip(model),
                      ),
                    )
                  else
                    Spacer(),
                  if (model.contextLimit != null)
                    _Fact(
                      icon: Icons.data_object_rounded,
                      text: formatTokens(model.contextLimit),
                      tooltip: 'Context window',
                    ),
                  if (_hasCapabilities(model)) ...<Widget>[
                    SizedBox(width: 7),
                    _CapabilityCluster(model: model),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _hasCapabilities(PricedModel model) =>
      model.reasoning ||
      model.toolCall ||
      model.supportsVision ||
      model.openWeights;

  String _pricingTooltip(PricedModel model) {
    final String source = model.pricingProviderName ?? model.providerName;
    final String kind = model.pricingOfficial
        ? 'Official $source pricing'
        : 'Representative pricing from $source';
    return '$kind · input and output per 1M tokens';
  }
}

class _ModelMark extends StatelessWidget {
  const _ModelMark({required this.reasoning});

  final bool reasoning;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 30,
      height: 38,
      child: Icon(
        reasoning ? Icons.psychology_outlined : Icons.auto_awesome_outlined,
        size: 21,
        color: colors.primary,
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text, required this.tooltip});

  final IconData icon;
  final String text;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
          SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityCluster extends StatelessWidget {
  const _CapabilityCluster({required this.model});

  final PricedModel model;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: ShapeDecoration(
        color: colors.surfaceContainerHigh.withValues(alpha: 0.86),
        shape: StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (model.reasoning)
            _CapabilityIcon(
              icon: Icons.psychology_outlined,
              tooltip: 'Reasoning',
              color: colors.primary,
            ),
          if (model.toolCall)
            _CapabilityIcon(
              icon: Icons.build_outlined,
              tooltip: 'Tool calling',
              color: colors.secondary,
            ),
          if (model.supportsVision)
            _CapabilityIcon(
              icon: Icons.image_outlined,
              tooltip: 'Vision',
              color: colors.tertiary,
            ),
          if (model.openWeights)
            _CapabilityIcon(
              icon: Icons.lock_open_outlined,
              tooltip: 'Open weights',
              color: colors.onSurfaceVariant,
            ),
        ],
      ),
    );
  }
}

class _CapabilityIcon extends StatelessWidget {
  const _CapabilityIcon({
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
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 2),
        child: Icon(icon, size: 13, color: color),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.color,
    required this.foreground,
  });

  final String label;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: ShapeDecoration(color: color, shape: StadiumBorder()),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
