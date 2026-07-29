import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/models/model_pricing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/card_visual_theme.dart';
import '../../core/widgets/app_scroll_view.dart';
import '../../core/widgets/card_visual.dart';
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
    showDragHandle: false,
    enableDrag: false,
    clipBehavior: Clip.antiAlias,
    builder: (BuildContext context) => _ModelDetailBottomSheet(model: model),
  );
}

class ModelDetailRoute extends StatelessWidget {
  const ModelDetailRoute({required this.model, super.key});

  final PricedModel model;

  @override
  Widget build(BuildContext context) {
    final bool wide =
        MediaQuery.sizeOf(context).width >= AppTheme.wideBreakpoint;
    if (wide) {
      return Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, maxHeight: 720),
          child: _ModelDetail(model: model, showClose: true),
        ),
      );
    }

    final ThemeData theme = Theme.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color:
            theme.bottomSheetTheme.modalBackgroundColor ??
            theme.colorScheme.surface,
        shape:
            theme.bottomSheetTheme.shape ??
            RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
        clipBehavior: Clip.antiAlias,
        child: _ModelDetailBottomSheet(model: model),
      ),
    );
  }
}

class _ModelDetailBottomSheet extends StatefulWidget {
  const _ModelDetailBottomSheet({required this.model});

  final PricedModel model;

  @override
  State<_ModelDetailBottomSheet> createState() =>
      _ModelDetailBottomSheetState();
}

class _ModelDetailBottomSheetState extends State<_ModelDetailBottomSheet> {
  static const double _openExtent = 0.88;
  static const double _dismissExtent = 0.665;
  static const double _dismissVelocity = 900;

  final DraggableScrollableController _controller =
      DraggableScrollableController();
  VelocityTracker? _velocityTracker;
  int _settleGeneration = 0;
  double _currentExtent = _openExtent;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _settleGeneration++;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _velocityTracker?.addPosition(event.timeStamp, event.position);
  }

  void _handlePointerUp(PointerUpEvent event) {
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    _settle(cancelled: false);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _settle(cancelled: true);
  }

  void _settle({required bool cancelled}) {
    if (!_controller.isAttached) return;
    final double extent = _currentExtent;
    if ((_openExtent - extent).abs() < 0.001) return;
    final double velocity = cancelled
        ? 0
        : (_velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0);
    _velocityTracker = null;
    final bool dismiss =
        !cancelled &&
        (extent <= _dismissExtent || velocity >= _dismissVelocity);
    final int generation = ++_settleGeneration;
    scheduleMicrotask(() {
      if (!mounted || generation != _settleGeneration) return;
      _controller
          .animateTo(
            dismiss ? 0.001 : _openExtent,
            duration: Duration(milliseconds: dismiss ? 240 : 190),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (!mounted || generation != _settleGeneration) return;
            if (dismiss) Navigator.of(context).pop();
          });
    });
  }

  bool _handleExtent(DraggableScrollableNotification notification) {
    _currentExtent = notification.extent;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<DraggableScrollableNotification>(
      onNotification: _handleExtent,
      child: Listener(
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: DraggableScrollableSheet(
          controller: _controller,
          expand: false,
          initialChildSize: _openExtent,
          minChildSize: 0.001,
          maxChildSize: _openExtent,
          shouldCloseOnMinExtent: false,
          builder: (BuildContext context, ScrollController controller) =>
              _ModelDetail(
                model: widget.model,
                scrollController: controller,
                showDragHandle: true,
              ),
        ),
      ),
    );
  }
}

class _ModelDetail extends StatelessWidget {
  const _ModelDetail({
    required this.model,
    this.showClose = false,
    this.showDragHandle = false,
    this.scrollController,
  });

