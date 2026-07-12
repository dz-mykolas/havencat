import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/ui/core/widgets/app_scroll_view.dart';

void main() {
  testWidgets('coarse wheel deltas animate and accumulate', (
    WidgetTester tester,
  ) async {
    final AppScrollController controller = AppScrollController(
      smoothWheelScrolling: true,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_TestScrollView(controller: controller));

    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    final Offset location = tester.getCenter(find.text('Item 2'));
    await tester.sendEventToBinding(pointer.hover(location));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, 120)));
    await tester.pump();
    await tester.pump(Duration(milliseconds: 30));

    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(120));

    await tester.sendEventToBinding(pointer.scroll(Offset(0, 120)));
    await tester.pumpAndSettle();

    expect(controller.offset, closeTo(240, 0.1));
  });

  testWidgets('precise wheel deltas retain immediate native scrolling', (
    WidgetTester tester,
  ) async {
    final AppScrollController controller = AppScrollController(
      smoothWheelScrolling: true,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_TestScrollView(controller: controller));

    final TestPointer pointer = TestPointer(2, PointerDeviceKind.mouse);
    final Offset location = tester.getCenter(find.text('Item 2'));
    await tester.sendEventToBinding(pointer.hover(location));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, 12)));
    await tester.pump();

    expect(controller.offset, 12);
  });

  testWidgets('reduced motion keeps wheel scrolling immediate', (
    WidgetTester tester,
  ) async {
    final AppScrollController controller = AppScrollController(
      smoothWheelScrolling: true,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _TestScrollView(controller: controller, disableAnimations: true),
    );

    final TestPointer pointer = TestPointer(3, PointerDeviceKind.mouse);
    final Offset location = tester.getCenter(find.text('Item 2'));
    await tester.sendEventToBinding(pointer.hover(location));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, 120)));
    await tester.pump();

    expect(controller.offset, 120);
  });

  testWidgets('touch drag remains native', (WidgetTester tester) async {
    final AppScrollController controller = AppScrollController(
      smoothWheelScrolling: true,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_TestScrollView(controller: controller));

    await tester.drag(find.text('Item 2'), Offset(0, -180));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });
}

class _TestScrollView extends StatelessWidget {
  const _TestScrollView({
    required this.controller,
    this.disableAnimations = false,
  });

  final AppScrollController controller;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: 40,
            itemBuilder: (BuildContext context, int index) =>
                SizedBox(height: 60, child: Text('Item $index')),
          ),
        ),
      ),
    );
  }
}
