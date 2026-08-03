import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/app.dart';
import 'package:app/app_router.dart';
import 'package:app/data/services/storage/conversation_store.dart';
import 'package:app/domain/models/conversation.dart';
import 'package:app/domain/models/message.dart';
import 'package:app/providers.dart';
import 'package:app/ui/chat/widgets/chat_input.dart';

void main() {
  testWidgets('chat clears the measured composer and respects manual scroll', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Conversation conversation = _conversation();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        conversationStoreProvider.overrideWithValue(
          _SeededConversationStore(conversation),
        ),
      ],
    );
    addTearDown(container.dispose);
    final repository = container.read(conversationRepositoryProvider);
    await repository.ready;
    repository.selectConversation(conversation.id);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: App(initialLocation: chatRouteFor(conversation.id)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'one\ntwo\nthree\nfour\nfive',
    );
    await tester.pumpAndSettle();

    final ListView list = tester.widget<ListView>(find.byType(ListView));
    final ScrollController controller = list.controller!;
    final double composerHeight = tester.getSize(find.byType(ChatInput)).height;
    final EdgeInsets padding = list.padding! as EdgeInsets;
    expect(padding.bottom, greaterThanOrEqualTo(composerHeight + 27 + 64));
    expect(
      controller.offset,
      closeTo(controller.position.maxScrollExtent, 0.5),
    );
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey<String>('message-23'))).dy,
      lessThan(tester.getTopLeft(find.byType(ChatInput)).dy),
    );

    await tester.drag(find.byType(ListView), const Offset(0, 260));
    await tester.pump();
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
    final double readingOffset = controller.offset;

    await tester.enterText(find.byType(TextField), 'short');
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(readingOffset, 0.5));

    await tester.tap(find.byTooltip('Jump to latest'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest'), findsNothing);
    expect(
      controller.offset,
      closeTo(controller.position.maxScrollExtent, 0.5),
    );
  });

  testWidgets('hovering either side reveals actions for the whole turn', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Conversation conversation = _hoverConversation();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        conversationStoreProvider.overrideWithValue(
          _SeededConversationStore(conversation),
        ),
      ],
    );
    addTearDown(container.dispose);
    final repository = container.read(conversationRepositoryProvider);
    await repository.ready;
    repository.selectConversation(conversation.id);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: App(initialLocation: chatRouteFor(conversation.id)),
      ),
    );
    await tester.pumpAndSettle();

    final Finder firstUserActions = find.byKey(
      const ValueKey<String>('user-message-actions-user-1'),
    );
    final Finder firstReplyActions = find.byKey(
      const ValueKey<String>('assistant-message-actions-reply-1'),
    );
    final Finder latestReplyActions = find.byKey(
      const ValueKey<String>('assistant-message-actions-reply-2'),
    );
    expect(tester.widget<AnimatedOpacity>(firstUserActions).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(firstReplyActions).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(latestReplyActions).opacity, 1);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.text('First user message')));
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(firstUserActions).opacity, 1);
    expect(tester.widget<AnimatedOpacity>(firstReplyActions).opacity, 1);

    await mouse.moveTo(tester.getCenter(find.text('Unanswered user message')));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(firstUserActions).opacity, 0);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey<String>('user-message-actions-user-3')),
          )
          .opacity,
      1,
    );
    expect(tester.widget<AnimatedOpacity>(latestReplyActions).opacity, 1);
  });
}

Conversation _conversation() {
  final List<ChatMessage> messages = <ChatMessage>[];
  for (int index = 0; index < 24; index++) {
    final ChatMessage message = ChatMessage(
      id: 'message-$index',
      role: index.isEven ? MessageRole.user : MessageRole.assistant,
      text: 'Message $index with enough text to occupy a visible chat row.',
      parentId: index == 0 ? null : 'message-${index - 1}',
    );
    if (messages.isNotEmpty) messages.last.childrenIds.add(message.id);
    messages.add(message);
  }
  return Conversation(
    id: 'scroll-test',
    title: 'Scroll test',
    messages: messages,
  );
}

Conversation _hoverConversation() {
  final List<ChatMessage> messages = <ChatMessage>[
    ChatMessage(
      id: 'user-1',
      role: MessageRole.user,
      text: 'First user message',
    ),
    ChatMessage(
      id: 'reply-1',
      role: MessageRole.assistant,
      text: 'First assistant reply',
      parentId: 'user-1',
    ),
    ChatMessage(
      id: 'user-2',
      role: MessageRole.user,
      text: 'Second user message',
      parentId: 'reply-1',
    ),
    ChatMessage(
      id: 'reply-2',
      role: MessageRole.assistant,
      text: 'Second assistant reply',
      parentId: 'user-2',
    ),
    ChatMessage(
      id: 'user-3',
      role: MessageRole.user,
      text: 'Unanswered user message',
      parentId: 'reply-2',
    ),
  ];
  for (int index = 1; index < messages.length; index++) {
    messages[index - 1].childrenIds.add(messages[index].id);
  }
  return Conversation(
    id: 'hover-test',
    title: 'Hover test',
    messages: messages,
  );
}

class _SeededConversationStore implements ConversationStore {
  _SeededConversationStore(this.conversation);

  final Conversation conversation;

  @override
  Future<List<Conversation>> load() async => <Conversation>[conversation];

  @override
  Future<void> upsert(Conversation conversation) async {}

  @override
  Future<void> delete(String id) async {}
}
