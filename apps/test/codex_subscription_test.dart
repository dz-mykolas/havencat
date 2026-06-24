import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:http_mock_adapter/src/handlers/request_handler.dart';

import 'package:app/data/services/llm/subscription/chatgpt_subscription_adapter.dart';
import 'package:app/data/services/llm/subscription/codex_protocol.dart';
import 'package:app/domain/models/adapter_kind.dart';
import 'package:app/domain/models/llm_model.dart';
import 'package:app/domain/models/message.dart';
import 'package:app/domain/models/provider_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CodexProtocol', () {
    test('buildBody is a plain Responses request: no persona, no tools', () {
      final Map<String, Object?> body = CodexProtocol.buildBody(
        model: 'gpt-5.5',
        messages: <ChatMessage>[
          ChatMessage(id: '1', role: MessageRole.user, text: 'hello'),
          ChatMessage(id: '2', role: MessageRole.assistant, text: 'hi'),
          ChatMessage(id: '3', role: MessageRole.user, text: '   '),
        ],
      );

      expect(body['model'], 'gpt-5.5');
      // Empty instructions by default → no imposed persona.
      expect(body['instructions'], '');
      expect(body['store'], false);
      expect(body['stream'], true);
      // The Codex endpoint rejects these; we must not send them.
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('max_output_tokens'), isFalse);
      expect(body.containsKey('tools'), isFalse);

      final List<dynamic> input = body['input'] as List<dynamic>;
      // Blank messages are dropped; only the two real turns remain.
      expect(input.length, 2);
      final Map<String, Object?> first = input.first as Map<String, Object?>;
      expect(first['role'], 'user');
      final Map<String, Object?> firstContent =
          (first['content'] as List<dynamic>).first as Map<String, Object?>;
      expect(firstContent['type'], 'input_text');
      final Map<String, Object?> second = input[1] as Map<String, Object?>;
      expect(second['role'], 'assistant');
      final Map<String, Object?> secondContent =
          (second['content'] as List<dynamic>).first as Map<String, Object?>;
      expect(secondContent['type'], 'output_text');
    });

    test('buildBody honors a caller-supplied system prompt', () {
      final Map<String, Object?> body = CodexProtocol.buildBody(
        model: 'gpt-5.5',
        instructions: 'You are a pirate.',
        messages: <ChatMessage>[
          ChatMessage(id: '1', role: MessageRole.user, text: 'hi'),
        ],
      );
      expect(body['instructions'], 'You are a pirate.');
    });

    test('accountIdFromJwt decodes the chatgpt_account_id claim', () {
      String seg(Map<String, Object?> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      final String jwt =
          '${seg(<String, Object?>{'alg': 'none'})}.'
          '${seg(<String, Object?>{
            'https://api.openai.com/auth': <String, Object?>{'chatgpt_account_id': 'acct-123'},
          })}.'
          'sig';

      expect(CodexProtocol.accountIdFromJwt(jwt), 'acct-123');
      expect(CodexProtocol.accountIdFromJwt('not-a-jwt'), isNull);
    });
  });

  group('ChatGptSubscriptionAdapter.listModels', () {
    final ProviderAccount account = ProviderAccount(
      id: 'a',
      kind: AdapterKind.subscription,
      displayName: 'ChatGPT',
      config: const <String, Object?>{},
    );
    // The npm registry lookup isn't mocked here, so the version resolver falls
    // back to the default client version — the URL the adapter ends up hitting.
    final String modelsUrl =
        'https://chatgpt.com/backend-api'
        '${CodexProtocol.modelsPath(CodexProtocol.defaultClientVersion)}';

    test('returns all models, flagging hidden internal ones', () async {
      final Dio dio = Dio();
      final DioAdapter mock = DioAdapter(dio: dio);
      mock.onGet(modelsUrl, (MockServer server) {
        server.reply(200, <String, dynamic>{
          'models': <Map<String, dynamic>>[
            <String, dynamic>{'slug': 'gpt-5.5'},
            <String, dynamic>{'slug': 'gpt-5.2-codex'},
            // Internal reviewer model the Codex app hides.
            <String, dynamic>{
              'slug': 'codex-auto-review',
              'display_name': 'Codex Auto Review',
              'visibility': 'hide',
            },
          ],
        });
      });

      final ChatGptSubscriptionAdapter adapter = ChatGptSubscriptionAdapter(
        dio: dio,
      );
      final List<LlmModel> models = await adapter.listModels(
        account: account,
        secret: 'token',
      );

      expect(models.map((LlmModel m) => m.id), <String>[
        'gpt-5.5',
        'gpt-5.2-codex',
        'codex-auto-review',
      ]);
      expect(
        models.where((LlmModel m) => m.hidden).map((LlmModel m) => m.id),
        <String>['codex-auto-review'],
      );
    });

    test('propagates upstream failures so the UI can retry', () async {
      final Dio dio = Dio();
      final DioAdapter mock = DioAdapter(dio: dio);
      mock.onGet(modelsUrl, (MockServer server) {
        server.reply(500, <String, dynamic>{'detail': 'boom'});
      });

      final ChatGptSubscriptionAdapter adapter = ChatGptSubscriptionAdapter(
        dio: dio,
      );

      expect(
        () => adapter.listModels(account: account, secret: 'token'),
        throwsA(isA<DioException>()),
      );
    });
  });
}
