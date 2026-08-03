import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/repositories/conversation_repository.dart';
import 'package:app/data/repositories/provider_account_repository.dart';
import 'package:app/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:app/data/services/auth/chatgpt_token_service.dart';
import 'package:app/data/services/auth/credential_resolver.dart';
import 'package:app/data/services/auth/secret_store.dart';
import 'package:app/data/services/generation/in_memory_generation_task_store.dart';
import 'package:app/data/services/llm/adapter_registry.dart';
import 'package:app/data/services/llm/llm_adapter.dart';
import 'package:app/data/services/llm/llm_event.dart';
import 'package:app/data/services/storage/account_store.dart';
import 'package:app/data/services/web_retrieval/web_retrieval.dart';
import 'package:app/domain/models/adapter_kind.dart';
import 'package:app/domain/models/conversation.dart';
import 'package:app/domain/models/generation_task.dart';
import 'package:app/domain/models/llm_model.dart';
import 'package:app/domain/models/message.dart';
import 'package:app/domain/models/provider_account.dart';
import 'package:app/domain/models/web_search_result_payload.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';

/// A mock [LlmAdapter] that replays a scripted list of [LlmEvent] sequences.
///
/// Each call to [stream] pops the next sequence from [_rounds] and emits its
/// events. This lets us test the tool-call loop: round 1 emits tool calls,
/// round 2 emits a final text reply.
class _ScriptedAdapter implements LlmAdapter {
  _ScriptedAdapter(this._rounds);

  final List<List<LlmEvent>> _rounds;
  int _callCount = 0;
  int get callCount => _callCount;

  /// The last [LlmRequest] passed to [stream], for assertions.
  LlmRequest? lastRequest;

  @override
  AdapterKind get kind => AdapterKind.mock;

  @override
  Stream<LlmEvent> stream({
    required LlmRequest request,
    required ProviderAccount account,
    required String? secret,
  }) {
    lastRequest = request;
    final int round = _callCount++;
    final List<LlmEvent> events = round < _rounds.length
        ? _rounds[round]
        : const <LlmEvent>[];

    return Stream<LlmEvent>.fromIterable(events);
  }

  @override
  Future<List<LlmModel>> listModels({
    required ProviderAccount account,
    required String? secret,
  }) async => const <LlmModel>[];
}

/// A fake [WebRetrievalAdapter] that returns canned results.
class _FakeWebRetrieval implements WebRetrievalAdapter {
  @override
  String get kind => 'fake';

  @override
  Future<WebSearchResponse> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  }) async {
    return WebSearchResponse(
      results: <WebSearchResult>[
        WebSearchResult(
          title: 'Result for $query',
          url: 'https://example.com/$query',
          snippet: 'Snippet about $query',
          provider: 'test',
        ),
      ],
    );
  }

  @override
  Future<FetchedPage> fetch(
    String url, {
    FetchFormat format = FetchFormat.markdown,
  }) async {
    return FetchedPage(
      url: url,
      title: 'Fetched: $url',
      content: 'Content of $url',
      contentType: 'text/markdown',
    );
  }
}

class _FailingWebRetrieval extends _FakeWebRetrieval {
  @override
  Future<WebSearchResponse> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  }) async {
    return const WebSearchResponse(
      results: <WebSearchResult>[],
      issues: <WebProviderIssue>[
        WebProviderIssue(provider: 'searxng', kind: 'authentication'),
      ],
    );
  }
}

class _CountingGenerationTaskStore extends InMemoryGenerationTaskStore {
  int checkpointCount = 0;
  int commandPollCount = 0;

  @override
  Future<void> checkpoint({
    required Conversation conversation,
    required GenerationTask task,
  }) {
    checkpointCount++;
    return super.checkpoint(conversation: conversation, task: task);
  }

  @override
  Future<List<GenerationCommand>> pendingCommands(String taskId) {
    commandPollCount++;
    return super.pendingCommands(taskId);
  }
}

