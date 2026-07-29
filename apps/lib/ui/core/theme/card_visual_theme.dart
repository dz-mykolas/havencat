import 'package:flutter/material.dart';

import '../../../domain/models/app_theme_preferences.dart';

enum CardFlowShape { ribbon, tide, bloom }

@immutable
class CardVisualSpec {
  const CardVisualSpec({
    required this.shape,
    required this.colors,
    required this.duration,
    required this.opacity,
    required this.amplitude,
    required this.phase,
    required this.focus,
    this.showFlow = true,
    this.reverse = false,
    this.assetName,
    this.assetAnimated = false,
    this.reducedMotionAssetName,
    this.assetOpacity = 0.22,
    this.assetFit = BoxFit.cover,
    this.assetAlignment = Alignment.center,
    this.cornerIcon,
    this.cornerIconAlignment = Alignment.topRight,
    this.cornerIconOpacity = 0.08,
  });

  final CardFlowShape shape;
  final List<Color> colors;
  final Duration duration;
  final double opacity;
  final double amplitude;
  final double phase;
  final Alignment focus;
  final bool showFlow;
  final bool reverse;
  final String? assetName;
  final bool assetAnimated;
  final String? reducedMotionAssetName;
  final double assetOpacity;
  final BoxFit assetFit;
  final Alignment assetAlignment;
  final IconData? cornerIcon;
  final Alignment cornerIconAlignment;
  final double cornerIconOpacity;

  CardVisualSpec copyWith({
    CardFlowShape? shape,
    List<Color>? colors,
    Duration? duration,
    double? opacity,
    double? amplitude,
    double? phase,
    Alignment? focus,
    bool? showFlow,
    bool? reverse,
    String? assetName,
    bool? assetAnimated,
    String? reducedMotionAssetName,
    double? assetOpacity,
    BoxFit? assetFit,
    Alignment? assetAlignment,
    IconData? cornerIcon,
    Alignment? cornerIconAlignment,
    double? cornerIconOpacity,
  }) {
    return CardVisualSpec(
      shape: shape ?? this.shape,
      colors: colors ?? this.colors,
      duration: duration ?? this.duration,
      opacity: opacity ?? this.opacity,
      amplitude: amplitude ?? this.amplitude,
      phase: phase ?? this.phase,
      focus: focus ?? this.focus,
      showFlow: showFlow ?? this.showFlow,
      reverse: reverse ?? this.reverse,
      assetName: assetName ?? this.assetName,
      assetAnimated: assetAnimated ?? this.assetAnimated,
      reducedMotionAssetName:
          reducedMotionAssetName ?? this.reducedMotionAssetName,
      assetOpacity: assetOpacity ?? this.assetOpacity,
      assetFit: assetFit ?? this.assetFit,
      assetAlignment: assetAlignment ?? this.assetAlignment,
      cornerIcon: cornerIcon ?? this.cornerIcon,
      cornerIconAlignment: cornerIconAlignment ?? this.cornerIconAlignment,
      cornerIconOpacity: cornerIconOpacity ?? this.cornerIconOpacity,
    );
  }

  CardVisualSpec lerp(CardVisualSpec other, double t) {
    return CardVisualSpec(
      shape: t < 0.5 ? shape : other.shape,
      colors: _lerpColors(colors, other.colors, t),
      duration: Duration(
        microseconds: lerpDouble(
          duration.inMicroseconds.toDouble(),
          other.duration.inMicroseconds.toDouble(),
          t,
        ).round(),
      ),
      opacity: lerpDouble(opacity, other.opacity, t),
      amplitude: lerpDouble(amplitude, other.amplitude, t),
      phase: lerpDouble(phase, other.phase, t),
      focus: Alignment.lerp(focus, other.focus, t)!,
      showFlow: t < 0.5 ? showFlow : other.showFlow,
      reverse: t < 0.5 ? reverse : other.reverse,
      assetName: t < 0.5 ? assetName : other.assetName,
      assetAnimated: t < 0.5 ? assetAnimated : other.assetAnimated,
      reducedMotionAssetName: t < 0.5
          ? reducedMotionAssetName
          : other.reducedMotionAssetName,
      assetOpacity: lerpDouble(assetOpacity, other.assetOpacity, t),
      assetFit: t < 0.5 ? assetFit : other.assetFit,
      assetAlignment: Alignment.lerp(assetAlignment, other.assetAlignment, t)!,
      cornerIcon: t < 0.5 ? cornerIcon : other.cornerIcon,
      cornerIconAlignment: Alignment.lerp(
        cornerIconAlignment,
        other.cornerIconAlignment,
        t,
      )!,
      cornerIconOpacity: lerpDouble(
        cornerIconOpacity,
        other.cornerIconOpacity,
        t,
      ),
    );
  }

