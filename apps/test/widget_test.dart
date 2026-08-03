// Basic smoke test for the app UI.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/app.dart';

void main() {
  testWidgets('shows greeting empty state on launch', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(child: App()));

    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text('How can I help you today?'), findsOneWidget);

    final Offset logoCenter = tester.getCenter(find.byIcon(Icons.auto_awesome));
    final Offset titleCenter = tester.getCenter(find.text('Hello there'));
    final Offset subtitleCenter = tester.getCenter(
      find.text('How can I help you today?'),
    );
    expect(logoCenter.dx, closeTo(titleCenter.dx, 1));
    expect(titleCenter.dx, closeTo(subtitleCenter.dx, 1));

    final Rect logo = tester.getRect(find.byIcon(Icons.auto_awesome));
    final Rect subtitle = tester.getRect(
      find.text('How can I help you today?'),
    );
    final Rect input = tester.getRect(find.byType(TextField));
    final double greetingCenter = (logo.top + subtitle.bottom) / 2;
    final double availableCenter = (kToolbarHeight + input.top) / 2;
    expect(greetingCenter, closeTo(availableCenter, 20));
  });

  testWidgets('opens the sidebar from a center-screen swipe', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(child: App()));

    await tester.dragFrom(const Offset(195, 320), const Offset(170, 0));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byIcon(Icons.light_mode_rounded), findsNothing);
    expect(find.byIcon(Icons.dark_mode_rounded), findsNothing);
  });

  testWidgets('typing in the input enables sending a message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: App()));

    await tester.enterText(find.byType(TextField), 'Hello!');
    await tester.pump();

    // Sending should add the user message and switch out of the empty state.
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(find.text('Hello!'), findsOneWidget);
    expect(find.text('Hello there'), findsNothing);

    // Drain the mock reply stream so no timers remain pending at teardown.
    for (int i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  });

  testWidgets('starts a chat while the composer tooltip is visible', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: App()));

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.byTooltip('Tools')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Tools'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Hello!');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(tester.takeException(), isNull);

    for (int i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  });

  testWidgets('opens the desktop tools popover without hiding tile ink', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: App()));

    await tester.tap(find.byTooltip('Tools'));
    await tester.pumpAndSettle();

    expect(find.text('Add images'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
  });

  testWidgets('tolerates a transiently unusable browser viewport', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1, 1);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: App()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
