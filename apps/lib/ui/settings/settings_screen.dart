import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/storage/app_settings.dart';
import '../../domain/models/app_theme_preferences.dart';
import '../../domain/models/code_theme_preferences.dart';
import '../../providers.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/code_highlight_theme.dart';
import '../core/widgets/app_scroll_view.dart';
import '../core/widgets/fade_slide_in.dart';
import '../pricing/discover_panel.dart';
import 'widgets/web_search_settings_panel.dart';

enum SettingsSection { models, webSearch, appearance, general, context }

extension SettingsSectionPresentation on SettingsSection {
  String get routeSegment => switch (this) {
    SettingsSection.models => 'models',
    SettingsSection.webSearch => 'web-search',
    SettingsSection.appearance => 'appearance',
    SettingsSection.general => 'general',
    SettingsSection.context => 'context',
  };

  String get label => switch (this) {
    SettingsSection.models => 'Models & providers',
    SettingsSection.webSearch => 'Web search',
    SettingsSection.appearance => 'Appearance',
    SettingsSection.general => 'General',
    SettingsSection.context => 'Context',
  };

  IconData get icon => switch (this) {
    SettingsSection.models => Icons.hub_outlined,
    SettingsSection.webSearch => Icons.travel_explore_rounded,
    SettingsSection.appearance => Icons.palette_outlined,
    SettingsSection.general => Icons.tune_rounded,
    SettingsSection.context => Icons.compress_rounded,
  };
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({
    this.initialSection,
    this.onSectionChanged,
    this.onConfigureWebSearchProvider,
    this.discoverRouting,
    super.key,
  });

  final SettingsSection? initialSection;
  final ValueChanged<SettingsSection?>? onSectionChanged;
  final WebSearchProviderRouteCallback? onConfigureWebSearchProvider;
  final DiscoverRouting? discoverRouting;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late SettingsSection _category;
  SettingsSection? _mobileCategory;

  @override
  void initState() {
    super.initState();
    _category = widget.initialSection ?? SettingsSection.models;
    _mobileCategory = widget.initialSection;
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection == widget.initialSection) return;
    _category = widget.initialSection ?? SettingsSection.models;
    _mobileCategory = widget.initialSection;
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = ref.watch(appSettingsProvider);
    final bool wide =
        MediaQuery.sizeOf(context).width >= AppTheme.wideBreakpoint;
    final bool showingMobileDetail = !wide && _mobileCategory != null;
    final bool showingRoutedSection =
        widget.onSectionChanged != null && widget.initialSection != null;

