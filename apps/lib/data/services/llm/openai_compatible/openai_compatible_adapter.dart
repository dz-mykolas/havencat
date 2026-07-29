import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../../../domain/models/adapter_kind.dart';
import '../../../../domain/models/content_modality.dart';
import '../../../../domain/models/llm_model.dart';
import '../../../../domain/models/message.dart';
import '../../../../domain/models/message_attachment.dart';
import '../../../../domain/models/provider_account.dart';
import '../../errors/provider_failure_mapper.dart';
import '../llm_adapter.dart';
import '../llm_endpoint.dart';
import '../llm_event.dart';
import '../sse/sse_client.dart';

/// One generic adapter covering every OpenAI-compatible `/v1/chat/completions`
/// endpoint: OpenAI API, Qwen DashScope, OpenRouter, Groq, Together, DeepSeek,
/// Ollama, LM Studio, vLLM, llama.cpp server, and any custom endpoint speaking
/// the same shape.
///
/// Config (from [ProviderAccount.config]):
///   - `baseUrl`  (default https://api.openai.com/v1)
///   - `model`    (e.g. 'gpt-4o-mini', 'qwen-max', 'llama3.1')
///   - `headers`  (optional extra headers, e.g. custom auth proxies)
///
/// The API key comes in via [secret] (resolved from secure storage by the
/// repository), never from [config].
class OpenAiCompatibleAdapter implements LlmAdapter {
  OpenAiCompatibleAdapter({
    Dio? dio,
    SseClient? sseClient,
    LlmEndpoint? endpoint,
  }) : this._(dio ?? Dio(), sseClient, endpoint);

  OpenAiCompatibleAdapter._(
    this._dio,
    SseClient? sseClient,
    LlmEndpoint? endpoint,
  ) : _sse = sseClient ?? SseClient(_dio),
      _endpoint = endpoint ?? LlmEndpoint.fromPlatform();

  static final Logger _log = Logger('llm.openai_compat');

  final Dio _dio;
  final SseClient _sse;
  final LlmEndpoint _endpoint;
  static const ProviderFailureMapper _failureMapper = ProviderFailureMapper();

  @override
  AdapterKind get kind => AdapterKind.openaiCompatible;

