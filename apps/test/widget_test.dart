// Basic smoke test for the app UI.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/app.dart';

void main() {
  testWidgets('shows greeting empty state on launch', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: App()));

    // The empty-state greeting should be visible.
    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text('How can I help you today?'), findsOneWidget);
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

    expect(find.byTooltip('Use light theme'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
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
}