void main() {
  late ProviderAccountRepository providers;
  late AdapterRegistry adapters;
  late CredentialResolver credentials;

  setUp(() async {
    final accountStore = AccountStore();
    final secretStore = SecretStore();
    providers = ProviderAccountRepository(
      accountStore: accountStore,
      secretStore: secretStore,
    );
    // The repo seeds a default mock account; just set its model.
    final seeded = providers.accounts.first;
    await providers.setModel(seeded.id, 'mock-model');
    credentials = CredentialResolver(
      secretStore: secretStore,
      chatGptTokens: ChatGptTokenService(
        secretStore: secretStore,
        oauthFlow: ChatGptOAuthFlow(dio: Dio()),
      ),
    );
  });

  group('ConversationRepository tool-call loop', () {
    test('no tools sent when toolsEnabled is false', () async {
      final adapter = _ScriptedAdapter(<List<LlmEvent>>[
        <LlmEvent>[
          const TokenEvent('Hello'),
          const DoneEvent(finishReason: 'stop'),
        ],
      ]);
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);

      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        webRetrieval: _FakeWebRetrieval(),
        toolsEnabled: false,
      );

      await repo.sendMessage('hi');

      expect(adapter.lastRequest!.tools, isEmpty);
      final messages = repo.active.messages;
      expect(messages.length, 2); // user + assistant
      expect(messages.last.role, MessageRole.assistant);
      expect(messages.last.text, 'Hello');
    });

    test('tools sent when toolsEnabled is true', () async {
      final adapter = _ScriptedAdapter(<List<LlmEvent>>[
        <LlmEvent>[
          const TokenEvent('Reply'),
          const DoneEvent(finishReason: 'stop'),
        ],
      ]);
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);

      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        webRetrieval: _FakeWebRetrieval(),
        toolsEnabled: true,
      );

      await repo.sendMessage('hi');

      expect(adapter.lastRequest!.tools.length, 2);
      expect(
        adapter.lastRequest!.tools.map((t) => t.name).toList(),
        containsAll(<String>['web_search', 'fetch_page']),
      );
    });

    test('executes tool call and re-streams with results', () async {
      final adapter = _ScriptedAdapter(<List<LlmEvent>>[
        // Round 1: model calls web_search.
        <LlmEvent>[
          const ToolCallEvent(
            id: 'call_1',
            name: 'web_search',
            args: '{"query":"rust sqlite"}',
          ),
          const DoneEvent(finishReason: 'tool_calls'),
        ],
        // Round 2: model uses the results.
        <LlmEvent>[
          const TokenEvent('Based on my search, '),
          const TokenEvent('SQLite is great.'),
          const DoneEvent(finishReason: 'stop'),
        ],
      ]);
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);

      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        webRetrieval: _FakeWebRetrieval(),
        toolsEnabled: true,
      );

      await repo.sendMessage('search for rust sqlite');

      // user + assistant(tool_call) + tool(result) + assistant(final)
      final messages = repo.active.messages;
      expect(messages.length, 4);

      // Assistant message with tool call.
      final assistantWithCall = messages[1];
      expect(assistantWithCall.role, MessageRole.assistant);
      expect(assistantWithCall.toolCalls.length, 1);
      expect(assistantWithCall.toolCalls.first.name, 'web_search');
      expect(assistantWithCall.toolCalls.first.args, '{"query":"rust sqlite"}');

      // Tool result message.
      final toolResult = messages[2];
      expect(toolResult.role, MessageRole.tool);
      expect(toolResult.toolCallId, 'call_1');
      expect(toolResult.text, contains('Result for rust sqlite'));
      expect(toolResult.text, contains('https://example.com/rust sqlite'));

      // Final assistant reply.
      final finalReply = messages[3];
      expect(finalReply.role, MessageRole.assistant);
      expect(finalReply.text, 'Based on my search, SQLite is great.');

      // The adapter was called twice (two rounds).
      expect(adapter.callCount, 2);
    });

    test('accumulates fragmented tool call arguments', () async {
      final adapter = _ScriptedAdapter(<List<LlmEvent>>[
        // Round 1: OpenAI streams tool_calls in fragments — id+name first,
        // then argument tokens.
        <LlmEvent>[
          const ToolCallEvent(id: 'call_1', name: 'web_search', args: ''),
          const ToolCallEvent(id: '', name: '', args: '{"qu'),
          const ToolCallEvent(id: '', name: '', args: 'ery":"test"}'),
          const DoneEvent(finishReason: 'tool_calls'),
        ],
        // Round 2: final reply.
        <LlmEvent>[
          const TokenEvent('Done.'),
          const DoneEvent(finishReason: 'stop'),
        ],
      ]);
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);

      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        webRetrieval: _FakeWebRetrieval(),
        toolsEnabled: true,
      );

      await repo.sendMessage('search');

      final messages = repo.active.messages;
      // The tool call args should be accumulated correctly.
      final assistantWithCall = messages[1];
      expect(assistantWithCall.toolCalls.length, 1);
      expect(assistantWithCall.toolCalls.first.id, 'call_1');
      expect(assistantWithCall.toolCalls.first.name, 'web_search');
      expect(assistantWithCall.toolCalls.first.args, '{"query":"test"}');

      // Tool result should contain the query.
      final toolResult = messages[2];
      expect(toolResult.text, contains('Result for test'));
    });

    test('caps at 5 rounds to prevent infinite loops', () async {
      // Every round emits a tool call — the loop should stop after 5.
      final endlessRounds = List<List<LlmEvent>>.generate(
        10,
        (_) => <LlmEvent>[
          const ToolCallEvent(
            id: 'call_1',
            name: 'web_search',
            args: '{"query":"loop"}',
          ),
          const DoneEvent(finishReason: 'tool_calls'),
        ],
      );
      final adapter = _ScriptedAdapter(endlessRounds);
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);

      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        webRetrieval: _FakeWebRetrieval(),
        toolsEnabled: true,
      );

      await repo.sendMessage('loop');

      // Should have stopped after 5 rounds, not 10.
      expect(adapter.callCount, 5);
      expect(repo.isGenerating, isFalse);
    });

    test('handles error event without executing tools', () async {
      final adapter = _ScriptedAdapter(<List<LlmEvent>>[
        <LlmEvent>[const ErrorEvent(AuthError('Bad key'))],
      ]);
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);

      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        webRetrieval: _FakeWebRetrieval(),
        toolsEnabled: true,
      );

      await repo.sendMessage('hi');

      final messages = repo.active.messages;
      expect(messages.length, 2); // user + assistant(error)
      expect(messages.last.role, MessageRole.assistant);
      expect(messages.last.text, contains('Bad key'));
      expect(adapter.callCount, 1);
    });

    test('handles multiple tool calls in one round', () async {
      final adapter = _ScriptedAdapter(<List<LlmEvent>>[
        // Round 1: model calls web_search twice.
        <LlmEvent>[
          const ToolCallEvent(
            id: 'call_1',
            name: 'web_search',
            args: '{"query":"rust"}',
          ),
          const ToolCallEvent(
            id: 'call_2',
            name: 'web_search',
            args: '{"query":"sqlite"}',
          ),
          const DoneEvent(finishReason: 'tool_calls'),
        ],
        // Round 2: final reply.
        <LlmEvent>[
          const TokenEvent('Both done.'),
          const DoneEvent(finishReason: 'stop'),
        ],
      ]);
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);

      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        webRetrieval: _FakeWebRetrieval(),
        toolsEnabled: true,
      );

      await repo.sendMessage('search rust and sqlite');

      final messages = repo.active.messages;
      // user + assistant(2 calls) + tool(result1) + tool(result2) + assistant
      expect(messages.length, 5);

      final assistantWithCalls = messages[1];
      expect(assistantWithCalls.toolCalls.length, 2);

      // Both tool results should be present.
      expect(messages[2].role, MessageRole.tool);
      expect(messages[2].toolCallId, 'call_1');
      expect(messages[2].text, contains('Result for rust'));

      expect(messages[3].role, MessageRole.tool);
      expect(messages[3].toolCallId, 'call_2');
      expect(messages[3].text, contains('Result for sqlite'));
    });

    test('appends "not configured" when webRetrieval is null', () async {
      final adapter = _ScriptedAdapter(<List<LlmEvent>>[
        <LlmEvent>[
          const ToolCallEvent(
            id: 'call_1',
            name: 'web_search',
            args: '{"query":"test"}',
          ),
          const DoneEvent(finishReason: 'tool_calls'),
        ],
        <LlmEvent>[
          const TokenEvent('No results available.'),
          const DoneEvent(finishReason: 'stop'),
        ],
      ]);
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);

      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        webRetrieval: null,
        toolsEnabled: true,
      );

      await repo.sendMessage('search');

      final messages = repo.active.messages;
      final toolResult = messages[2];
      expect(toolResult.role, MessageRole.tool);
      expect(toolResult.text, 'Web search not configured.');
    });

    test('coalesces burst token updates and durable stream work', () async {
      const int tokenCount = 400;
      final adapter = _ScriptedAdapter(<List<LlmEvent>>[
        <LlmEvent>[
          ...List<LlmEvent>.generate(tokenCount, (_) => const TokenEvent('x')),
          const DoneEvent(finishReason: 'stop'),
        ],
      ]);
      final _CountingGenerationTaskStore taskStore =
          _CountingGenerationTaskStore();
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);
      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        generationTaskStore: taskStore,
      );
      int notificationCount = 0;
      repo.addListener(() => notificationCount++);

      await repo.sendMessage('stream quickly');

      expect(
        repo.active.messages.last.text,
        List<String>.filled(tokenCount, 'x').join(),
      );
      expect(taskStore.checkpointCount, lessThanOrEqualTo(3));
      expect(taskStore.commandPollCount, lessThanOrEqualTo(4));
      expect(notificationCount, lessThan(20));
    });

    test('surfaces a failed web tool and marks its result as failed', () async {
      final adapter = _ScriptedAdapter(<List<LlmEvent>>[
        <LlmEvent>[
          const ToolCallEvent(
            id: 'call_1',
            name: 'web_search',
            args: '{"query":"test"}',
          ),
          const DoneEvent(finishReason: 'tool_calls'),
        ],
        <LlmEvent>[
          const TokenEvent('The search backend failed.'),
          const DoneEvent(finishReason: 'stop'),
        ],
      ]);
      adapters = AdapterRegistry()..register(AdapterKind.mock, adapter);
      final repo = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: adapters,
        credentialResolver: credentials,
        webRetrieval: _FailingWebRetrieval(),
        toolsEnabled: true,
      );

      await repo.sendMessage('search');

      final ChatMessage toolResult = repo.active.messages[2];
      expect(toolResult.role, MessageRole.tool);
      expect(toolResult.hasError, isTrue);
      expect(toolResult.text, contains('SearXNG credentials were rejected'));
      expect(repo.lastFailure?.kind, FailureKind.authentication);
      expect(repo.lastFailure?.source.providerId, 'searxng');
    });
  });

  testWidgets('tool call row shows the web search query only when expanded', (
    WidgetTester tester,
  ) async {
    final ChatMessage assistant = ChatMessage(
      id: 'assistant',
      role: MessageRole.assistant,
      toolCalls: <ToolCall>[
        ToolCall(
          id: 'call_1',
          name: 'web_search',
          args: '{"query":"rust sqlite mobile"}',
        ),
      ],
    );
    final ChatMessage result = ChatMessage(
      id: 'result',
      role: MessageRole.tool,
      text: const WebSearchResultPayload(
        query: 'rust sqlite mobile',
        results: <WebSearchResultItem>[
          WebSearchResultItem(
            title: 'SQLite in mobile Rust apps',
            url: 'https://example.com/guides/mobile-rust',
            snippet:
                'A practical guide to embedding SQLite in a Rust mobile app.',
            provider: 'test',
          ),
        ],
      ).encode(),
      toolCallId: 'call_1',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: assistant,
            messages: <ChatMessage>[assistant, result],
          ),
        ),
      ),
    );

    expect(find.text('Web search'), findsOneWidget);
    expect(find.text('Completed'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('rust sqlite mobile'), findsNothing);
    expect(find.text('REQUEST'), findsNothing);
    expect(find.text('RESULTS'), findsNothing);
    final Offset labelPosition = tester.getTopLeft(find.text('Web search'));
    final Offset iconPosition = tester.getTopLeft(
      find.byIcon(Icons.travel_explore_rounded),
    );
    final double labelCenterY = tester.getCenter(find.text('Web search')).dy;
    expect(
      tester.getCenter(find.byIcon(Icons.travel_explore_rounded)).dy,
      moreOrLessEquals(labelCenterY, epsilon: 1),
    );
    expect(
      tester.getCenter(find.byIcon(Icons.check)).dy,
      moreOrLessEquals(labelCenterY, epsilon: 1),
    );
    expect(
      tester.getCenter(find.byIcon(Icons.expand_more_rounded)).dy,
      moreOrLessEquals(labelCenterY, epsilon: 1),
    );

    await tester.tap(find.text('Web search'));
    await tester.pump();
    final double statusStart = tester.getTopLeft(find.text('Completed')).dx;
    await tester.pump(const Duration(milliseconds: 70));
    final double statusMiddle = tester.getTopLeft(find.text('Completed')).dx;
    expect(find.byIcon(Icons.check), findsNWidgets(2));
    await tester.pumpAndSettle();
    final double statusEnd = tester.getTopLeft(find.text('Completed')).dx;

    expect(find.text('Completed'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(statusMiddle, greaterThan(statusStart));
    expect(statusEnd, greaterThan(statusMiddle));
    expect(tester.getTopLeft(find.text('Web search')), labelPosition);
    expect(
      tester.getTopLeft(find.byIcon(Icons.travel_explore_rounded)),
      iconPosition,
    );
    expect(
      tester.getTopLeft(find.byIcon(Icons.check)).dx,
      moreOrLessEquals(labelPosition.dx, epsilon: 1),
    );
    expect(
      tester.getTopLeft(find.text('Completed')).dy,
      greaterThan(tester.getBottomLeft(find.text('Web search')).dy),
    );
    expect(find.text('REQUEST'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('Completed')).dy,
      lessThan(tester.getTopLeft(find.text('REQUEST')).dy),
    );
    expect(find.text('rust sqlite mobile'), findsOneWidget);
    expect(find.text('RESULTS'), findsOneWidget);
    expect(
      find.textContaining('SQLite in mobile Rust apps', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('example.com/guides/mobile-rust', findRichText: true),
      findsOneWidget,
    );
    final GestureDetector resultLink = tester.widget<GestureDetector>(
      find.byKey(const ValueKey<String>('web-search-result-0')),
    );
    expect(resultLink.onTap, isNotNull);
    final MouseRegion resultCursor = tester.widget<MouseRegion>(
      find.byKey(const ValueKey<String>('web-search-result-cursor-0')),
    );
    expect(resultCursor.cursor, SystemMouseCursors.click);
    expect(
      find.text('A practical guide to embedding SQLite in a Rust mobile app.'),
      findsOneWidget,
    );
    expect(find.textContaining('"type":"web_search_results"'), findsNothing);
  });

  testWidgets('user actions appear beneath without changing row height', (
    WidgetTester tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final ChatMessage message = ChatMessage(
      id: 'user',
      role: MessageRole.user,
      text: 'Editable message',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            onEditUser: (String text, bool resend) {},
          ),
        ),
      ),
    );

    final Finder actions = find.byKey(
      const ValueKey<String>('user-message-actions-user'),
    );
    expect(tester.widget<AnimatedOpacity>(actions).opacity, 0);
    final double heightBefore = tester
        .getSize(find.byType(MessageBubble))
        .height;

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.text('Editable message')));
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(actions).opacity, 1);
    expect(tester.getSize(find.byType(MessageBubble)).height, heightBefore);
    final Rect copyRect = tester.getRect(
      find.byKey(const ValueKey<String>('user-copy-control-user')),
    );
    final Rect editRect = tester.getRect(
      find.byKey(const ValueKey<String>('user-edit-control-user')),
    );
    expect(copyRect.center.dx, lessThan(editRect.center.dx));
    expect(copyRect.width, greaterThanOrEqualTo(30));
    expect(copyRect.height, greaterThanOrEqualTo(30));
    expect(editRect.left - copyRect.right, greaterThanOrEqualTo(4));
    expect(tester.getSize(actions).height, 38);
    expect(
      copyRect.top,
      greaterThan(tester.getRect(find.text('Editable message')).bottom),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('user-copy-control-user')),
    );
    expect(copiedText, 'Editable message');

    await tester.tap(
      find.byKey(const ValueKey<String>('user-edit-control-user')),
    );
    await tester.pump();
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('touch hold opens user message action sheet', (
    WidgetTester tester,
  ) async {
    final ChatMessage message = ChatMessage(
      id: 'user',
      role: MessageRole.user,
      text: 'Hold this message',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            onEditUser: (String text, bool resend) {},
          ),
        ),
      ),
    );

    final Finder actions = find.byKey(
      const ValueKey<String>('user-message-actions-user'),
    );
    expect(tester.widget<AnimatedOpacity>(actions).opacity, 0);

    await tester.longPress(find.text('Hold this message'));
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(actions).opacity, 0);
    expect(find.text('Copy message'), findsOneWidget);
    expect(find.text('Edit message'), findsOneWidget);
  });

  testWidgets('latest assistant actions stay visible and older ones hover', (
    WidgetTester tester,
  ) async {
    String? copiedText;
    bool regenerated = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              MessageBubble(
                message: ChatMessage(
                  id: 'older',
                  role: MessageRole.assistant,
                  text: 'Older reply',
                ),
                onRegenerate: ({String? suggestion}) {
                  regenerated = true;
                },
              ),
              MessageBubble(
                message: ChatMessage(
                  id: 'latest',
                  role: MessageRole.assistant,
                  text: 'Latest reply',
                ),
                isLatestAssistant: true,
                onRegenerate: ({String? suggestion}) {},
              ),
            ],
          ),
        ),
      ),
    );

    final Finder olderActions = find.byKey(
      const ValueKey<String>('assistant-message-actions-older'),
    );
    final Finder latestActions = find.byKey(
      const ValueKey<String>('assistant-message-actions-latest'),
    );
    expect(tester.widget<AnimatedOpacity>(olderActions).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(latestActions).opacity, 1);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.text('Older reply')));
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(olderActions).opacity, 1);
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-copy-control-older')),
    );
    expect(copiedText, 'Older reply');

    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-regenerate-control-older')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Regenerate'));
    await tester.pumpAndSettle();
    expect(regenerated, isTrue);
  });

  testWidgets('message editor clearly separates saving from sending again', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? submittedText;
    bool? submittedAsResend;
    final ChatMessage message = ChatMessage(
      id: 'user',
      role: MessageRole.user,
      text: 'Original message',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            descendantCount: 2,
            onEditUser: (String text, bool resend) {
              submittedText = text;
              submittedAsResend = resend;
            },
          ),
        ),
      ),
    );

    await tester.longPress(find.text('Original message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit message'));
    await tester.pumpAndSettle();

    expect(find.text('2'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    final Finder branchTooltip = find.byWidgetPredicate(
      (Widget widget) =>
          widget is Tooltip &&
          (widget.message?.contains('available after sending') ?? false),
    );
    expect(
      tester.widget<Tooltip>(branchTooltip).message,
      '2 later messages stay available after sending',
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.done_all_rounded),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Send'))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField), 'Updated message');
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.done_all_rounded),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Send'))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(submittedText, 'Updated message');
    expect(submittedAsResend, isTrue);
  });
}