    return PopScope(
      canPop: !showingMobileDetail,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && showingMobileDetail) _closeMobileCategory();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: showingMobileDetail || showingRoutedSection
              ? BackButton(onPressed: _closeMobileCategory)
              : null,
          title: Text(
            showingMobileDetail ? _mobileCategory!.label : 'Settings',
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 1120),
              child: wide
                  ? Padding(
                      padding: EdgeInsets.fromLTRB(24, 16, 24, 28),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          SizedBox(
                            width: 220,
                            child: _CategoryNavigation(
                              selected: _category,
                              onSelected: _selectCategory,
                            ),
                          ),
                          SizedBox(width: 24),
                          Expanded(
                            child: _CategoryContent(
                              category: _category,
                              settings: settings,
                              discoverRouting: widget.discoverRouting,
                              onConfigureWebSearchProvider:
                                  widget.onConfigureWebSearchProvider,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _mobileCategory == null
                  ? _MobileCategoryList(onSelected: _openMobileCategory)
                  : Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                      child: _CategoryContent(
                        category: _mobileCategory!,
                        settings: settings,
                        discoverRouting: widget.discoverRouting,
                        onConfigureWebSearchProvider:
                            widget.onConfigureWebSearchProvider,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  void _openMobileCategory(SettingsSection category) {
    if (widget.onSectionChanged case final onSectionChanged?) {
      onSectionChanged(category);
      return;
    }
    setState(() {
      _category = category;
      _mobileCategory = category;
    });
  }

  void _closeMobileCategory() {
    if (widget.onSectionChanged case final onSectionChanged?) {
      onSectionChanged(null);
      return;
    }
    setState(() => _mobileCategory = null);
  }

  void _selectCategory(SettingsSection category) {
    if (widget.onSectionChanged case final onSectionChanged?) {
      onSectionChanged(category);
      return;
    }
    setState(() => _category = category);
  }
}

class _MobileCategoryList extends StatelessWidget {
  const _MobileCategoryList({required this.onSelected});

  final ValueChanged<SettingsSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return AppScrollView(
      builder: (BuildContext context, AppScrollController controller) =>
          ListView(
            controller: controller,
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: <Widget>[
              for (
                int index = 0;
                index < SettingsSection.values.length;
                index++
              )
                Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: FadeSlideIn(
                    delay: Duration(milliseconds: 35 * index),
                    child: _MobileCategoryButton(
                      category: SettingsSection.values[index],
                      onTap: () => onSelected(SettingsSection.values[index]),
                    ),
                  ),
                ),
            ],
          ),
    );
  }
}

class _MobileCategoryButton extends StatelessWidget {
  const _MobileCategoryButton({required this.category, required this.onTap});

  final SettingsSection category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.appColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: context.appColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Icon(
                  category.icon,
                  size: 18,
                  color: context.appColors.brandViolet,
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  category.label,
                  style: TextStyle(
                    color: context.appColors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                color: context.appColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryNavigation extends StatelessWidget {
  const _CategoryNavigation({required this.selected, required this.onSelected});

  final SettingsSection selected;
  final ValueChanged<SettingsSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Text(
            'CATEGORIES',
            style: TextStyle(
              color: context.appColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
        ),
        for (final SettingsSection category in SettingsSection.values) ...[
          _CategoryButton(
            category: category,
            selected: category == selected,
            onTap: () => onSelected(category),
          ),
          SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _CategoryButton extends StatelessWidget {
  const _CategoryButton({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final SettingsSection category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? context.appColors.surface : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: <Widget>[
              Icon(
                category.icon,
                size: 18,
                color: selected
                    ? context.appColors.brandViolet
                    : context.appColors.textSecondary,
              ),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  category.label,
                  style: TextStyle(
                    color: selected
                        ? context.appColors.textPrimary
                        : context.appColors.textSecondary,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (selected)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: context.appColors.textSecondary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryContent extends StatelessWidget {
  const _CategoryContent({
    required this.category,
    required this.settings,
    required this.discoverRouting,
    required this.onConfigureWebSearchProvider,
  });

  final SettingsSection category;
  final AppSettings settings;
  final DiscoverRouting? discoverRouting;
  final WebSearchProviderRouteCallback? onConfigureWebSearchProvider;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0.025, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: switch (category) {
        SettingsSection.models => _ModelsCategory(
          key: ValueKey<SettingsSection>(SettingsSection.models),
          routing: discoverRouting,
        ),
        SettingsSection.webSearch => WebSearchSettingsPanel(
          key: ValueKey<SettingsSection>(SettingsSection.webSearch),
          onConfigureProvider: onConfigureWebSearchProvider,
        ),
        SettingsSection.appearance => _ScrollableCategory(
          key: ValueKey<SettingsSection>(SettingsSection.appearance),
          children: <Widget>[
            _AppearanceGroupLabel(label: 'APP THEME'),
            _AppearanceCard(settings: settings),
            SizedBox(height: 18),
            _AppearanceGroupLabel(label: 'CODE THEME'),
            _CodeThemeCard(settings: settings),
          ],
        ),
        SettingsSection.general => _ScrollableCategory(
          key: ValueKey<SettingsSection>(SettingsSection.general),
          children: <Widget>[_PreferencesCard(settings: settings)],
        ),
        SettingsSection.context => _ScrollableCategory(
          key: ValueKey<SettingsSection>(SettingsSection.context),
          children: <Widget>[_CompactionCard(settings: settings)],
        ),
      },
    );
  }
}

class _ScrollableCategory extends StatelessWidget {
  const _ScrollableCategory({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppScrollView(
      builder: (BuildContext context, AppScrollController controller) =>
          ListView(
            controller: controller,
            padding: EdgeInsets.only(bottom: 24),
            children: children,
          ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.appColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding ?? EdgeInsets.all(6), child: child),
    );
  }
}

class _ModelsCategory extends StatelessWidget {
  const _ModelsCategory({this.routing, super.key});

  final DiscoverRouting? routing;

  @override
  Widget build(BuildContext context) {
    return DiscoverPanel(routing: routing);
  }
}

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: <Widget>[
          SwitchListTile(
            key: const ValueKey<String>('use-device-theme'),
            dense: true,
            visualDensity: VisualDensity(vertical: -2),
            value: settings.useDeviceTheme,
            onChanged: settings.setUseDeviceTheme,
            secondary: Icon(
              Icons.brightness_auto_rounded,
              size: 19,
              color: context.appColors.brandViolet,
            ),
            title: Text(
              'Use device theme',
              style: TextStyle(
                color: context.appColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              'Switch automatically with your device appearance.',
              style: TextStyle(
                color: context.appColors.textSecondary,
                fontSize: 11,
              ),
            ),
            contentPadding: EdgeInsets.symmetric(horizontal: 12),
          ),
          _SettingsDivider(),
          if (settings.useDeviceTheme) ...<Widget>[
            _ThemePreferenceGroup(
              settings: settings,
              icon: Icons.light_mode_rounded,
              label: 'Light theme',
              preset: settings.lightTheme,
              onTap: () => _showThemePicker(
                context,
                title: 'Light theme',
                presets: AppThemePreset.values
                    .where((AppThemePreset value) => !value.isDark)
                    .toList(growable: false),
                selected: settings.lightTheme,
                onSelected: settings.setLightTheme,
              ),
            ),
            _SettingsDivider(),
            _ThemePreferenceGroup(
              settings: settings,
              icon: Icons.dark_mode_rounded,
              label: 'Dark theme',
              preset: settings.darkTheme,
              onTap: () => _showThemePicker(
                context,
                title: 'Dark theme',
                presets: AppThemePreset.values
                    .where((AppThemePreset value) => value.isDark)
                    .toList(growable: false),
                selected: settings.darkTheme,
                onSelected: settings.setDarkTheme,
              ),
            ),
          ] else
            _ThemePreferenceGroup(
              settings: settings,
              icon: Icons.palette_outlined,
              label: 'Theme',
              preset: settings.theme,
              onTap: () => _showThemePicker(
                context,
                title: 'Theme',
                presets: AppThemePreset.values,
                selected: settings.theme,
                onSelected: settings.setTheme,
              ),
            ),
        ],
      ),
    );
  }
}

class _AppearanceGroupLabel extends StatelessWidget {
  const _AppearanceGroupLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 4, 12, 9),
      child: Text(
        label,
        style: TextStyle(
          color: context.appColors.textSecondary,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.05,
        ),
      ),
    );
  }
}

class _CodeThemeCard extends StatelessWidget {
  const _CodeThemeCard({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final CodeThemeDefinition definition = CodeThemeCatalog.resolve(
      settings.codeTheme,
      Theme.of(context).brightness,
    );
    final String subtitle = settings.codeTheme == CodeThemeOption.adaptive
        ? 'Match app · ${definition.label}'
        : definition.label;
    return _Card(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ListTile(
            key: const ValueKey<String>('code-theme'),
            dense: true,
            leading: Icon(
              Icons.code_rounded,
              size: 19,
              color: context.appColors.brandViolet,
            ),
            title: Text(
              'Code theme',
              style: TextStyle(
                color: context.appColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                color: context.appColors.textSecondary,
                fontSize: 11,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _CodeThemeSwatches(definition: definition),
                SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: context.appColors.textSecondary,
                ),
              ],
            ),
            onTap: () => _showCodeThemePicker(context, settings),
          ),
          _CodeThemePreview(definition: definition),
        ],
      ),
    );
  }
}

class _CodeThemePreview extends StatelessWidget {
  const _CodeThemePreview({required this.definition});

  final CodeThemeDefinition definition;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      child: HighlightView(
        "final greeting = 'Hello';\nprint(greeting);",
        language: 'dart',
        theme: definition.styles,
        padding: EdgeInsets.fromLTRB(14, 10, 14, 12),
        textStyle: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.45,
        ),
      ),
    );
  }
}

class _CodeThemeThumbnail extends StatelessWidget {
  const _CodeThemeThumbnail({required this.definition});

