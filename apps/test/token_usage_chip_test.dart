import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/ui/chat/widgets/token_usage_chip.dart';

void main() {
  testWidgets('streaming estimate grows with live completion tokens', (
    WidgetTester tester,
  ) async {
    Widget app(int completion) {
      return MaterialApp(
        home: Scaffold(
          body: TokenUsageChip(
            actualTokens: null,
            completionTokens: null,
            totalTokens: null,
            estimatedTokens: 100,
            estimatedCompletionTokens: completion,
            contextWindow: 128000,
            isGenerating: true,
          ),
        ),
      );
    }

    await tester.pumpWidget(app(4));
    expect(find.text('~104 / 128k'), findsOneWidget);

    await tester.pumpWidget(app(12));
    await tester.pump();
    expect(find.text('~112 / 128k'), findsOneWidget);
    final Tooltip tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('Input: ~100'));
    expect(tooltip.message, contains('Output: ~12'));
  });
}
