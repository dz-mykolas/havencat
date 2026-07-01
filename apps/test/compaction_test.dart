import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/services/llm/context_compaction.dart';
import 'package:app/data/services/llm/llm_adapter.dart';
import 'package:app/data/services/llm/llm_event.dart';
import 'package:app/data/services/llm/secret_redaction.dart';
import 'package:app/data/services/llm/token_estimator.dart';
import 'package:app/domain/models/adapter_kind.dart';
import 'package:app/domain/models/llm_model.dart';
import 'package:app/domain/models/message.dart';
import 'package:app/domain/models/provider_account.dart';

/// A fake adapter that emits a canned summary string as the "reply".
class _FakeSummaryAdapter implements LlmAdapter {
  _FakeSummaryAdapter(this._reply, {this.error});

  final String _reply;
  final Object? error;

  @override
  AdapterKind get kind => AdapterKind.openaiCompatible;

  @override
  Stream<LlmEvent> stream({
    required LlmRequest request,
    required ProviderAccount account,
    required String? secret,
  }) async* {
    if (error != null) {
      yield ErrorEvent(UnknownError(error.toString()));
      return;
    }
    yield TokenEvent(_reply);
    yield const DoneEvent();
  }

  @override
  Future<List<LlmModel>> listModels({
    required ProviderAccount account,
    required String? secret,
  }) async => const <LlmModel>[];
}

ProviderAccount _account() => ProviderAccount(
  id: 'test',
  kind: AdapterKind.openaiCompatible,
  displayName: 'Test',
  config: const <String, Object?>{'model': 'test-model'},
);

ChatMessage _user(String text) => ChatMessage(
  id: 'u-${text.hashCode}',
  role: MessageRole.user,
  text: text,
  createdAt: DateTime.now(),
);

ChatMessage _assistant(String text) => ChatMessage(
  id: 'a-${text.hashCode}',
  role: MessageRole.assistant,
  text: text,
  createdAt: DateTime.now(),
);

