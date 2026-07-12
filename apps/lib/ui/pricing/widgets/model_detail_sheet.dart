import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/models/model_pricing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';
import '../pricing_format.dart';

Future<void> showModelDetailSheet(BuildContext context, PricedModel model) {
  final bool wide = MediaQuery.sizeOf(context).width >= AppTheme.wideBreakpoint;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, maxHeight: 720),
          child: _ModelDetail(model: model, showClose: true),
        ),
      ),
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      child: _ModelDetail(model: model),
    ),
  );
}

class _ModelDetail extends StatelessWidget {
  const _ModelDetail({required this.model, this.showClose = false});

  final PricedModel model;
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: AppScrollView(
        builder: (BuildContext context, AppScrollController controller) =>
            SingleChildScrollView(
              controller: controller,
              padding: EdgeInsets.fromLTRB(20, showClose ? 18 : 0, 20, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _IdentityHeader(model: model, showClose: showClose),
                  SizedBox(height: 22),
                  _Pricing(model: model),
                  SizedBox(height: 24),
                  _Limits(model: model),
                  if (_hasCapabilities(model)) ...<Widget>[
                    SizedBox(height: 24),
                    _Capabilities(model: model),
                  ],
                  SizedBox(height: 24),
                  _Metadata(model: model),
                ],
              ),
            ),
      ),
    );
  }

  static bool _hasCapabilities(PricedModel model) =>
      model.reasoning ||
      model.toolCall ||
      model.attachment ||
      model.supportsVision ||
      model.openWeights ||
      model.inputModalities.isNotEmpty ||
      model.outputModalities.isNotEmpty;
}

class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({required this.model, required this.showClose});

  final PricedModel model;
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: context.appColors.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Icon(
            model.reasoning
                ? Icons.psychology_outlined
                : Icons.auto_awesome_outlined,
            size: 21,
            color: context.appColors.brandViolet,
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                model.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.appColors.textPrimary,
                  fontSize: 18,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 3),
              Text(
                model.providerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.appColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
        if (showClose)
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close_rounded, size: 20),
            color: context.appColors.textSecondary,
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _Pricing extends StatelessWidget {
  const _Pricing({required this.model});

  final PricedModel model;

  @override
  Widget build(BuildContext context) {
    final ModelCost? cost = model.cost;
    final bool hasPrice = cost?.hasHeadlinePricing ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          icon: Icons.payments_outlined,
          title: 'Pricing',
          trailing: model.pricingProviderName == null
              ? null
              : _PricingSource(model: model),
        ),
        SizedBox(height: 14),
        if (!hasPrice)
          _QuietMessage(
            icon: Icons.money_off_csred_outlined,
            text: 'No published pricing',
          )
        else ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: _PrimaryMetric(
                  label: 'Input',
                  value: formatPricePerMillion(cost?.input),
                ),
              ),
              SizedBox(width: 24),
              Expanded(
                child: _PrimaryMetric(
                  label: 'Output',
                  value: formatPricePerMillion(cost?.output),
                ),
              ),
            ],
          ),
          if (cost?.reasoning != null ||
              cost?.cacheRead != null ||
              cost?.cacheWrite != null) ...<Widget>[
            SizedBox(height: 13),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: <Widget>[
                if (cost?.reasoning != null)
                  _InlineMetric(
                    label: 'Reasoning',
                    value: formatPricePerMillion(cost?.reasoning),
                  ),
                if (cost?.cacheRead != null)
                  _InlineMetric(
                    label: 'Cache read',
                    value: formatPricePerMillion(cost?.cacheRead),
                  ),
                if (cost?.cacheWrite != null)
                  _InlineMetric(
                    label: 'Cache write',
                    value: formatPricePerMillion(cost?.cacheWrite),
                  ),
              ],
            ),
          ],
          SizedBox(height: 8),
          Text(
            'USD per 1M tokens',
            style: TextStyle(
              color: context.appColors.textSecondary,
              fontSize: 10.5,
            ),
          ),
        ],
      ],
    );
  }
}

class _PricingSource extends StatelessWidget {
  const _PricingSource({required this.model});

  final PricedModel model;

