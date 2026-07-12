import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

@immutable
class AppWheelScrollConfig {
  const AppWheelScrollConfig({
    this.duration = const Duration(milliseconds: 180),
    this.curve = Curves.easeOutCubic,
    this.preciseDeltaThreshold = 40,
  });

  final Duration duration;
  final Curve curve;
  final double preciseDeltaThreshold;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppWheelScrollConfig &&
          duration == other.duration &&
          curve == other.curve &&
          preciseDeltaThreshold == other.preciseDeltaThreshold;

  @override
  int get hashCode => Object.hash(duration, curve, preciseDeltaThreshold);
}

class AppScrollController extends ScrollController {
  AppScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    this.wheelConfig = const AppWheelScrollConfig(),
    bool? smoothWheelScrolling,
  }) : smoothWheelScrolling = smoothWheelScrolling ?? kIsWeb;

  final AppWheelScrollConfig wheelConfig;
  final bool smoothWheelScrolling;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _AppScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      wheelConfig: wheelConfig,
      smoothWheelScrolling: smoothWheelScrolling,
    );
  }
}

class AppScrollView extends StatefulWidget {
  const AppScrollView({
    super.key,
    required this.builder,
    this.controller,
    this.wheelConfig = const AppWheelScrollConfig(),
  });

  final Widget Function(BuildContext context, AppScrollController controller)
  builder;
  final AppScrollController? controller;
  final AppWheelScrollConfig wheelConfig;

  @override
  State<AppScrollView> createState() => _AppScrollViewState();
}

class _AppScrollViewState extends State<AppScrollView> {
  late AppScrollController _controller;
  late bool _ownsController;

  @override
  void initState() {
    super.initState();
    _setController();
  }

  @override
  void didUpdateWidget(AppScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.wheelConfig != widget.wheelConfig) {
      if (_ownsController) _controller.dispose();
      _setController();
    }
  }

  void _setController() {
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        AppScrollController(wheelConfig: widget.wheelConfig);
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

class _AppScrollPosition extends ScrollPositionWithSingleContext {
  _AppScrollPosition({
    required super.physics,
    required super.context,
    required this.wheelConfig,
    required this.smoothWheelScrolling,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  }) : _scrollContext = context;

  final AppWheelScrollConfig wheelConfig;
  final bool smoothWheelScrolling;
  final ScrollContext _scrollContext;

  double? _wheelTarget;
  int _animationGeneration = 0;

  @override
  void pointerScroll(double delta) {
    if (!_shouldSmooth(delta)) {
      _cancelWheelAnimation();
      super.pointerScroll(delta);
      return;
    }

    final double target = math.min(
      math.max((_wheelTarget ?? pixels) + delta, minScrollExtent),
      maxScrollExtent,
    );
    if (target == pixels) {
      _cancelWheelAnimation();
      super.pointerScroll(delta);
      return;
    }

    _wheelTarget = target;
    final int generation = ++_animationGeneration;
    updateUserScrollDirection(
      delta > 0 ? ScrollDirection.reverse : ScrollDirection.forward,
    );
    animateTo(
      target,
      duration: wheelConfig.duration,
      curve: wheelConfig.curve,
    ).whenComplete(() {
      if (generation == _animationGeneration) _wheelTarget = null;
    });
  }

  bool _shouldSmooth(double delta) {
    if (!smoothWheelScrolling ||
        delta.abs() < wheelConfig.preciseDeltaThreshold) {
      return false;
    }
    final BuildContext? context = _scrollContext.notificationContext;
    return context == null ||
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
  }

  void _cancelWheelAnimation() {
    _wheelTarget = null;
    _animationGeneration++;
  }
}