  final PricedModel model;
  final bool showClose;
  final bool showDragHandle;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final ScrollController? externalController = scrollController;
    return SafeArea(
      top: false,
      child: externalController == null
          ? AppScrollView(
              builder: (BuildContext context, AppScrollController controller) =>
                  _buildScrollable(context, controller),
            )
          : _buildScrollable(context, externalController),
    );
  }

  Widget _buildScrollable(BuildContext context, ScrollController controller) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<_ModelCapability> capabilities = _enabledCapabilities(model);
    return SingleChildScrollView(
      controller: controller,
      padding: EdgeInsets.only(bottom: 22),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 150,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (Rect bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Colors.white, Colors.white, Colors.transparent],
                stops: <double>[0, 0.72, 1],
              ).createShader(bounds),
              child: CardVisual(
                spec: context.cardVisuals.modelDetail,
                active: true,
                entranceExtent: 0.16,
                entranceDuration: Duration(milliseconds: 1800),
                accentColors: capabilities
                    .map(
                      (_ModelCapability capability) =>
                          capability.accent(colors),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _IdentityHeader(
                model: model,
                showClose: showClose,
                showDragHandle: showDragHandle,
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
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
            ],
          ),
          if (showDragHandle)
            Positioned(
              top: 9,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
            ),
        ],
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
  const _IdentityHeader({
    required this.model,
    required this.showClose,
    required this.showDragHandle,
  });

  final PricedModel model;
  final bool showClose;
  final bool showDragHandle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: showDragHandle ? 136 : 128),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          showDragHandle ? 30 : 22,
          showClose ? 8 : 18,
          22,
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(20),
              ),
              alignment: Alignment.center,
              child: Icon(
                model.reasoning
                    ? Icons.psychology_rounded
                    : Icons.auto_awesome_rounded,
                size: 29,
                color: colors.onPrimary,
              ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    model.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                      height: 1.12,
                    ),
                  ),
                ],
              ),
            ),
            if (showClose) ...<Widget>[
              SizedBox(width: 4),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded),
                color: colors.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Pricing extends StatelessWidget {
  const _Pricing({required this.model});

  final PricedModel model;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
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
        SizedBox(height: 12),
        if (!hasPrice)
          _QuietMessage(
            icon: Icons.money_off_csred_outlined,
            text: 'No published pricing',
          )
        else ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: _MetricCard(
                  label: 'Input',
                  value: formatPricePerMillion(cost?.input),
                  color: Color.alphaBlend(
                    colors.primary.withValues(alpha: 0.15),
                    colors.surfaceContainerLow,
                  ),
                  foreground: colors.onSurface,
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: _MetricCard(
                  label: 'Output',
                  value: formatPricePerMillion(cost?.output),
                  color: Color.alphaBlend(
                    colors.tertiary.withValues(alpha: 0.15),
                    colors.surfaceContainerLow,
                  ),
                  foreground: colors.onSurface,
                ),
              ),
            ],
          ),
          if (cost?.reasoning != null ||
              cost?.cacheRead != null ||
              cost?.cacheWrite != null) ...<Widget>[
            SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (cost?.reasoning != null)
                  _SupportingMetric(
                    label: 'Reasoning',
                    value: formatPricePerMillion(cost?.reasoning),
                  ),
                if (cost?.cacheRead != null)
                  _SupportingMetric(
                    label: 'Cache read',
                    value: formatPricePerMillion(cost?.cacheRead),
                  ),
                if (cost?.cacheWrite != null)
                  _SupportingMetric(
                    label: 'Cache write',
                    value: formatPricePerMillion(cost?.cacheWrite),
                  ),
              ],
            ),
          ],
          SizedBox(height: 8),
          Text(
            'USD per 1M tokens',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
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
            size: 15,
            color: colors.onSurfaceVariant,
          ),
          SizedBox(width: 5),
          Flexible(
            child: Text(
              provider,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
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
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(icon: Icons.data_object_rounded, title: 'Limits'),
        SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: _MetricCard(
                label: 'Context',
                value: formatTokens(model.contextLimit),
                suffix: 'tokens',
                color: colors.surfaceContainerHigh,
                foreground: colors.onSurface,
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: _MetricCard(
                label: 'Max output',
                value: formatTokens(model.outputLimit),
                suffix: 'tokens',
                color: colors.surfaceContainerHigh,
                foreground: colors.onSurface,
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
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<_ModelCapability> capabilities = _enabledCapabilities(model);
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
            for (final _ModelCapability capability in capabilities)
              _Capability(
                icon: capability.icon,
                label: capability.label,
                accent: capability.accent(colors),
              ),
          ],
        ),
        if (model.inputModalities.isNotEmpty ||
            model.outputModalities.isNotEmpty) ...<Widget>[
          SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (model.inputModalities.isNotEmpty)
                _Modality(
                  icon: Icons.login_rounded,
                  label: 'In',
                  values: model.inputModalities,
                ),
              if (model.outputModalities.isNotEmpty)
                _Modality(
                  icon: Icons.logout_rounded,
                  label: 'Out',
                  values: model.outputModalities,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

enum _ModelCapability { reasoning, tools, vision, files, openWeights }

extension on _ModelCapability {
  bool enabledFor(PricedModel model) => switch (this) {
    _ModelCapability.reasoning => model.reasoning,
    _ModelCapability.tools => model.toolCall,
    _ModelCapability.vision => model.supportsVision,
    _ModelCapability.files => model.attachment,
    _ModelCapability.openWeights => model.openWeights,
  };

  String get label => switch (this) {
    _ModelCapability.reasoning => 'Reasoning',
    _ModelCapability.tools => 'Tools',
    _ModelCapability.vision => 'Vision',
    _ModelCapability.files => 'Files',
    _ModelCapability.openWeights => 'Open weights',
  };

  IconData get icon => switch (this) {
    _ModelCapability.reasoning => Icons.psychology_outlined,
    _ModelCapability.tools => Icons.build_outlined,
    _ModelCapability.vision => Icons.image_outlined,
    _ModelCapability.files => Icons.attach_file_rounded,
    _ModelCapability.openWeights => Icons.lock_open_outlined,
  };

  Color accent(ColorScheme colors) => switch (this) {
    _ModelCapability.reasoning => colors.primary,
    _ModelCapability.tools => colors.secondary,
    _ModelCapability.vision => colors.tertiary,
    _ModelCapability.files => Color.lerp(colors.primary, colors.tertiary, 0.5)!,
    _ModelCapability.openWeights => Color.lerp(
      colors.secondary,
      colors.tertiary,
      0.5,
    )!,
  };
}

List<_ModelCapability> _enabledCapabilities(PricedModel model) =>
    _ModelCapability.values
        .where((_ModelCapability capability) => capability.enabledFor(model))
        .toList(growable: false);

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
          SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: <Widget>[
              if (model.releaseDate != null)
                _MetadataDate(
                  label: 'Released',
                  value: _date(model.releaseDate!),
                ),
              if (model.lastUpdated != null)
                _MetadataDate(
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: colors.primary),
        SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: colors.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (trailing != null) ...<Widget>[Spacer(), Flexible(child: trailing!)],
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.color,
    required this.foreground,
    this.suffix,
  });

  final String label;
  final String value;
  final String? suffix;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelMedium?.copyWith(
              color: foreground.withValues(alpha: 0.72),
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.headlineSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
          if (suffix != null) ...<Widget>[
            SizedBox(height: 4),
            Text(
              suffix!,
              style: textTheme.labelSmall?.copyWith(
                color: foreground.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SupportingMetric extends StatelessWidget {
  const _SupportingMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: '$label  ',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            TextSpan(
              text: value,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Capability extends StatelessWidget {
  const _Capability({
    required this.icon,
    required this.label,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.12),
          colors.surfaceContainerLow,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: accent),
          SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Modality extends StatelessWidget {
  const _Modality({
    required this.icon,
    required this.label,
    required this.values,
  });

  final IconData icon;
  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 320),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 15, color: colors.onSurfaceVariant),
            SizedBox(width: 6),
            Flexible(
              child: Text(
                '$label · ${values.map(_titleCase).join(' · ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _titleCase(String value) => value.isEmpty
      ? value
      : '${value[0].toUpperCase()}${value.substring(1).toLowerCase()}';
}

class _MetadataDate extends StatelessWidget {
  const _MetadataDate({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: '$label  ',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: value,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyId extends StatelessWidget {
  const _CopyId({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _copy(context),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: 48),
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 9, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurface,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Icon(
                  Icons.copy_outlined,
                  size: 17,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 17, color: colors.onSurfaceVariant),
          SizedBox(width: 8),
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
