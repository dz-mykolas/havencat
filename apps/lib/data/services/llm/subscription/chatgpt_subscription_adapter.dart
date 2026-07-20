import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../../../domain/models/adapter_kind.dart';
import '../../../../domain/models/content_modality.dart';
import '../../../../domain/models/llm_model.dart';
import '../../../../domain/models/message_attachment.dart';
import '../../../../domain/models/provider_account.dart';
import '../../errors/provider_failure_mapper.dart';
import '../../auth/chatgpt_oauth_flow.dart';
import '../llm_adapter.dart';
import '../llm_endpoint.dart';
import '../llm_event.dart';
import '../sse/sse_client.dart';
import 'codex_protocol.dart';
import 'codex_version.dart';

/// Drives the ChatGPT subscription backend with a stored "Sign in with ChatGPT"
/// (Codex) OAuth access token, as a plain chat client.
///
/// This token type is only authorized for the Codex Responses API
/// (`chatgpt.com/backend-api/codex/responses`) — the web `/conversation`
/// endpoint requires the browser client's proof-of-work sentinel and rejects
/// API-style requests. But the Codex endpoint itself is a normal Responses API:
/// it accepts any model the account exposes, empty `instructions` (no forced
/// persona), and no tools. So the experience is "pick a model and chat",
/// drawing on the user's Plus/Pro quota rather than API billing. See
/// [CodexProtocol] for the wire details. We reuse [SseClient] for the SSE
/// transport and map the Responses API's semantic events to [LlmEvent]s.
class ChatGptSubscriptionAdapter implements LlmAdapter {
  factory ChatGptSubscriptionAdapter({
    Dio? dio,
    SseClient? sseClient,
    LlmEndpoint? endpoint,
    CodexVersionResolver? versionResolver,
  }) {
    final Dio resolvedDio = dio ?? Dio();
    final LlmEndpoint resolvedEndpoint = endpoint ?? LlmEndpoint.fromPlatform();
    return ChatGptSubscriptionAdapter._(
      resolvedDio,
      sseClient ?? SseClient(resolvedDio),
      resolvedEndpoint,
      versionResolver ??
          CodexVersionResolver(dio: resolvedDio, endpoint: resolvedEndpoint),
    );
  }

  ChatGptSubscriptionAdapter._(
    this._dio,
    this._sse,
    this._endpoint,
    this._version,
  );

  static final Logger _log = Logger('llm.chatgpt_sub');

  final Dio _dio;
  final SseClient _sse;
  final LlmEndpoint _endpoint;
  final CodexVersionResolver _version;
  static const ProviderFailureMapper _failureMapper = ProviderFailureMapper();

  /// Last-resort model when the account has none selected yet. The model
  /// selector normally fills this in from the live [listModels] result.
  static const String _fallbackModel = 'gpt-5.2';

  @override
  AdapterKind get kind => AdapterKind.subscription;

