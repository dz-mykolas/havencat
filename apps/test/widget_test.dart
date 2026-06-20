// Basic smoke test for the HavenChat UI.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:havencat/app.dart';

void main() {
  testWidgets('shows greeting empty state on launch', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: HavenChatApp()));

    // The empty-state greeting and a suggestion chip should be visible.
    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text('How can I help you today?'), findsOneWidget);
    expect(find.text('Help me debug some code'), findsOneWidget);
  });

  testWidgets('typing in the input enables sending a message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: HavenChatApp()));

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