  static List<Color> _lerpColors(List<Color> from, List<Color> to, double t) {
    final int length = from.length > to.length ? from.length : to.length;
    return List<Color>.generate(length, (int index) {
      final Color a = from[index.clamp(0, from.length - 1)];
      final Color b = to[index.clamp(0, to.length - 1)];
      return Color.lerp(a, b, t)!;
    }, growable: false);
  }

  static double lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

@immutable
class AppCardVisualTheme extends ThemeExtension<AppCardVisualTheme> {
  const AppCardVisualTheme({required this.modelDetail});

  factory AppCardVisualTheme.fromPreset(
    AppThemePreset preset,
    ColorScheme colors,
  ) {
    final CardVisualSpec base = switch (preset) {
      AppThemePreset.gradientLight => CardVisualSpec(
        shape: CardFlowShape.tide,
        colors: <Color>[colors.secondary, colors.primary, colors.tertiary],
        duration: Duration(seconds: 28),
        opacity: 0.2,
        amplitude: 1,
        phase: 0.18,
        focus: Alignment.centerLeft,
      ),
      AppThemePreset.gradientDark => CardVisualSpec(
        shape: CardFlowShape.tide,
        colors: <Color>[colors.primary, colors.tertiary, colors.secondary],
        duration: Duration(seconds: 28),
        opacity: 0.26,
        amplitude: 1,
        phase: 0.62,
        focus: Alignment.centerRight,
        reverse: true,
      ),
      _ => CardVisualSpec(
        shape: CardFlowShape.tide,
        colors: <Color>[colors.primary, colors.secondary, colors.tertiary],
        duration: Duration(seconds: 28),
        opacity: 0,
        amplitude: 1,
        phase: 0,
        focus: Alignment.center,
        showFlow: false,
      ),
    };
    final CardVisualSpec modelDetail = preset.isGradient
        ? base.copyWith(
            colors: base.colors.map(_vividColor).toList(growable: false),
          )
        : base;
    return AppCardVisualTheme(modelDetail: modelDetail);
  }

  static Color _vividColor(Color color) {
    final HSLColor hsl = HSLColor.fromColor(color);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.72, 0.92))
        .withLightness(hsl.lightness.clamp(0.48, 0.62))
        .toColor();
  }

  final CardVisualSpec modelDetail;

  @override
  AppCardVisualTheme copyWith({CardVisualSpec? modelDetail}) {
    return AppCardVisualTheme(modelDetail: modelDetail ?? this.modelDetail);
  }

  @override
  AppCardVisualTheme lerp(covariant AppCardVisualTheme? other, double t) {
    if (other == null) return this;
    return AppCardVisualTheme(
      modelDetail: modelDetail.lerp(other.modelDetail, t),
    );
  }
}

extension AppCardVisualContext on BuildContext {
  AppCardVisualTheme get cardVisuals {
    final ThemeData theme = Theme.of(this);
    return theme.extension<AppCardVisualTheme>() ??
        AppCardVisualTheme.fromPreset(
          theme.brightness == Brightness.dark
              ? AppThemePreset.haven
              : AppThemePreset.parchment,
          theme.colorScheme,
        );
  }
}