  @override
  Widget build(BuildContext context) {
    final String provider = model.pricingProviderName!;
    final String message = model.pricingOfficial
        ? 'Official pricing from $provider'
        : 'Representative pricing from $provider';
    return Tooltip(
      message: message,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            model.pricingOfficial
                ? Icons.verified_outlined
                : Icons.storefront_outlined,
            size: 14,
            color: context.appColors.textSecondary,
          ),
          SizedBox(width: 5),
          Flexible(
            child: Text(
              provider,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.appColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Limits extends StatelessWidget {
  const _Limits({required this.model});

  final PricedModel model;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(icon: Icons.data_object_rounded, title: 'Limits'),
        SizedBox(height: 14),
        Row(
          children: <Widget>[
            Expanded(
              child: _PrimaryMetric(
                label: 'Context',
                value: formatTokens(model.contextLimit),
                suffix: 'tokens',
              ),
            ),
            SizedBox(width: 24),
            Expanded(
              child: _PrimaryMetric(
                label: 'Max output',
                value: formatTokens(model.outputLimit),
                suffix: 'tokens',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Capabilities extends StatelessWidget {
  const _Capabilities({required this.model});

  final PricedModel model;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          icon: Icons.auto_awesome_outlined,
          title: 'Capabilities',
        ),
        SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (model.reasoning)
              _Capability(
                icon: Icons.psychology_outlined,
                label: 'Reasoning',
                color: context.appColors.brandViolet,
              ),
            if (model.toolCall)
              _Capability(
                icon: Icons.build_outlined,
                label: 'Tools',
                color: context.appColors.brandBlue,
              ),
            if (model.supportsVision)
              _Capability(
                icon: Icons.image_outlined,
                label: 'Vision',
                color: context.appColors.brandPink,
              ),
            if (model.attachment)
              _Capability(
                icon: Icons.attach_file_rounded,
                label: 'Files',
                color: context.appColors.textSecondary,
              ),
            if (model.openWeights)
              _Capability(
                icon: Icons.lock_open_outlined,
                label: 'Open weights',
                color: context.appColors.textSecondary,
              ),
          ],
        ),
        if (model.inputModalities.isNotEmpty ||
            model.outputModalities.isNotEmpty) ...<Widget>[
          SizedBox(height: 13),
          if (model.inputModalities.isNotEmpty)
            _ModalityLine(
              icon: Icons.login_rounded,
              label: 'In',
              values: model.inputModalities,
            ),
          if (model.outputModalities.isNotEmpty) ...<Widget>[
            SizedBox(height: 7),
            _ModalityLine(
              icon: Icons.logout_rounded,
              label: 'Out',
              values: model.outputModalities,
            ),
          ],
        ],
      ],
    );
  }
}

class _Metadata extends StatelessWidget {
  const _Metadata({required this.model});

  final PricedModel model;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(icon: Icons.fingerprint_rounded, title: 'Model ID'),
        SizedBox(height: 10),
        _CopyId(id: model.id),
        if (model.releaseDate != null || model.lastUpdated != null) ...<Widget>[
          SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: <Widget>[
              if (model.releaseDate != null)
                _InlineMetric(
                  label: 'Released',
                  value: _date(model.releaseDate!),
                ),
              if (model.lastUpdated != null)
                _InlineMetric(
                  label: 'Updated',
                  value: _date(model.lastUpdated!),
                ),
            ],
          ),
        ],
      ],
    );
  }

  static String _date(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: context.appColors.textSecondary),
        SizedBox(width: 7),
        Text(
          title,
          style: TextStyle(
            color: context.appColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (trailing != null) ...<Widget>[Spacer(), Flexible(child: trailing!)],
      ],
    );
  }
}

class _PrimaryMetric extends StatelessWidget {
  const _PrimaryMetric({required this.label, required this.value, this.suffix});

  final String label;
  final String value;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: context.appColors.textPrimary,
            fontSize: 21,
            height: 1.05,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 4),
        Text(
          suffix == null ? label : '$label · $suffix',
          style: TextStyle(
            color: context.appColors.textSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _InlineMetric extends StatelessWidget {
  const _InlineMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: '$label  ',
            style: TextStyle(
              color: context.appColors.textSecondary,
              fontSize: 11,
            ),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
              color: context.appColors.textPrimary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
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
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 15, color: color),
        SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: context.appColors.textSecondary,
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _ModalityLine extends StatelessWidget {
  const _ModalityLine({
    required this.icon,
    required this.label,
    required this.values,
  });

  final IconData icon;
  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 14, color: context.appColors.textSecondary),
        SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: context.appColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            values.map(_titleCase).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.appColors.textPrimary,
              fontSize: 11.5,
            ),
          ),
        ),
      ],
    );
  }

  static String _titleCase(String value) => value.isEmpty
      ? value
      : '${value[0].toUpperCase()}${value.substring(1).toLowerCase()}';
}

class _CopyId extends StatelessWidget {
  const _CopyId({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.appColors.surfaceHigh,
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _copy(context),
        child: Padding(
          padding: EdgeInsets.fromLTRB(11, 9, 8, 9),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.appColors.textPrimary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              SizedBox(width: 8),
              Icon(
                Icons.copy_outlined,
                size: 16,
                color: context.appColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Model ID copied'),
        duration: Duration(seconds: 1),
      ),
    );
  }
}

class _QuietMessage extends StatelessWidget {
  const _QuietMessage({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: context.appColors.textSecondary),
        SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            color: context.appColors.textSecondary,
            fontSize: 12.5,
          ),
        ),
      ],
    );
  }
}