  @override
  Stream<LlmEvent> stream({
    required LlmRequest request,
    required ProviderAccount account,
    required String? secret,
  }) async* {
    final String baseUrl = _readBaseUrl(account);
    final String model = _readModel(account, request);
    final Map<String, String> headers = _readHeaders(account, secret);
    final CancelToken cancelToken = CancelToken();
    final FailureSource failureSource = FailureSource(
      subsystem: AppSubsystem.llm,
      operation: 'generate',
      providerId: account.displayName,
      accountId: account.id,
      modelId: model,
    );

    _log.info(
      'stream: model=$model baseUrl=$baseUrl '
      'messages=${request.messages.length} tools=${request.tools.length}',
    );

    // Wire the request's cancellation signal (if any) to dio's CancelToken.
    final Future<void> Function()? signal = request.signal;
    StreamSubscription<void>? signalSub;
    if (signal != null) {
      signalSub = signal().asStream().listen((_) {
        if (!cancelToken.isCancelled) cancelToken.cancel();
      });
    }

    try {
      if (_usesDedicatedImageApi(baseUrl, request)) {
        yield* _generateImages(
          request: request,
          baseUrl: baseUrl,
          headers: headers,
          cancelToken: cancelToken,
        );
        return;
      }
      final ResolvedRequest resolved = _endpoint.resolve(
        '$baseUrl/chat/completions',
        headers,
      );
      final Stream<SseEvent> events = _sse.stream(
        url: resolved.url,
        method: 'POST',
        headers: resolved.headers,
        body: jsonEncode(_buildBody(request, model)),
        cancelToken: cancelToken,
      );

      // Buffer finish_reason and usage so we can emit a single DoneEvent
      // carrying both. OpenAI sends finish_reason on the last content chunk
      // and usage in a separate empty-choices chunk (when include_usage is
      // set); some providers send them together. Either way, we hold off on
      // emitting DoneEvent until the stream ends so the repository's
      // done-completer fires once with the real usage.
      String? finishReason;
      LlmUsage? usage;
      await for (final SseEvent event in events) {
        if (event.data == '[DONE]') {
          _log.fine('stream: [DONE] received');
          break;
        }
        final LlmEvent? parsed = _parseChunk(event.data, failureSource);
        if (parsed == null) continue;
        if (parsed is DoneEvent) {
          finishReason ??= parsed.finishReason;
          usage ??= parsed.usage;
        } else {
          yield parsed;
        }
      }
      yield DoneEvent(finishReason: finishReason ?? 'stop', usage: usage);
    } on DioException catch (e) {
      _log.warning(
        'stream: DioException ${e.type.name} status=${e.response?.statusCode}',
      );
      yield ErrorEvent(
        _failureMapper.fromDio(
          e,
          source: failureSource,
          flavor: ProviderErrorFlavor.openAi,
        ),
      );
    } catch (e, stack) {
      _log.severe('stream: unexpected error', e, stack);
      yield ErrorEvent(UnknownError(e.toString(), source: failureSource));
    } finally {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('LLM stream consumer stopped.');
      }
      await signalSub?.cancel();
    }
  }

  bool _usesDedicatedImageApi(String baseUrl, LlmRequest request) {
    if (request.modelCapabilities?.produces(ContentModality.image) != true) {
      return false;
    }
    final String host = Uri.tryParse(baseUrl)?.host ?? '';
    return host == 'api.openai.com' || host == 'openrouter.ai';
  }

  Stream<LlmEvent> _generateImages({
    required LlmRequest request,
    required String baseUrl,
    required Map<String, String> headers,
    required CancelToken cancelToken,
  }) async* {
    final String host = Uri.tryParse(baseUrl)?.host ?? '';
    final bool openRouter = host == 'openrouter.ai';
    final ChatMessage? latestUser = request.messages
        .where((ChatMessage message) => message.isUser)
        .lastOrNull;
    final String prompt = latestUser?.text.trim().isNotEmpty == true
        ? latestUser!.text.trim()
        : 'Create an image based on the provided reference.';
    final List<MessageAttachment> references = request.messages
        .where((ChatMessage message) => message.isUser)
        .expand((ChatMessage message) => message.attachments)
        .where(
          (MessageAttachment attachment) =>
              attachment.modality == ContentModality.image &&
              attachment.dataUrl != null,
        )
        .toList(growable: false);
    final bool openAiEdit = !openRouter && references.isNotEmpty;
    final String path = openRouter
        ? '/images'
        : openAiEdit
        ? '/images/edits'
        : '/images/generations';
    final Map<String, String> requestHeaders = Map<String, String>.from(
      headers,
    );
    if (openAiEdit) {
      requestHeaders.removeWhere(
        (String key, _) => key.toLowerCase() == 'content-type',
      );
    }
    final ResolvedRequest resolved = _endpoint.resolve(
      '$baseUrl$path',
      requestHeaders,
    );

    final Object data;
    if (openAiEdit) {
      data = FormData.fromMap(<String, Object?>{
        'model': request.model,
        'prompt': prompt,
        'image[]': <MultipartFile>[
          for (int i = 0; i < references.length; i++)
            MultipartFile.fromBytes(
              references[i].inlineBytes!,
              filename: references[i].name ?? 'reference-$i.png',
              contentType: DioMediaType.parse(references[i].mimeType),
            ),
        ],
      });
    } else {
      data = <String, Object?>{
        'model': request.model,
        'prompt': prompt,
        if (openRouter && references.isNotEmpty)
          'input_references': <Map<String, Object?>>[
            for (final MessageAttachment attachment in references)
              <String, Object?>{
                'type': 'image_url',
                'image_url': <String, Object?>{'url': attachment.dataUrl},
              },
          ],
      };
    }

    final Response<dynamic> response = await _dio.post<dynamic>(
      resolved.url,
      options: Options(headers: resolved.headers),
      cancelToken: cancelToken,
      data: data,
    );
    final Object? body = response.data;
    final Object? rawImages = body is Map ? body['data'] : null;
    bool emittedImage = false;
    if (rawImages is List) {
      for (int index = 0; index < rawImages.length; index++) {
        final Object? raw = rawImages[index];
        if (raw is! Map) continue;
        final String? base64 = raw['b64_json'] as String?;
        final String? url = raw['url'] as String?;
        if (base64 != null && base64.isNotEmpty) {
          emittedImage = true;
          yield AttachmentEvent(
            MessageAttachment(
              id: 'generated-image-$index',
              modality: ContentModality.image,
              mimeType: (raw['media_type'] as String?) ?? 'image/png',
              source: AttachmentSource.inlineBase64,
              data: base64,
              generated: true,
            ),
          );
        } else if (url != null && url.isNotEmpty) {
          emittedImage = true;
          yield AttachmentEvent(
            MessageAttachment.fromUrl(
              id: 'generated-image-$index',
              modality: ContentModality.image,
              url: url,
              mimeType: (raw['media_type'] as String?) ?? 'image/png',
              generated: true,
            ),
          );
        }
      }
    }
    if (!emittedImage) {
      yield const ErrorEvent(
        InvalidRequestError('The image provider returned no image.'),
      );
      return;
    }
    final Map<String, dynamic>? usage = body is Map<String, dynamic>
        ? body['usage'] as Map<String, dynamic>?
        : null;
    yield DoneEvent(
      finishReason: 'stop',
      usage: usage == null
          ? null
          : LlmUsage(
              promptTokens: (usage['prompt_tokens'] as num?)?.toInt(),
              completionTokens: (usage['completion_tokens'] as num?)?.toInt(),
              totalTokens: (usage['total_tokens'] as num?)?.toInt(),
            ),
    );
  }

  @override
  Future<List<LlmModel>> listModels({
    required ProviderAccount account,
    required String? secret,
  }) async {
    final FailureSource failureSource = FailureSource(
      subsystem: AppSubsystem.modelCatalog,
      operation: 'list_models',
      providerId: account.displayName,
      accountId: account.id,
    );
    try {
      final String baseUrl = _readBaseUrl(account);
      final Map<String, String> headers = _readHeaders(account, secret);
      final ResolvedRequest resolved = _endpoint.resolve(
        '$baseUrl/models',
        headers,
      );

      final Response<dynamic> response = await _dio.get<dynamic>(
        resolved.url,
        options: Options(headers: resolved.headers),
      );

      // OpenAI shape: { "object": "list", "data": [ { "id": "gpt-4o" }, ... ] }.
      final Object? body = response.data;
      final List<dynamic>? data = body is Map<String, dynamic>
          ? body['data'] as List<dynamic>?
          : (body is List ? body : null);
      if (data == null) return const <LlmModel>[];

      final List<LlmModel> models = <LlmModel>[];
      for (final dynamic entry in data) {
        if (entry is Map<String, dynamic>) {
          final String? id = entry['id'] as String?;
          if (id != null && id.isNotEmpty) models.add(LlmModel(id: id));
        } else if (entry is String && entry.isNotEmpty) {
          models.add(LlmModel(id: entry));
        }
      }
      return models;
    } on Object catch (error) {
      throw _failureMapper.fromException(
        error,
        source: failureSource,
        flavor: ProviderErrorFlavor.openAi,
        fallbackMessage: 'Models could not be loaded from this provider.',
      );
    }
  }

  String _readBaseUrl(ProviderAccount account) {
    final Object? configured = account.config['baseUrl'];
    if (configured is! String || configured.trim().isEmpty) {
      throw StateError(
        'No base URL is configured for provider account '
        '"${account.displayName}".',
      );
    }
    final String baseUrl = configured.trim();
    // Strip a trailing slash so we always join with '/chat/completions'.
    return baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
  }

  String _readModel(ProviderAccount account, LlmRequest request) {
    if (request.model.isNotEmpty) return request.model;
    final Object? configured = account.config['model'];
    if (configured is String && configured.isNotEmpty) return configured;
    throw StateError(
      'No model is selected for provider account "${account.displayName}".',
    );
  }

  Map<String, String> _readHeaders(ProviderAccount account, String? secret) {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final Map<String, Object?>? extra =
        account.config['headers'] as Map<String, Object?>?;
    if (extra != null) {
      extra.forEach((String k, Object? v) {
        if (v != null) headers[k] = v.toString();
      });
    }
    if (secret != null && secret.isNotEmpty) {
      headers['Authorization'] = 'Bearer $secret';
    }
    return headers;
  }

  Map<String, Object?> _buildBody(LlmRequest request, String model) {
    final List<Map<String, Object?>> messages = request.messages
        .where(
          (m) =>
              m.text.trim().isNotEmpty ||
              m.toolCalls.isNotEmpty ||
              m.attachments.isNotEmpty,
        )
        .map(_messageToJson)
        .toList();
    if (request.systemPrompt != null && request.systemPrompt!.isNotEmpty) {
      messages.insert(0, <String, Object?>{
        'role': 'system',
        'content': request.systemPrompt,
      });
    }
    return <String, Object?>{
      'model': model,
      'stream': true,
      'stream_options': <String, Object?>{'include_usage': true},
      'messages': messages,
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxTokens != null) 'max_tokens': request.maxTokens,
      if (request.tools.isNotEmpty)
        'tools': request.tools
            .map(
              (t) => <String, Object?>{
                'type': 'function',
                'function': <String, Object?>{
                  'name': t.name,
                  'description': t.description,
                  'parameters': t.parameters,
                },
              },
            )
            .toList(),
    };
  }

  /// Serialize a [ChatMessage] to the OpenAI chat-completions JSON shape.
  /// Handles plain user/assistant text, assistant messages with tool_calls,
  /// and tool-result messages.
  Map<String, Object?> _messageToJson(ChatMessage m) {
    if (m.isTool) {
      return <String, Object?>{
        'role': 'tool',
        'tool_call_id': m.toolCallId,
        'content': m.text,
      };
    }
    final Map<String, Object?> json = <String, Object?>{
      'role': m.isUser ? 'user' : 'assistant',
      'content': m.isUser && m.attachments.isNotEmpty
          ? <Map<String, Object?>>[
              if (m.text.trim().isNotEmpty)
                <String, Object?>{'type': 'text', 'text': m.text},
              for (final MessageAttachment attachment in m.attachments)
                if (attachment.modality == ContentModality.image &&
                    attachment.dataUrl != null)
                  <String, Object?>{
                    'type': 'image_url',
                    'image_url': <String, Object?>{'url': attachment.dataUrl},
                  },
            ]
          : m.text,
    };
    if (m.toolCalls.isNotEmpty) {
      json['tool_calls'] = m.toolCalls
          .map(
            (tc) => <String, Object?>{
              'id': tc.id,
              'type': 'function',
              'function': <String, Object?>{
                'name': tc.name,
                'arguments': tc.args,
              },
            },
          )
          .toList();
    }
    return json;
  }

  /// Parse one `data:` payload from the SSE stream into an [LlmEvent].
  ///
  /// Returns null for keep-alive/empty chunks. Emits [DoneEvent] when the
  /// provider signals completion via `finish_reason`. Emits [ToolCallEvent]s
  /// as tool calls accumulate in the delta — note that OpenAI streams
  /// tool_calls in fragments (id/function name first, then argument tokens),
  /// so the repository must accumulate them by index.
  LlmEvent? _parseChunk(String data, FailureSource failureSource) {
    if (data.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (e) {
      _log.warning(
        'parseChunk: JSON decode failed: $e data="${data.substring(0, data.length.clamp(0, 120))}"',
      );
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    if (decoded['error'] != null || decoded['type'] == 'error') {
      return ErrorEvent(
        _failureMapper.fromPayload(
          decoded,
          source: failureSource,
          flavor: ProviderErrorFlavor.openAi,
        ),
      );
    }

    // When stream_options.include_usage is set, OpenAI sends the usage in a
    // final chunk with an empty choices array. Emit it as a DoneEvent so the
    // repository can capture prompt_tokens. If a finish_reason was already
    // seen on a prior chunk (without usage), this supplements it.
    final List<dynamic>? choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      final LlmUsage? usage = _parseUsage(decoded);
      if (usage != null) {
        return DoneEvent(finishReason: 'stop', usage: usage);
      }
      return null;
    }

    final Map<String, dynamic> choice = choices.first as Map<String, dynamic>;
    final Map<String, dynamic>? delta =
        choice['delta'] as Map<String, dynamic>?;
    final String? finishReason = choice['finish_reason'] as String?;

    // Tool calls stream in fragments: the first chunk carries the id + name,
    // subsequent chunks carry argument tokens. We surface each fragment as a
    // ToolCallEvent with the same id so the repository can accumulate by index.
    final List<dynamic>? toolCalls = delta?['tool_calls'] as List<dynamic>?;
    if (toolCalls != null && toolCalls.isNotEmpty) {
      final Map<String, dynamic> tc = toolCalls.first as Map<String, dynamic>;
      final String? id = tc['id'] as String?;
      final Map<String, dynamic>? function =
          tc['function'] as Map<String, dynamic>?;
      final String? name = function?['name'] as String?;
      final String? argsFragment = function?['arguments'] as String?;
      if (id != null || name != null || argsFragment != null) {
        return ToolCallEvent(
          id: id ?? '',
          name: name ?? '',
          args: argsFragment ?? '',
        );
      }
    }

    final Object? content = delta?['content'];
    if (content is String && content.isNotEmpty) {
      return TokenEvent(content);
    }

    final Object? images = delta?['images'] ?? choice['images'];
    if (images is List && images.isNotEmpty) {
      final Object? first = images.first;
      if (first is Map) {
        final Object? imageUrl = first['image_url'];
        final String? url = imageUrl is Map
            ? imageUrl['url'] as String?
            : imageUrl as String?;
        if (url != null && url.isNotEmpty) {
          return AttachmentEvent(
            MessageAttachment.fromUrl(
              id: 'generated-image-${url.hashCode}',
              modality: ContentModality.image,
              url: url,
              mimeType: 'image/png',
              generated: true,
            ),
          );
        }
      }
    }

    // Some providers stream reasoning under `reasoning_content` (e.g. DeepSeek)
    // or `reasoning` (other OpenAI-compatible providers).
    final String? reasoning =
        (delta?['reasoning_content'] as String?) ??
        (delta?['reasoning'] as String?);
    if (reasoning != null && reasoning.isNotEmpty) {
      return ReasoningEvent(reasoning);
    }

    if (finishReason != null) {
      // Don't emit DoneEvent here — the stream loop buffers it so usage
      // (which arrives in a separate empty-choices chunk) isn't lost.
      return DoneEvent(finishReason: finishReason, usage: _parseUsage(decoded));
    }

    return null;
  }

  /// Parse the top-level `usage` object from a streaming chunk. OpenAI sends
  /// usage in the final chunk (the one with `finish_reason` or an empty
  /// choices array) when `stream_options.include_usage` is set. Returns null
  /// when the chunk carries no usage.
  LlmUsage? _parseUsage(Map<String, dynamic> decoded) {
    final Object? usageJson = decoded['usage'];
    if (usageJson is! Map<String, dynamic>) return null;
    return LlmUsage(
      promptTokens: (usageJson['prompt_tokens'] as num?)?.toInt(),
      completionTokens: (usageJson['completion_tokens'] as num?)?.toInt(),
      totalTokens: (usageJson['total_tokens'] as num?)?.toInt(),
    );
  }
}
