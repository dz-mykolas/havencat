import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../../domain/models/adapter_kind.dart';
import '../../../../domain/models/llm_model.dart';
import '../../../../domain/models/message.dart';
import '../../../../domain/models/provider_account.dart';
import '../llm_adapter.dart';
import '../llm_endpoint.dart';
import '../llm_event.dart';
import 'sse_client.dart';

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

  final Dio _dio;
  final SseClient _sse;
  final LlmEndpoint _endpoint;

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

    // Wire the request's cancellation signal (if any) to dio's CancelToken.
    final Future<void> Function()? signal = request.signal;
    StreamSubscription<void>? signalSub;
    if (signal != null) {
      signalSub = signal().asStream().listen((_) {
        if (!cancelToken.isCancelled) cancelToken.cancel();
      });
    }

    try {
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

      await for (final SseEvent event in events) {
        if (event.data == '[DONE]') {
          yield const DoneEvent(finishReason: 'stop');
          return;
        }
        final LlmEvent? parsed = _parseChunk(event.data);
        if (parsed != null) yield parsed;
      }
      // Stream ended without an explicit [DONE] marker — still terminate.
      yield const DoneEvent();
    } on DioException catch (e) {
      yield ErrorEvent(_mapDioError(e));
    } catch (e) {
      yield ErrorEvent(UnknownError(e.toString()));
    } finally {
      await signalSub?.cancel();
    }
  }

  @override
  Future<List<LlmModel>> listModels({
    required ProviderAccount account,
    required String? secret,
  }) async {
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
  }

  String _readBaseUrl(ProviderAccount account) {
    final String baseUrl =
        (account.config['baseUrl'] as String?)?.trim().isNotEmpty == true
        ? (account.config['baseUrl'] as String).trim()
        : 'https://api.openai.com/v1';
    // Strip a trailing slash so we always join with '/chat/completions'.
    return baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
  }

  String _readModel(ProviderAccount account, LlmRequest request) {
    return request.model.isNotEmpty
        ? request.model
        : (account.config['model'] as String?) ?? 'gpt-4o-mini';
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
    final List<Map<String, Object?>> messages =
        request.messages
            .where((m) => m.text.trim().isNotEmpty || m.toolCalls.isNotEmpty)
            .map(_messageToJson)
            .toList();
    if (request.systemPrompt != null && request.systemPrompt!.isNotEmpty) {
      messages.insert(
        0,
        <String, Object?>{
          'role': 'system',
          'content': request.systemPrompt,
        },
      );
    }
    return <String, Object?>{
      'model': model,
      'stream': true,
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
      'content': m.text,
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
  LlmEvent? _parseChunk(String data) {
    if (data.trim().isEmpty) return null;
    final Object? decoded = jsonDecode(data);
    if (decoded is! Map<String, dynamic>) return null;

    final List<dynamic>? choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) return null;

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

    if (finishReason != null) {
      return DoneEvent(finishReason: finishReason);
    }

    final String? content = delta?['content'] as String?;
    if (content != null && content.isNotEmpty) {
      return TokenEvent(content);
    }

    // Some providers stream reasoning under `reasoning_content` (e.g. DeepSeek).
    final String? reasoning = delta?['reasoning_content'] as String?;
    if (reasoning != null && reasoning.isNotEmpty) {
      return ReasoningEvent(reasoning);
    }

    return null;
  }

  LlmError _mapDioError(DioException e) {
    final int? status = e.response?.statusCode;
    final String body = e.response?.data?.toString() ?? e.message ?? '';

    if (status == 401 || status == 403) {
      return AuthError('Authentication failed ($status). Check your API key.');
    }
    if (status == 429) {
      return RateLimitError('Rate limited. Please slow down.');
    }
    if (status == 402) {
      return QuotaError('Insufficient quota / billing issue.');
    }
    if (status != null && status >= 400 && status < 500) {
      return InvalidRequestError('Request rejected ($status): $body');
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return NetworkError('Network error: ${e.message ?? e.type.name}');
    }
    return UnknownError('Request failed: ${e.message ?? e.type.name}');
  }
}
