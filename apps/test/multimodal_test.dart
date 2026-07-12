import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:http_mock_adapter/src/handlers/request_handler.dart';

import 'package:app/data/services/llm/llm_event.dart';
import 'package:app/data/services/llm/model_context_resolver.dart';
import 'package:app/data/services/llm/openai_compatible/openai_compatible_adapter.dart';
import 'package:app/data/services/llm/sse/sse_client.dart';
import 'package:app/data/services/llm/subscription/codex_protocol.dart';
import 'package:app/domain/models/adapter_kind.dart';
import 'package:app/domain/models/content_modality.dart';
import 'package:app/domain/models/llm_model.dart';
import 'package:app/domain/models/message.dart';
import 'package:app/domain/models/message_attachment.dart';
import 'package:app/domain/models/model_pricing.dart';
import 'package:app/domain/models/provider_account.dart';

void main() {
  final MessageAttachment image = MessageAttachment.inline(
    id: 'image-1',
    modality: ContentModality.image,
    mimeType: 'image/png',
    bytes: Uint8List.fromList(<int>[1, 2, 3]),
    name: 'sample.png',
  );

  test('message attachments survive conversation JSON', () {
    final ChatMessage message = ChatMessage(
      id: 'message-1',
      role: MessageRole.user,
      text: 'What is this?',
      attachments: <MessageAttachment>[image],
    );

    final ChatMessage decoded = ChatMessage.fromJson(message.toJson());

    expect(decoded.text, 'What is this?');
    expect(decoded.attachments.single.id, 'image-1');
    expect(decoded.attachments.single.mimeType, 'image/png');
    expect(decoded.attachments.single.inlineBytes, <int>[1, 2, 3]);
  });

  test('models.dev enrichment retains modalities and feature flags', () {
    final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
      <String, Object?>{
        'models': <String, Object?>{
          'openai/vision-model': <String, Object?>{
            'id': 'openai/vision-model',
            'name': 'Vision Model',
            'attachment': true,
            'reasoning': true,
            'tool_call': true,
            'modalities': <String, Object?>{
              'input': <String>['text', 'image'],
              'output': <String>['text', 'image'],
            },
            'limit': <String, Object?>{'context': 123000},
          },
        },
        'providers': <String, Object?>{
          'openai': <String, Object?>{
            'id': 'openai',
            'name': 'OpenAI',
            'models': <String, Object?>{
              'vision-model': <String, Object?>{
                'id': 'vision-model',
                'name': 'Vision Model',
                'attachment': true,
                'reasoning': true,
                'tool_call': true,
                'modalities': <String, Object?>{
                  'input': <String>['text', 'image'],
                  'output': <String>['text', 'image'],
                },
                'limit': <String, Object?>{'context': 123000},
              },
            },
          },
        },
      },
      fetchedAt: DateTime.utc(2026),
    );

    final LlmModel enriched = ModelContextResolver(catalog).enrich(
      const <LlmModel>[LlmModel(id: 'vision-model')],
      providerId: 'openai',
    ).single;

    expect(enriched.contextWindow, 123000);
    expect(enriched.capabilities!.accepts(ContentModality.image), isTrue);
    expect(enriched.capabilities!.produces(ContentModality.image), isTrue);
    expect(enriched.capabilities!.reasoning, isTrue);
    expect(enriched.capabilities!.toolCalling, isTrue);
  });

  test('Codex Responses protocol emits input_image content parts', () {
    final Map<String, Object?> body = CodexProtocol.buildBody(
      model: 'gpt-5',
      messages: <ChatMessage>[
        ChatMessage(
          id: 'message-1',
          role: MessageRole.user,
          text: 'Describe this',
          attachments: <MessageAttachment>[image],
        ),
      ],
    );

    final Map<String, Object?> item =
        (body['input'] as List<dynamic>).single as Map<String, Object?>;
    final List<dynamic> content = item['content'] as List<dynamic>;
    expect(content.map((dynamic part) => part['type']), <String>[
      'input_text',
      'input_image',
    ]);
    expect(content.last['image_url'], 'data:image/png;base64,AQID');
  });

  test('OpenAI-compatible chat requests serialize image_url parts', () async {
    final _CapturingSseClient sse = _CapturingSseClient();
    final OpenAiCompatibleAdapter adapter = OpenAiCompatibleAdapter(
      sseClient: sse,
    );
    final ProviderAccount account = ProviderAccount(
      id: 'account',
      kind: AdapterKind.openaiCompatible,
      displayName: 'Test',
      config: <String, Object?>{
        'baseUrl': 'https://example.com/v1',
        'model': 'vision-model',
      },
    );

    await adapter
        .stream(
          request: LlmRequest(
            model: 'vision-model',
            messages: <ChatMessage>[
              ChatMessage(
                id: 'message-1',
                role: MessageRole.user,
                text: 'Describe this',
                attachments: <MessageAttachment>[image],
              ),
            ],
          ),
          account: account,
          secret: 'secret',
        )
        .toList();

    final Map<String, dynamic> body =
        jsonDecode(sse.body!) as Map<String, dynamic>;
    final Map<String, dynamic> message =
        (body['messages'] as List<dynamic>).single as Map<String, dynamic>;
    final List<dynamic> content = message['content'] as List<dynamic>;
    expect(content.first['type'], 'text');
    expect(content.last['type'], 'image_url');
    expect(content.last['image_url']['url'], 'data:image/png;base64,AQID');
  });

  test('OpenAI image models use the image API and emit attachments', () async {
    final Dio dio = Dio();
    final DioAdapter mock = DioAdapter(dio: dio);
    mock.onPost(
      'https://api.openai.com/v1/images/generations',
      (MockServer server) => server.reply(200, <String, Object?>{
        'data': <Map<String, Object?>>[
          <String, Object?>{'b64_json': 'AQID'},
        ],
        'usage': <String, Object?>{
          'prompt_tokens': 2,
          'completion_tokens': 3,
          'total_tokens': 5,
        },
      }),
      data: Matchers.any,
    );
    final OpenAiCompatibleAdapter adapter = OpenAiCompatibleAdapter(dio: dio);
    final ProviderAccount account = ProviderAccount(
      id: 'account',
      kind: AdapterKind.openaiCompatible,
      displayName: 'OpenAI',
      config: <String, Object?>{
        'baseUrl': 'https://api.openai.com/v1',
        'model': 'image-model',
      },
    );

    final List<LlmEvent> events = await adapter
        .stream(
          request: LlmRequest(
            model: 'image-model',
            modelCapabilities: const ModelCapabilities(
              input: <ContentModality>{ContentModality.text},
              output: <ContentModality>{ContentModality.image},
            ),
            messages: <ChatMessage>[
              ChatMessage(
                id: 'message-1',
                role: MessageRole.user,
                text: 'Draw a cat',
              ),
            ],
          ),
          account: account,
          secret: 'secret',
        )
        .toList();

    final AttachmentEvent output = events.whereType<AttachmentEvent>().single;
    expect(output.attachment.inlineBytes, <int>[1, 2, 3]);
    expect(events.whereType<DoneEvent>().single.usage!.totalTokens, 5);
  });
}

class _CapturingSseClient extends SseClient {
  _CapturingSseClient() : super(Dio());

  String? body;

  @override
  Stream<SseEvent> stream({
    required String url,
    required String method,
    Map<String, dynamic>? headers,
    Object? body,
    CancelToken? cancelToken,
  }) async* {
    this.body = body as String?;
    yield const SseEvent('[DONE]');
  }
}
