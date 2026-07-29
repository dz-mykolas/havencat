import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_svg/flutter_svg.dart';

import '../../../domain/models/model_pricing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';

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
        return AppScrollView(
          builder: (BuildContext context, AppScrollController controller) =>
              GridView.builder(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, 2, 12, 16),
                scrollCacheExtent: ScrollCacheExtent.pixels(200),
                addAutomaticKeepAlives: false,
                itemCount: providers.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  mainAxisExtent: 64,
                ),
                itemBuilder: (BuildContext context, int index) {
                  final ProviderModels provider = providers[index];
                  return _ProviderCard(
                    provider: provider,
                    onTap: () => onTap(provider.id),
                  );
                },
              ),
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
    final BorderRadius borderRadius = BorderRadius.circular(14);
    return Material(
      color: context.appColors.surface,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: <Widget>[
              _ProviderMark(logoUrl: provider.logoUrl),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  provider.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: context.appColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Tooltip(
                message: '${provider.models.length} models',
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  decoration: ShapeDecoration(
                    color: context.appColors.surfaceHigh.withValues(
                      alpha: 0.86,
                    ),
                    shape: StadiumBorder(),
                  ),
                  child: Text(
                    '${provider.models.length}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.appColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              SizedBox(width: 5),
              Icon(
                Icons.chevron_right_rounded,
                color: context.appColors.textSecondary,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderMark extends StatelessWidget {
  const _ProviderMark({required this.logoUrl});

  final String logoUrl;

  @override
  Widget build(BuildContext context) {
    final Widget fallback = Icon(
      Icons.hub_outlined,
      size: 20,
      color: context.appColors.brandViolet,
    );
    return SizedBox(
      width: 30,
      height: 34,
      child: Center(
        child: logoUrl.trim().isEmpty
            ? fallback
            : SvgPicture.network(
                logoUrl,
                width: 22,
                height: 22,
                colorFilter: ColorFilter.mode(
                  context.appColors.brandViolet,
                  BlendMode.srcIn,
                ),
                placeholderBuilder: (_) => fallback,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
