// Verifies the tap-pulse comet travels along the pill border from the
// bottom-left corner, up the left side, across the top, to the top-right
// corner.

import 'dart:ui' show PathMetric, PathMetrics, Tangent;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double _startFrac = 0.95;
const double _endFrac = 0.45;
const double _travelFrac = (_endFrac - _startFrac + 1) % 1; // 0.5

void main() {
  test('comet head travels from bottom-left to top-right', () {
    const Size size = Size(400, 60);
    const double radius = 26;
    const double stroke = 2.5;
    final RRect rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(radius),
    );
    final Path path = Path()..addRRect(rrect.deflate(stroke / 2));
    final PathMetrics metrics = path.computeMetrics();
    final PathMetric m = metrics.first;
    final double len = m.length;

    Offset posAt(double pulseT) {
      final double f = (_startFrac + _travelFrac * pulseT) % 1;
      return m.getTangentForOffset(f * len)!.position;
    }

    final Offset start = posAt(0.0); // bottom-left region
    final Offset q1 = posAt(0.25); // up the left side / top-left
    final Offset mid = posAt(0.5); // top edge, past center
    final Offset end = posAt(1.0); // top-right region
    // ignore: avoid_print
    print('start=$start q1=$q1 mid=$mid end=$end len=$len');

    // Start: bottom-left corner region (low x, high y).
    expect(start.dx, lessThan(40));
    expect(start.dy, greaterThan(size.height - 5));

    // Quarter: on the top edge near the left side (already up the left side).
    expect(q1.dy, lessThan(stroke + 2));
    expect(q1.dx, lessThan(60));

    // Mid: on the top edge.
    expect(mid.dy, lessThan(stroke + 2));

    // End: top-right corner region (high x, low y).
    expect(end.dx, greaterThan(size.width - 40));
    expect(end.dy, lessThan(stroke + 2));
  });
}
