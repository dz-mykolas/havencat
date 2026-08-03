import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/ui/chat/widgets/chat_markdown.dart';

void main() {
  testWidgets('inline code copy icon copies inside a selection area', (
    WidgetTester tester,
  ) async {
    String? copied;
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatMarkdown(text: 'Use `ABC-123`', selectable: true),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();

    expect(copied, 'ABC-123');
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('long inline copy code wraps on narrow messages', (
    WidgetTester tester,
  ) async {
    const String code =
        'MOCK1-WIN11-HOME0-DEMO0-XXXXX-EXTRA-LONG-COPYABLE-VALUE';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: ChatMarkdown(text: 'Code: `$code`', selectable: true),
          ),
        ),
      ),
    );

    final Size codeSize = tester.getSize(find.text(code));
    expect(codeSize.width, lessThanOrEqualTo(160));
    expect(codeSize.height, greaterThan(20));
    expect(tester.takeException(), isNull);
  });
}
