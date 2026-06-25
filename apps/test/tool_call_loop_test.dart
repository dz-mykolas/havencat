import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/repositories/conversation_repository.dart';
import 'package:app/data/repositories/provider_account_repository.dart';
import 'package:app/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:app/data/services/auth/chatgpt_token_service.dart';
import 'package:app/data/services/auth/credential_resolver.dart';
import 'package:app/data/services/auth/secret_store.dart';
import 'package:app/data/services/llm/adapter_registry.dart';
import 'package:app/data/services/llm/llm_adapter.dart';
import 'package:app/data/services/llm/llm_event.dart';
import 'package:app/data/services/storage/account_store.dart';
import 'package:app/data/services/web_retrieval/web_retrieval.dart';
import 'package:app/domain/models/adapter_kind.dart';
import 'package:app/domain/models/llm_model.dart';
import 'package:app/domain/models/message.dart';
import 'package:app/domain/models/provider_account.dart';

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
  Future<List<WebSearchResult>> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  }) async {
    return <WebSearchResult>[
      WebSearchResult(
        title: 'Result for $query',
        url: 'https://example.com/$query',
        snippet: 'Snippet about $query',
        provider: 'test',
      ),
    ];
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
  });
}
