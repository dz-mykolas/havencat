import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Smooth scrolling for Flutter web.
///
/// Intercepts mouse-wheel events and animates the scroll position smoothly
/// instead of jumping instantly (Flutter web's default behaviour).
///
/// Usage: wrap your [ListView] with this widget, passing the same
/// [ScrollController].
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({
    super.key,
    required this.controller,
    required this.child,
    this.scrollSpeed = 2.5,
    this.scrollAnimationLength = 600,
    this.curve = Curves.easeOutCubic,
  });

  final ScrollController controller;
  final Widget child;
  final double scrollSpeed;
  final int scrollAnimationLength;
  final Curve curve;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  double _targetScroll = 0;
  bool _isAnimating = false;
  DateTime _lastScrollTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrollListener);
    _targetScroll = widget.controller.initialScrollOffset;
  }

  @override
  void didUpdateWidget(covariant SmoothScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scrollListener);
      widget.controller.addListener(_scrollListener);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrollListener);
    super.dispose();
  }

  void _scrollListener() {
    if (!_isAnimating && widget.controller.hasClients) {
      _targetScroll = widget.controller.offset;
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Consume the event so the Scrollable's default instant-jump doesn't fire.
    GestureBinding.instance.pointerSignalResolver.register(event, _resolve);
  }

  void _resolve(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!widget.controller.hasClients) return;

    final now = DateTime.now();
    final timeDiff = now.difference(_lastScrollTime).inMilliseconds;
    _lastScrollTime = now;

    _targetScroll += (event.scrollDelta.dy * widget.scrollSpeed);

    final maxExtent = widget.controller.position.maxScrollExtent;
    if (_targetScroll > maxExtent) _targetScroll = maxExtent;
    if (_targetScroll < 0) _targetScroll = 0;

    int animationDuration = timeDiff < 50
        ? widget.scrollAnimationLength ~/ 4
        : widget.scrollAnimationLength;

    if (_targetScroll == maxExtent || _targetScroll == 0) {
      animationDuration = widget.scrollAnimationLength ~/ 4;
    }

    _isAnimating = true;
    widget.controller
        .animateTo(
          _targetScroll,
          duration: Duration(milliseconds: animationDuration),
          curve: widget.curve,
        )
        .then((_) {
          _isAnimating = false;
        });
  }

  @override
  Widget build(BuildContext context) {
    // We disable the Scrollable's own wheel handling by giving it a physics
    // where shouldAcceptUserOffset returns false. This makes
    // _receivedPointerSignal in Scrollable early-return, so it never registers
    // with the pointerSignalResolver. Our Listener (parent) then wins the
    // resolver and drives the smooth animation.
    //
    // Touch dragging still works because it goes through the gesture arena,
    // not the pointer signal path.
    //
    // Explicit Scrollbar replaces the default RawScrollbar (which is thinner
    // and styled differently) with the Material Scrollbar.
    return Scrollbar(
      controller: widget.controller,
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(
            physics: const _BlockWheelPhysics(),
            scrollbars: false,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Physics that rejects pointer-signal (wheel) scrolling so the Scrollable
/// doesn't process wheel events. Touch drags still work (they use the gesture
/// arena, not pointer signals).
class _BlockWheelPhysics extends ScrollPhysics {
  const _BlockWheelPhysics({super.parent});

  @override
  _BlockWheelPhysics applyTo(ScrollPhysics? ancestor) {
    return _BlockWheelPhysics(parent: buildParent(ancestor));
  }

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    // Returning false makes Scrollable._receivedPointerSignal early-return,
    // so it never registers with the pointerSignalResolver for wheel events.
    return false;
  }
}