void main() {
  group('secret_redaction', () {
    test('redacts GitHub PATs', () {
      const text = 'my token is ghp_1234567890abcdefghijklmnopqrstuvwxyz1234';
      final result = redactSecrets(text);
      expect(result, contains('[REDACTED:github_token]'));
      expect(result, isNot(contains('ghp_')));
    });

    test('redacts OpenAI keys', () {
      const text = 'key = sk-proj-abcdef1234567890XYZ';
      final result = redactSecrets(text);
      expect(result, contains('[REDACTED:openai_key]'));
      expect(result, isNot(contains('sk-proj-')));
    });

    test('redacts Bearer tokens', () {
      const text = 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz1234';
      final result = redactSecrets(text);
      expect(result, contains('[REDACTED:bearer_token]'));
    });

    test('redacts api_key assignments', () {
      const text = 'api_key = "mysecret1234567890"';
      final result = redactSecrets(text);
      expect(result, contains('[REDACTED:api_key]'));
    });

    test('redacts PEM private key blocks', () {
      const text = '''-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA1234567890abcdefghijklmnopqrstuvwxyz
-----END RSA PRIVATE KEY-----''';
      final result = redactSecrets(text);
      expect(result, contains('[REDACTED:private_key_block]'));
      expect(result, isNot(contains('MIIEpAIBAA')));
    });

    test('does not redact non-secret text', () {
      const text = 'The quick brown fox jumps over the lazy dog.';
      expect(redactSecrets(text), equals(text));
    });

    test('returns text unchanged when disabled', () {
      const text = 'api_key = "mysecret1234567890"';
      expect(redactSecrets(text, enabled: false), equals(text));
    });

    test('returns empty text unchanged', () {
      expect(redactSecrets(''), equals(''));
    });
  });

  group('LlmContextCompactor', () {
    test('produces a summary message with isCompactionSummary flag', () async {
      final adapter = _FakeSummaryAdapter('## Active Task\nNone');
      final compactor = LlmContextCompactor(
        adapter: adapter,
        account: _account(),
        secret: 'test-key',
        model: 'test-model',
      );

      final oldMessages = <ChatMessage>[
        _user('What is 2+2?'),
        _assistant('4'),
        _user('Thanks!'),
        _assistant('You are welcome.'),
      ];
      final recentTail = <ChatMessage>[_user('New question')];

      final result = await compactor.compact(oldMessages, recentTail);

      // Result: [summaryMessage, ...recentTail]
      expect(result.length, equals(2));
      expect(result.first.isCompactionSummary, isTrue);
      expect(result.last, equals(recentTail.last));
    });

    test('summary message has the handoff prefix', () async {
      final adapter = _FakeSummaryAdapter('## Active Task\nNone');
      final compactor = LlmContextCompactor(
        adapter: adapter,
        account: _account(),
        secret: 'test-key',
        model: 'test-model',
      );

      final result = await compactor.compact(
        <ChatMessage>[_user('Hello'), _assistant('Hi there')],
        <ChatMessage>[_user('New')],
      );

      expect(
        result.first.text,
        startsWith('[CONTEXT COMPACTION — REFERENCE ONLY]'),
      );
    });

    test('returns recentTail unchanged when oldMessages is empty', () async {
      final adapter = _FakeSummaryAdapter('should not be called');
      final compactor = LlmContextCompactor(
        adapter: adapter,
        account: _account(),
        secret: 'test-key',
        model: 'test-model',
      );

      final recentTail = <ChatMessage>[_user('Hi')];
      final result = await compactor.compact(<ChatMessage>[], recentTail);

      expect(result, equals(recentTail));
    });

    test(
      'iteratively updates prior summary instead of re-summarizing',
      () async {
        // First compaction — produces a summary.
        final adapter = _FakeSummaryAdapter('## Active Task\nFirst summary');

        // Wrap the adapter to count calls.
        final countingAdapter = _CountingAdapter(adapter);
        final compactor2 = LlmContextCompactor(
          adapter: countingAdapter,
          account: _account(),
          secret: 'test-key',
          model: 'test-model',
        );

        final oldMessages = <ChatMessage>[
          _user('Question 1'),
          _assistant('Answer 1'),
        ];
        final recentTail = <ChatMessage>[_user('Question 2')];

        final firstResult = await compactor2.compact(oldMessages, recentTail);
        expect(countingAdapter.callCount, equals(1));
        expect(firstResult.first.isCompactionSummary, isTrue);

        // Second compaction — the prior summary is in oldMessages.
        // The compactor should find it and pass it as previousSummary.
        final newOldMessages = <ChatMessage>[
          ...firstResult, // includes the summary + recent tail
          _assistant('Answer 2'),
        ];
        final newRecentTail = <ChatMessage>[_user('Question 3')];

        await compactor2.compact(newOldMessages, newRecentTail);
        expect(countingAdapter.callCount, equals(2));

        // Verify the second call's prompt contained "PREVIOUS SUMMARY".
        expect(countingAdapter.lastPrompt, contains('PREVIOUS SUMMARY'));
        expect(countingAdapter.lastPrompt, contains('First summary'));
      },
    );

    test(
      'redacts secrets from transcript before sending to summarizer',
      () async {
        final adapter = _FakeSummaryAdapter('## Active Task\nNone');
        final capturingAdapter = _CapturingAdapter(adapter);
        final compactor = LlmContextCompactor(
          adapter: capturingAdapter,
          account: _account(),
          secret: 'test-key',
          model: 'test-model',
          settings: const CompactionSettings(redactSecrets: true),
        );

        await compactor.compact(
          <ChatMessage>[
            _user('My key is ghp_1234567890abcdefghijklmnopqrstuvwxyz1234'),
            _assistant('Got it'),
          ],
          <ChatMessage>[_user('Next')],
        );

        // The prompt sent to the summarizer should NOT contain the raw token.
        expect(capturingAdapter.lastPrompt, isNot(contains('ghp_1234567890')));
        expect(
          capturingAdapter.lastPrompt,
          contains('[REDACTED:github_token]'),
        );
      },
    );

    test('does not redact when redactSecrets is disabled', () async {
      final adapter = _FakeSummaryAdapter('## Active Task\nNone');
      final capturingAdapter = _CapturingAdapter(adapter);
      final compactor = LlmContextCompactor(
        adapter: capturingAdapter,
        account: _account(),
        secret: 'test-key',
        model: 'test-model',
        settings: const CompactionSettings(redactSecrets: false),
      );

      await compactor.compact(
        <ChatMessage>[
          _user('My key is ghp_1234567890abcdefghijklmnopqrstuvwxyz1234'),
        ],
        <ChatMessage>[_user('Next')],
      );

      expect(capturingAdapter.lastPrompt, contains('ghp_1234567890'));
    });

    test('uses static fallback when LLM call fails', () async {
      final adapter = _FakeSummaryAdapter(
        'unused',
        error: Exception('network down'),
      );
      final compactor = LlmContextCompactor(
        adapter: adapter,
        account: _account(),
        secret: 'test-key',
        model: 'test-model',
        settings: const CompactionSettings(staticFallback: true),
      );

      final result = await compactor.compact(
        <ChatMessage>[
          _user('Fix the bug in src/main.dart'),
          _assistant('I will help with that.'),
        ],
        <ChatMessage>[_user('Continue')],
      );

      // Should still produce a summary message (the fallback).
      expect(result.first.isCompactionSummary, isTrue);
      expect(result.first.text, contains('Fallback summary'));
    });

    test(
      'returns full history when LLM fails and staticFallback is disabled',
      () async {
        final adapter = _FakeSummaryAdapter(
          'unused',
          error: Exception('network down'),
        );
        final compactor = LlmContextCompactor(
          adapter: adapter,
          account: _account(),
          secret: 'test-key',
          model: 'test-model',
          settings: const CompactionSettings(staticFallback: false),
        );

        final oldMessages = <ChatMessage>[_user('Hello'), _assistant('Hi')];
        final recentTail = <ChatMessage>[_user('World')];

        final result = await compactor.compact(oldMessages, recentTail);

        // No summary — returns old + recent unchanged.
        expect(result.length, equals(3));
        expect(result.where((m) => m.isCompactionSummary), isEmpty);
      },
    );

    test(
      'aborts and returns full history when abortOnSummaryFailure is true',
      () async {
        final adapter = _FakeSummaryAdapter(
          'unused',
          error: Exception('network down'),
        );
        final compactor = LlmContextCompactor(
          adapter: adapter,
          account: _account(),
          secret: 'test-key',
          model: 'test-model',
          settings: const CompactionSettings(
            abortOnSummaryFailure: true,
            staticFallback: true, // should be ignored when abort is on
          ),
        );

        final oldMessages = <ChatMessage>[_user('Hello'), _assistant('Hi')];
        final recentTail = <ChatMessage>[_user('World')];

        final result = await compactor.compact(oldMessages, recentTail);

        expect(result.length, equals(3));
        expect(result.where((m) => m.isCompactionSummary), isEmpty);
      },
    );

    test(
      'includes focus topic in prompt when autoFocusTopic is enabled',
      () async {
        final adapter = _FakeSummaryAdapter('## Active Task\nNone');
        final capturingAdapter = _CapturingAdapter(adapter);
        final compactor = LlmContextCompactor(
          adapter: capturingAdapter,
          account: _account(),
          secret: 'test-key',
          model: 'test-model',
          settings: const CompactionSettings(autoFocusTopic: true),
        );

        await compactor.compact(
          <ChatMessage>[
            _user('How do I fix the login bug?'),
            _assistant('Try X'),
          ],
          <ChatMessage>[_user('That did not work, the login bug persists')],
        );

        expect(capturingAdapter.lastPrompt, contains('Focus topic'));
      },
    );

    test('includes temporal anchoring instruction when enabled', () async {
      final adapter = _FakeSummaryAdapter('## Active Task\nNone');
      final capturingAdapter = _CapturingAdapter(adapter);
      final compactor = LlmContextCompactor(
        adapter: capturingAdapter,
        account: _account(),
        secret: 'test-key',
        model: 'test-model',
        settings: const CompactionSettings(temporalAnchoring: true),
      );

      await compactor.compact(
        <ChatMessage>[_user('Hi'), _assistant('Hello')],
        <ChatMessage>[_user('Bye')],
      );

      expect(capturingAdapter.lastPrompt, contains('Temporal anchoring'));
    });

    test('structured template sections are present in the prompt', () async {
      final adapter = _FakeSummaryAdapter('## Active Task\nNone');
      final capturingAdapter = _CapturingAdapter(adapter);
      final compactor = LlmContextCompactor(
        adapter: capturingAdapter,
        account: _account(),
        secret: 'test-key',
        model: 'test-model',
      );

      await compactor.compact(
        <ChatMessage>[_user('Hi'), _assistant('Hello')],
        <ChatMessage>[_user('Bye')],
      );

      final prompt = capturingAdapter.lastPrompt;
      for (final section in <String>[
        '## Active Task',
        '## Completed Actions',
        '## In Progress',
        '## Blocked',
        '## Key Decisions',
        '## Resolved Questions',
        '## Pending User Asks',
        '## Relevant Files',
        '## Critical Context',
      ]) {
        expect(prompt, contains(section), reason: 'missing section: $section');
      }
    });

    test('static fallback extracts file paths and tool names', () async {
      final adapter = _FakeSummaryAdapter('unused', error: Exception('failed'));
      final compactor = LlmContextCompactor(
        adapter: adapter,
        account: _account(),
        secret: 'test-key',
        model: 'test-model',
        settings: const CompactionSettings(staticFallback: true),
      );

      final result = await compactor.compact(
        <ChatMessage>[
          _user('Fix the bug in src/main.dart and lib/utils.dart'),
          _assistant('I will check those files.'),
        ],
        <ChatMessage>[_user('Continue')],
      );

      final fallbackText = result.first.text;
      expect(fallbackText, contains('src/main.dart'));
      expect(fallbackText, contains('lib/utils.dart'));
    });
  });

  group('CompactionSettings', () {
    test('defaults are sensible', () {
      const s = CompactionSettings();
      expect(s.redactSecrets, isTrue);
      expect(s.temporalAnchoring, isTrue);
      expect(s.antiThrash, isTrue);
      expect(s.staticFallback, isTrue);
      expect(s.abortOnSummaryFailure, isFalse);
      expect(s.autoFocusTopic, isFalse);
    });
  });

  group('token estimation', () {
    test('estimateTokens uses char/4 heuristic', () {
      expect(estimateTokens(''), equals(0));
      expect(estimateTokens('abcd'), equals(1));
      expect(estimateTokens('abcde'), equals(2));
    });

    test('estimateMessageTokens includes role overhead', () {
      final m = ChatMessage(
        id: 'x',
        role: MessageRole.user,
        text: 'abcd',
        createdAt: DateTime.now(),
      );
      expect(estimateMessageTokens(m), equals(5)); // 4 + 1
    });
  });
}

