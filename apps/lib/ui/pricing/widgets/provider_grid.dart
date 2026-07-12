import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_svg/flutter_svg.dart';

import '../../../domain/models/model_pricing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';

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
  final bool showCustomCard;
  final VoidCallback? onAddCustom;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 640
            ? 3
            : (constraints.maxWidth >= 400 ? 2 : 1);
        final int total = providers.length + (showCustomCard ? 1 : 0);
        return AppScrollView(
          builder: (BuildContext context, AppScrollController controller) =>
              GridView.builder(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, 2, 12, 16),
                scrollCacheExtent: ScrollCacheExtent.pixels(200),
                addAutomaticKeepAlives: false,
                itemCount: total,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  mainAxisExtent: 56,
                ),
                itemBuilder: (BuildContext context, int index) {
                  if (showCustomCard && index == 0) {
                    return _CustomCard(onTap: onAddCustom!);
                  }
                  final int providerIndex = showCustomCard ? index - 1 : index;
                  final ProviderModels provider = providers[providerIndex];
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

class _CustomCard extends StatelessWidget {
  const _CustomCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.appColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: <Widget>[
              _CustomMark(),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Custom endpoint',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.appColors.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                size: 17,
                color: context.appColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomMark extends StatelessWidget {
  const _CustomMark();

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
        Icons.add_rounded,
        size: 18,
        color: context.appColors.brandViolet,
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
      color: context.appColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: <Widget>[
              _ProviderMark(logoUrl: provider.logoUrl),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  provider.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.appColors.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Tooltip(
                message: '${provider.models.length} models',
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: context.appColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    '${provider.models.length}',
                    style: TextStyle(
                      color: context.appColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              SizedBox(width: 5),
              Icon(
                Icons.chevron_right_rounded,
                color: context.appColors.textSecondary,
                size: 17,
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
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: context.appColors.surfaceHigh,
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: SvgPicture.network(
        logoUrl,
        width: 20,
        height: 20,
        colorFilter: ColorFilter.mode(
          context.appColors.brandViolet,
          BlendMode.srcIn,
        ),
      ),
    );
  }
}