  @override
  Stream<LlmEvent> stream({
    required LlmRequest request,
    required ProviderAccount account,
    required String? secret,
  }) async* {
    final FailureSource failureSource = FailureSource(
      subsystem: AppSubsystem.llm,
      operation: 'generate',
      providerId: account.displayName,
      accountId: account.id,
      modelId: _resolveModel(account),
    );
    if (secret == null || secret.isEmpty) {
      _log.warning('stream: no secret (not signed in)');
      yield ErrorEvent(
        AuthError('Not signed in. Re-add the account.', source: failureSource),
      );
      return;
    }

    final String model = _resolveModel(account);
    final String baseUrl = ChatGptOAuthConfig.chatgptApiBaseUrl;

    _log.info(
      'stream: model=$model messages=${request.messages.length} '
      'tools=${request.tools.length}',
    );

    final Future<void> Function()? signal = request.signal;
    StreamSubscription<void>? signalSub;
    CancelToken? activeCancelToken;
    bool cancelled = false;
    if (signal != null) {
      signalSub = signal().asStream().listen((_) {
        cancelled = true;
        final CancelToken? token = activeCancelToken;
        if (token != null && !token.isCancelled) token.cancel();
      });
    }

    try {
      final ResolvedRequest resolved = _endpoint.resolve(
        '$baseUrl${CodexProtocol.responsesPath}',
        _codexHeaders(secret),
      );
      final String body = jsonEncode(
        CodexProtocol.buildBody(
          model: model,
          messages: request.messages,
          instructions: request.systemPrompt ?? '',
          tools: request.tools,
        ),
      );
      final CancelToken cancelToken = CancelToken();
      activeCancelToken = cancelToken;
      try {
        final Stream<SseEvent> events = _sse.stream(
          url: resolved.url,
          method: 'POST',
          headers: resolved.headers,
          body: body,
          cancelToken: cancelToken,
        );
        await for (final SseEvent event in events) {
          final List<LlmEvent> parsed = _parseEvents(event.data, failureSource);
          _log.fine(
            'sse raw: ${event.data.substring(0, event.data.length.clamp(0, 500))}'
            ' → parsed=${parsed.map((LlmEvent value) => value.runtimeType).join(',')}',
          );
          for (final LlmEvent value in parsed) {
            yield value;
            if (value is DoneEvent) return;
          }
        }
        if (cancelled) return;
        throw NetworkError(
          'The response stream ended before completion.',
          source: failureSource,
        );
      } on Object catch (error, stack) {
        if (cancelled ||
            (error is DioException && CancelToken.isCancel(error))) {
          return;
        }
        final AppFailure failure = _failureMapper.fromException(
          error,
          source: failureSource,
          flavor: ProviderErrorFlavor.codex,
        );
        _log.severe('stream: request failed', error, stack);
        yield ErrorEvent(failure);
      } finally {
        if (identical(activeCancelToken, cancelToken)) {
          activeCancelToken = null;
        }
      }
    } finally {
      final CancelToken? token = activeCancelToken;
      if (token != null && !token.isCancelled) token.cancel();
      await signalSub?.cancel();
    }
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
    if (secret == null || secret.isEmpty) {
      throw AuthError(
        'Not signed in. Re-add the account.',
        source: failureSource,
      );
    }

    try {
      final String baseUrl = ChatGptOAuthConfig.chatgptApiBaseUrl;
      final String version = await _version.resolve();
      final ResolvedRequest resolved = _endpoint.resolve(
        '$baseUrl${CodexProtocol.modelsPath(version)}',
        _codexHeaders(secret),
      );
      final Response<dynamic> response = await _dio.get<dynamic>(
        resolved.url,
        options: Options(headers: resolved.headers),
      );
      return _parseModels(response.data);
    } on Object catch (error) {
      throw _failureMapper.fromException(
        error,
        source: failureSource,
        flavor: ProviderErrorFlavor.codex,
        fallbackMessage: 'ChatGPT models could not be loaded.',
      );
    }
  }

  String _resolveModel(ProviderAccount account) {
    final Object? configured = account.config['model'];
    if (configured is String && configured.isNotEmpty) return configured;
    return _fallbackModel;
  }

  Map<String, String> _codexHeaders(String secret) {
    final String? accountId = CodexProtocol.accountIdFromJwt(secret);
    return <String, String>{
      'Authorization': 'Bearer $secret',
      'Content-Type': 'application/json',
      'OpenAI-Beta': 'responses=experimental',
      'chatgpt-account-id': ?accountId,
    };
  }