/// Adapter wrapper that counts stream() calls and captures the last prompt.
class _CapturingAdapter implements LlmAdapter {
  _CapturingAdapter(this._inner);

  final LlmAdapter _inner;
  String? lastPrompt;

  @override
  AdapterKind get kind => _inner.kind;

  @override
  Stream<LlmEvent> stream({
    required LlmRequest request,
    required ProviderAccount account,
    required String? secret,
  }) {
    lastPrompt = request.messages.first.text;
    return _inner.stream(request: request, account: account, secret: secret);
  }

  @override
  Future<List<LlmModel>> listModels({
    required ProviderAccount account,
    required String? secret,
  }) => _inner.listModels(account: account, secret: secret);
}

/// Adapter wrapper that counts stream() calls.
class _CountingAdapter implements LlmAdapter {
  _CountingAdapter(this._inner);

  final LlmAdapter _inner;
  int callCount = 0;
  String? lastPrompt;

  @override
  AdapterKind get kind => _inner.kind;

  @override
  Stream<LlmEvent> stream({
    required LlmRequest request,
    required ProviderAccount account,
    required String? secret,
  }) {
    callCount++;
    lastPrompt = request.messages.first.text;
    return _inner.stream(request: request, account: account, secret: secret);
  }

  @override
  Future<List<LlmModel>> listModels({
    required ProviderAccount account,
    required String? secret,
  }) => _inner.listModels(account: account, secret: secret);
}
