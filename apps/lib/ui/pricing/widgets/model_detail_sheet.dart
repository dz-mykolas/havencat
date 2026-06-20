import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/model_pricing.dart';
import '../pricing_format.dart';

/// Opens the full pricing/capability breakdown for [model] in a bottom sheet.
Future<void> showModelDetailSheet(BuildContext context, PricedModel model) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (BuildContext context) => _ModelDetailSheet(model: model),
  );
}

class _ModelDetailSheet extends StatelessWidget {
  const _ModelDetailSheet({required this.model});

  final PricedModel model;

  @override
  Widget build(BuildContext context) {
    final ModelCost? cost = model.cost;
    final double maxHeight = MediaQuery.of(context).size.height * 0.85;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                model.name,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                model.providerName,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 20),
              _SectionTitle('Pricing — USD per 1M tokens'),
              const SizedBox(height: 10),
              if (cost == null)
                const _Empty('No published pricing for this model.')
              else ...<Widget>[
                _CostRow(label: 'Input', value: cost.input),
                _CostRow(label: 'Output', value: cost.output),
                if (cost.reasoning != null)
                  _CostRow(label: 'Reasoning', value: cost.reasoning),
                if (cost.cacheRead != null)
                  _CostRow(label: 'Cache read', value: cost.cacheRead),
                if (cost.cacheWrite != null)
                  _CostRow(label: 'Cache write', value: cost.cacheWrite),
              ],
              const SizedBox(height: 22),
              _SectionTitle('Limits'),
              const SizedBox(height: 10),
              _InfoRow(
                label: 'Context window',
                value: '${formatTokens(model.contextLimit)} tokens',
              ),
              _InfoRow(
                label: 'Max output',
                value: '${formatTokens(model.outputLimit)} tokens',
              ),
              const SizedBox(height: 22),
              _SectionTitle('Capabilities'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _Tag('Reasoning', model.reasoning),
                  _Tag('Tool calling', model.toolCall),
                  _Tag('Attachments', model.attachment),
                  _Tag('Vision', model.supportsVision),
                  _Tag('Open weights', model.openWeights),
                ],
              ),
              if (model.inputModalities.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                _InfoRow(
                  label: 'Input',
                  value: model.inputModalities.join(', '),
                ),
                _InfoRow(
                  label: 'Output',
                  value: model.outputModalities.join(', '),
                ),
              ],
              const SizedBox(height: 22),
              _SectionTitle('Identifier'),
              const SizedBox(height: 10),
              _ModelIdRow(id: model.id),
              if (model.releaseDate != null) ...<Widget>[
                const SizedBox(height: 16),
                _InfoRow(
                  label: 'Released',
                  value: _date(model.releaseDate!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: AppTheme.textSecondary,
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }
}

class _CostRow extends StatelessWidget {
  const _CostRow({required this.label, required this.value});

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 14,
            ),
          ),
          Text(
            formatPricePerMillion(value),
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, this.enabled);

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: enabled ? AppTheme.surfaceHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: enabled ? AppTheme.brandViolet : AppTheme.outline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            enabled ? Icons.check_circle : Icons.remove_circle_outline,
            size: 14,
            color: enabled ? AppTheme.brandViolet : AppTheme.textSecondary,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: enabled ? AppTheme.textPrimary : AppTheme.textSecondary,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelIdRow extends StatelessWidget {
  const _ModelIdRow({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              id,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13.5,
                fontFamily: 'monospace',
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy id',
            icon: const Icon(Icons.copy_outlined, size: 18),
            color: AppTheme.textSecondary,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: id));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Copied "$id"'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
    );
  }
}