  List<LlmModel> _parseModels(Object? body) {
    List<dynamic>? entries;
    if (body is Map<String, dynamic>) {
      entries =
          (body['models'] as List<dynamic>?) ??
          (body['data'] as List<dynamic>?);
    } else if (body is List) {
      entries = body;
    }
    if (entries == null) return const <LlmModel>[];

    final List<LlmModel> models = <LlmModel>[];
    for (final dynamic entry in entries) {
      if (entry is Map<String, dynamic>) {
        final String? id = (entry['slug'] ?? entry['id']) as String?;
        if (id == null || id.isEmpty) continue;
        // Internal/hidden models (e.g. `codex-auto-review`, the auto-review
        // reviewer agent) carry `visibility: hide`. We surface the flag rather
        // than drop them so the global "show hidden models" setting can decide.
        final Object? visibility = entry['visibility'];
        final bool hidden =
            visibility is String && visibility.toLowerCase() == 'hide';
        final Object? name = entry['display_name'] ?? entry['displayName'];
        models.add(
          LlmModel(
            id: id,
            displayName: name is String && name.isNotEmpty ? name : null,
            hidden: hidden,
          ),
        );
      } else if (entry is String && entry.isNotEmpty) {
        models.add(LlmModel(id: entry));
      }
    }
    return models;
  }

  /// Parse one Responses API SSE payload into an [LlmEvent].
  ///
  /// The Responses API streams function calls in three stages:
  ///   1. `response.output_item.added` — announces the `function_call` item
  ///      with its `call_id` and `name` (arguments empty).
  ///   2. `response.function_call_arguments.delta` — partial argument
  ///      fragments (only `item_id` + `delta`, no `call_id`/`name`).
  ///   3. `response.function_call_arguments.done` — final `name` + complete
  ///      `arguments` for the call.
  ///
  /// We emit:
  ///   - A `ToolCallEvent(id, name, args:'')` on stage 1 to seed the
  ///     accumulator in the repository.
  ///   - `ToolCallEvent(id:'', name:'', args:delta)` on stage 2 so the
  ///     repository appends argument fragments to the last call.
  ///   - Nothing on stage 3 — the repository already accumulated the deltas.
  ///     (We could emit a correction here if the deltas were lossy, but
  ///     they're not.)
  ///
  /// Text and reasoning deltas are surfaced as [TokenEvent] / [ReasoningEvent].
  /// Everything else (lifecycle, content parts, annotations) is ignored.
  List<LlmEvent> _parseEvents(String data, FailureSource failureSource) {
    final String trimmed = data.trim();
    if (trimmed.isEmpty) return const <LlmEvent>[];
    if (trimmed == '[DONE]') {
      return const <LlmEvent>[DoneEvent(finishReason: 'stop')];
    }

    final Object? decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return const <LlmEvent>[];

    switch (decoded['type'] as String?) {
      case 'response.output_text.delta':
        final String? delta = decoded['delta'] as String?;
        return (delta != null && delta.isNotEmpty)
            ? <LlmEvent>[TokenEvent(delta)]
            : const <LlmEvent>[];

      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_text.delta':
        final String? delta = decoded['delta'] as String?;
        return (delta != null && delta.isNotEmpty)
            ? <LlmEvent>[ReasoningEvent(delta)]
            : const <LlmEvent>[];

      case 'response.image_generation_call.partial_image':
        final String? data =
            (decoded['partial_image_b64'] ?? decoded['b64_json']) as String?;
        if (data == null || data.isEmpty) return const <LlmEvent>[];
        return <LlmEvent>[
          AttachmentEvent(
            MessageAttachment(
              id:
                  (decoded['item_id'] ?? decoded['id'] ?? 'generated-image-0')
                      as String,
              modality: ContentModality.image,
              mimeType: 'image/png',
              source: AttachmentSource.inlineBase64,
              data: data,
              generated: true,
            ),
          ),
        ];

      // Stage 1: function_call item announced with call_id + name.
      case 'response.output_item.added':
        final Map<String, dynamic>? item =
            decoded['item'] as Map<String, dynamic>?;
        if (item != null && item['type'] == 'function_call') {
          final String? callId = item['call_id'] as String?;
          final String? name = item['name'] as String?;
          if (callId != null && callId.isNotEmpty) {
            return <LlmEvent>[
              ToolCallEvent(id: callId, name: name ?? '', args: ''),
            ];
          }
        }
        return const <LlmEvent>[];

      // Stage 2: argument delta fragments (item_id only, no call_id/name).
      case 'response.function_call_arguments.delta':
        final String? argsDelta = decoded['delta'] as String?;
        if (argsDelta == null || argsDelta.isEmpty) {
          return const <LlmEvent>[];
        }
        return <LlmEvent>[ToolCallEvent(id: '', name: '', args: argsDelta)];

      // Stage 3: arguments finalized. The repository already accumulated
      // the deltas — nothing to emit.
      case 'response.function_call_arguments.done':
        return const <LlmEvent>[];

      case 'response.completed':
        final Map<String, dynamic>? response =
            decoded['response'] as Map<String, dynamic>?;
        return <LlmEvent>[
          ..._imageEventsFromResponse(response),
          DoneEvent(finishReason: 'stop', usage: _parseUsage(response)),
        ];

      case 'response.failed':
      case 'error':
        return <LlmEvent>[
          ErrorEvent(
            _failureMapper.fromPayload(
              decoded,
              source: failureSource,
              flavor: ProviderErrorFlavor.codex,
            ),
          ),
        ];

      default:
        return const <LlmEvent>[];
    }
  }