  final CodeThemeDefinition definition;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 38,
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: definition.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: context.appColors.divider.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _CodeColorStroke(
                color: definition.colorFor('keyword'),
                width: 12,
              ),
              SizedBox(width: 3),
              _CodeColorStroke(color: definition.foreground, width: 9),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: 5),
            child: _CodeColorStroke(
              color: definition.colorFor('string'),
              width: 22,
            ),
          ),
          Row(
            children: <Widget>[
              _CodeColorStroke(color: definition.colorFor('number'), width: 9),
              SizedBox(width: 3),
              _CodeColorStroke(
                color: definition.colorFor('comment'),
                width: 14,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CodeColorStroke extends StatelessWidget {
  const _CodeColorStroke({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 3,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _CodeThemeSwatches extends StatelessWidget {
  const _CodeThemeSwatches({required this.definition});

  final CodeThemeDefinition definition;

  @override
  Widget build(BuildContext context) {
    final List<Color> colors = <Color>[
      definition.colorFor('keyword'),
      definition.colorFor('string'),
      definition.colorFor('number'),
    ];
    return Container(
      width: 50,
      height: 24,
      padding: EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: definition.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: context.appColors.divider.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          for (final Color color in colors)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }
}

Future<void> _showCodeThemePicker(BuildContext context, AppSettings settings) {
  final Widget content = _CodeThemePicker(settings: settings);
  if (MediaQuery.sizeOf(context).width >= AppTheme.wideBreakpoint) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 440, maxHeight: 640),
          child: content,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext context) => SafeArea(top: false, child: content),
  );
}

class _CodeThemePicker extends StatelessWidget {
  const _CodeThemePicker({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Code theme',
                  style: TextStyle(
                    color: context.appColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Flexible(
          child: AppScrollView(
            builder: (BuildContext context, AppScrollController controller) =>
                ListView(
                  controller: controller,
                  shrinkWrap: true,
                  padding: EdgeInsets.fromLTRB(8, 0, 8, 12),
                  children: <Widget>[
                    _CodeThemeOptionTile(
                      option: CodeThemeOption.adaptive,
                      definition: CodeThemeCatalog.resolve(
                        CodeThemeOption.adaptive,
                        brightness,
                      ),
                      selected: settings.codeTheme == CodeThemeOption.adaptive,
                      subtitle: 'Follows the app theme',
                      onTap: () => _selectCodeTheme(
                        context,
                        settings,
                        CodeThemeOption.adaptive,
                      ),
                    ),
                    _CodeThemePickerLabel(label: 'DARK'),
                    for (final CodeThemeOption option in CodeThemeCatalog.dark)
                      _CodeThemeOptionTile(
                        option: option,
                        definition: CodeThemeCatalog.definition(option),
                        selected: settings.codeTheme == option,
                        onTap: () =>
                            _selectCodeTheme(context, settings, option),
                      ),
                    _CodeThemePickerLabel(label: 'LIGHT'),
                    for (final CodeThemeOption option in CodeThemeCatalog.light)
                      _CodeThemeOptionTile(
                        option: option,
                        definition: CodeThemeCatalog.definition(option),
                        selected: settings.codeTheme == option,
                        onTap: () =>
                            _selectCodeTheme(context, settings, option),
                      ),
                  ],
                ),
          ),
        ),
      ],
    );
  }

  void _selectCodeTheme(
    BuildContext context,
    AppSettings settings,
    CodeThemeOption option,
  ) {
    settings.setCodeTheme(option);
    Navigator.of(context).pop();
  }
}

class _CodeThemePickerLabel extends StatelessWidget {
  const _CodeThemePickerLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 14, 12, 5),
      child: Text(
        label,
        style: TextStyle(
          color: context.appColors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _CodeThemeOptionTile extends StatelessWidget {
  const _CodeThemeOptionTile({
    required this.option,
    required this.definition,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final CodeThemeOption option;
  final CodeThemeDefinition definition;
  final bool selected;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey<String>('code-theme-${option.name}'),
      leading: _CodeThemeThumbnail(definition: definition),
      title: Text(
        option == CodeThemeOption.adaptive ? 'Match app' : definition.label,
      ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: selected
          ? Icon(
              Icons.check_circle_rounded,
              color: context.appColors.brandViolet,
            )
          : null,
      selected: selected,
      selectedTileColor: context.appColors.brandViolet.withValues(alpha: 0.1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      onTap: onTap,
    );
  }
}

class _ThemePreferenceGroup extends StatelessWidget {
  const _ThemePreferenceGroup({
    required this.settings,
    required this.icon,
    required this.label,
    required this.preset,
    required this.onTap,
  });

  final AppSettings settings;
  final IconData icon;
  final String label;
  final AppThemePreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final int? gradientHue = preset.isGradient
        ? settings.gradientHueFor(preset)
        : null;
    return Column(
      children: <Widget>[
        _ThemePreferenceTile(
          icon: icon,
          label: label,
          preset: preset,
          gradientHue: gradientHue,
          onTap: onTap,
        ),
        if (gradientHue != null)
          _GradientHueSelector(
            preset: preset,
            hue: gradientHue,
            onChanged: (int hue) => settings.previewGradientHue(preset, hue),
            onChangeEnd: (int hue) => settings.setGradientHue(preset, hue),
          ),
      ],
    );
  }
}

class _ThemePreferenceTile extends StatelessWidget {
  const _ThemePreferenceTile({
    required this.icon,
    required this.label,
    required this.preset,
    required this.onTap,
    this.gradientHue,
  });

  final IconData icon;
  final String label;
  final AppThemePreset preset;
  final VoidCallback onTap;
  final int? gradientHue;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 19, color: context.appColors.brandViolet),
      title: Text(
        label,
        style: TextStyle(
          color: context.appColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        preset.label,
        style: TextStyle(color: context.appColors.textSecondary, fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _ThemeSwatches(preset: preset, gradientHue: gradientHue),
          SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: context.appColors.textSecondary,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _GradientHueSelector extends StatelessWidget {
  const _GradientHueSelector({
    required this.preset,
    required this.hue,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final AppThemePreset preset;
  final int hue;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey<String>('gradient-hue-selector-${preset.name}'),
      padding: const EdgeInsets.fromLTRB(52, 0, 12, 10),
      child: SizedBox(
        height: 38,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Positioned(
              left: 10,
              right: 10,
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  gradient: LinearGradient(
                    colors: <Color>[
                      for (int value = 0; value <= 360; value += 30)
                        HSVColor.fromAHSV(
                          1,
                          value == 360 ? 0 : value.toDouble(),
                          0.78,
                          0.95,
                        ).toColor(),
                    ],
                  ),
                ),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 12,
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                disabledActiveTrackColor: Colors.transparent,
                disabledInactiveTrackColor: Colors.transparent,
                thumbColor: GradientThemePalette.preview(hue),
                overlayColor: GradientThemePalette.preview(
                  hue,
                ).withValues(alpha: 0.16),
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 10,
                  elevation: 0,
                  pressedElevation: 0,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                valueIndicatorColor: context.appColors.surfaceHigh,
                valueIndicatorTextStyle: TextStyle(
                  color: context.appColors.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Slider(
                key: ValueKey<String>('gradient-hue-${preset.name}'),
                value: hue.toDouble(),
                min: 0,
                max: 359,
                divisions: 359,
                label: '$hue°',
                semanticFormatterCallback: (double value) =>
                    'Hue ${value.round()} degrees',
                onChanged: (double value) => onChanged(value.round()),
                onChangeEnd: (double value) => onChangeEnd(value.round()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeSwatches extends StatelessWidget {
  const _ThemeSwatches({required this.preset, this.gradientHue});

  final AppThemePreset preset;
  final int? gradientHue;

  @override
  Widget build(BuildContext context) {
    final List<Color> palette = preset.isGradient
        ? GradientThemePalette.colors(
            gradientHue ?? defaultGradientThemeHue,
            preset.brightness,
          )
        : <Color>[preset.primary, preset.secondary, preset.tertiary];
    return SizedBox(
      width: 42,
      height: 18,
      child: Stack(
        children: <Widget>[
          for (final (int index, Color color) in palette.indexed)
            Positioned(
              left: index * 12,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: context.appColors.surface,
                    width: 2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> _showThemePicker(
  BuildContext context, {
  required String title,
  required List<AppThemePreset> presets,
  required AppThemePreset selected,
  required ValueChanged<AppThemePreset> onSelected,
}) {
  final Widget content = _ThemePicker(
    title: title,
    presets: presets,
    selected: selected,
    onSelected: onSelected,
  );
  if (MediaQuery.sizeOf(context).width >= AppTheme.wideBreakpoint) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 420, maxHeight: 560),
          child: content,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext context) => SafeArea(top: false, child: content),
  );
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({
    required this.title,
    required this.presets,
    required this.selected,
    required this.onSelected,
  });

  final String title;
  final List<AppThemePreset> presets;
  final AppThemePreset selected;
  final ValueChanged<AppThemePreset> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: context.appColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Flexible(
          child: AppScrollView(
            builder: (BuildContext context, AppScrollController controller) =>
                ListView.builder(
                  controller: controller,
                  shrinkWrap: true,
                  padding: EdgeInsets.fromLTRB(8, 0, 8, 12),
                  itemCount: presets.length,
                  itemBuilder: (BuildContext context, int index) {
                    final AppThemePreset preset = presets[index];
                    final bool active = preset == selected;
                    return ListTile(
                      leading: _ThemePreview(preset: preset),
                      title: Text(preset.label),
                      subtitle: Text(preset.description),
                      trailing: active
                          ? Icon(
                              Icons.check_circle_rounded,
                              color: context.appColors.brandViolet,
                            )
                          : Icon(
                              preset.brightness == Brightness.dark
                                  ? Icons.dark_mode_outlined
                                  : Icons.light_mode_outlined,
                              size: 17,
                              color: context.appColors.textSecondary,
                            ),
                      selected: active,
                      selectedTileColor: context.appColors.brandViolet
                          .withValues(alpha: 0.1),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                      onTap: () {
                        onSelected(preset);
                        Navigator.of(context).pop();
                      },
                    );
                  },
                ),
          ),
        ),
      ],
    );
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.preset});

  final AppThemePreset preset;

  @override
  Widget build(BuildContext context) {
    final ThemeData preview = AppTheme.build(preset);
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: preview.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 17,
        height: 17,
        decoration: BoxDecoration(
          color: preview.colorScheme.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _PreferencesCard extends StatelessWidget {
  const _PreferencesCard({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: SwitchListTile(
        dense: true,
        visualDensity: VisualDensity(vertical: -2),
        value: settings.showHiddenModels,
        onChanged: settings.setShowHiddenModels,
        title: Text(
          'Show hidden models',
          style: TextStyle(color: context.appColors.textPrimary, fontSize: 14),
        ),
        subtitle: Text(
          'Include models that providers mark as internal. Hidden models are '
          'excluded by default.',
          style: TextStyle(
            color: context.appColors.textSecondary,
            fontSize: 11,
          ),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 12),
      ),
    );
  }
}

class _CompactionCard extends StatelessWidget {
  const _CompactionCard({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: <Widget>[
          _SettingsSwitch(
            value: settings.redactSecrets,
            onChanged: settings.setRedactSecrets,
            title: 'Redact secrets in summaries',
            subtitle:
                'Strip API keys, tokens, and passwords before the summarizer '
                'sees them. On by default.',
          ),
          _SettingsDivider(),
          _SettingsSwitch(
            value: settings.temporalAnchoring,
            onChanged: settings.setTemporalAnchoring,
            title: 'Temporal anchoring',
            subtitle:
                'Rewrite active tasks into dated past tense so resumed chats '
                'do not repeat completed actions.',
          ),
          _SettingsDivider(),
          _SettingsSwitch(
            value: settings.antiThrash,
            onChanged: settings.setAntiThrash,
            title: 'Anti-thrash guard',
            subtitle:
                'Back off when a compression pass produces no savings. On by '
                'default.',
          ),
          _SettingsDivider(),
          _SettingsSwitch(
            value: settings.staticFallback,
            onChanged: settings.setStaticFallback,
            title: 'Static fallback summary',
            subtitle:
                'Insert a deterministic summary when the LLM summary call '
                'fails. On by default.',
          ),
          _SettingsDivider(),
          _SettingsSwitch(
            value: settings.abortOnSummaryFailure,
            onChanged: settings.setAbortOnSummaryFailure,
            title: 'Abort on summary failure',
            subtitle:
                'Freeze the chat when summarization fails instead of using a '
                'fallback. Best for strict workflows.',
          ),
          _SettingsDivider(),
          _SettingsSwitch(
            value: settings.autoFocusTopic,
            onChanged: settings.setAutoFocusTopic,
            title: 'Auto focus topic',
            subtitle:
                'Infer a focus topic from recent turns and prioritize related '
                'information in the summary.',
          ),
        ],
      ),
    );
  }
}

class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      visualDensity: VisualDensity(vertical: -2),
      value: value,
      onChanged: onChanged,
      title: Text(
        title,
        style: TextStyle(color: context.appColors.textPrimary, fontSize: 14),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: context.appColors.textSecondary,
          fontSize: 11,
          height: 1.35,
        ),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 12),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(height: 1, indent: 12, endIndent: 12);
  }
}