  List<LlmEvent> _imageEventsFromResponse(Map<String, dynamic>? response) {
    final Object? output = response?['output'];
    if (output is! List) return const <LlmEvent>[];
    final List<LlmEvent> result = <LlmEvent>[];
    for (int i = 0; i < output.length; i++) {
      final Object? raw = output[i];
      if (raw is! Map) continue;
      final String id = (raw['id'] as String?) ?? 'generated-image-$i';
      final Object? imageData = raw['result'] ?? raw['b64_json'];
      if (imageData is String && imageData.isNotEmpty) {
        result.add(
          AttachmentEvent(
            MessageAttachment(
              id: id,
              modality: ContentModality.image,
              mimeType: (raw['media_type'] as String?) ?? 'image/png',
              source: AttachmentSource.inlineBase64,
              data: imageData,
              generated: true,
            ),
          ),
        );
      }
      final Object? content = raw['content'];
      if (content is! List) continue;
      for (int partIndex = 0; partIndex < content.length; partIndex++) {
        final Object? part = content[partIndex];
        if (part is! Map) continue;
        final Object? url = part['image_url'] ?? part['url'];
        final Object? base64 = part['b64_json'] ?? part['data'];
        if (url is String && url.isNotEmpty) {
          result.add(
            AttachmentEvent(
              MessageAttachment.fromUrl(
                id: '$id-$partIndex',
                modality: ContentModality.image,
                url: url,
                mimeType: (part['media_type'] as String?) ?? 'image/png',
                generated: true,
              ),
            ),
          );
        } else if (base64 is String && base64.isNotEmpty) {
          result.add(
            AttachmentEvent(
              MessageAttachment(
                id: '$id-$partIndex',
                modality: ContentModality.image,
                mimeType: (part['media_type'] as String?) ?? 'image/png',
                source: AttachmentSource.inlineBase64,
                data: base64,
                generated: true,
              ),
            ),
          );
        }
      }
    }
    return result;
  }

  /// Extracts usage from a `response.completed` payload. The Responses API
  /// reports `response.usage` with `input_tokens` / `output_tokens` /
  /// `total_tokens` (different field names than Chat Completions' `prompt_*`).
  LlmUsage? _parseUsage(Map<String, dynamic>? response) {
    final Map<String, dynamic>? usage =
        response?['usage'] as Map<String, dynamic>?;
    if (usage == null) return null;
    return LlmUsage(
      promptTokens: usage['input_tokens'] as int?,
      completionTokens: usage['output_tokens'] as int?,
      totalTokens: usage['total_tokens'] as int?,
    );
  }
}
