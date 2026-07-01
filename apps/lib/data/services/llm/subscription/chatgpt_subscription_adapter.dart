import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../../../domain/models/adapter_kind.dart';
import '../../../../domain/models/llm_model.dart';
import '../../../../domain/models/provider_account.dart';
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
    if (secret == null || secret.isEmpty) {
      _log.warning('stream: no secret (not signed in)');
      yield const ErrorEvent(AuthError('Not signed in. Re-add the account.'));
      return;
    }

    final String model = _resolveModel(account);
    final String baseUrl = ChatGptOAuthConfig.chatgptApiBaseUrl;
    final CancelToken cancelToken = CancelToken();

    _log.info(
      'stream: model=$model messages=${request.messages.length} '
      'tools=${request.tools.length}',
    );

    final Future<void> Function()? signal = request.signal;
    StreamSubscription<void>? signalSub;
    if (signal != null) {
      signalSub = signal().asStream().listen((_) {
        if (!cancelToken.isCancelled) cancelToken.cancel();
      });
    }

    try {
      final ResolvedRequest resolved = _endpoint.resolve(
        '$baseUrl${CodexProtocol.responsesPath}',
        _codexHeaders(secret),
      );
      final Stream<SseEvent> events = _sse.stream(
        url: resolved.url,
        method: 'POST',
        headers: resolved.headers,
        body: jsonEncode(
          CodexProtocol.buildBody(
            model: model,
            messages: request.messages,
            instructions: request.systemPrompt ?? '',
            tools: request.tools,
          ),
        ),
        cancelToken: cancelToken,
      );

      await for (final SseEvent event in events) {
        final LlmEvent? parsed = _parseEvent(event.data);
        _log.fine(
          'sse raw: ${event.data.substring(0, event.data.length.clamp(0, 500))}'
          ' → parsed=${parsed?.runtimeType ?? 'null'}',
        );
        if (parsed == null) continue;
        yield parsed;
        if (parsed is DoneEvent) return;
      }
      _log.fine('stream: ended without explicit done');
      yield const DoneEvent();
    } on DioException catch (e) {
      _log.warning(
        'stream: DioException ${e.type.name} status=${e.response?.statusCode}',
      );
      yield ErrorEvent(_mapDioError(e));
    } catch (e, stack) {
      _log.severe('stream: unexpected error', e, stack);
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
    if (secret == null || secret.isEmpty) {
      throw StateError('Not signed in.');
    }

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
  LlmEvent? _parseEvent(String data) {
    final String trimmed = data.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed == '[DONE]') return const DoneEvent(finishReason: 'stop');

    final Object? decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return null;

    switch (decoded['type'] as String?) {
      case 'response.output_text.delta':
        final String? delta = decoded['delta'] as String?;
        return (delta != null && delta.isNotEmpty) ? TokenEvent(delta) : null;

      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_text.delta':
        final String? delta = decoded['delta'] as String?;
        return (delta != null && delta.isNotEmpty)
            ? ReasoningEvent(delta)
            : null;

      // Stage 1: function_call item announced with call_id + name.
      case 'response.output_item.added':
        final Map<String, dynamic>? item =
            decoded['item'] as Map<String, dynamic>?;
        if (item != null && item['type'] == 'function_call') {
          final String? callId = item['call_id'] as String?;
          final String? name = item['name'] as String?;
          if (callId != null && callId.isNotEmpty) {
            return ToolCallEvent(id: callId, name: name ?? '', args: '');
          }
        }
        return null;

      // Stage 2: argument delta fragments (item_id only, no call_id/name).
      case 'response.function_call_arguments.delta':
        final String? argsDelta = decoded['delta'] as String?;
        if (argsDelta == null || argsDelta.isEmpty) return null;
        return ToolCallEvent(id: '', name: '', args: argsDelta);

      // Stage 3: arguments finalized. The repository already accumulated
      // the deltas — nothing to emit.
      case 'response.function_call_arguments.done':
        return null;

      case 'response.completed':
        return DoneEvent(
          finishReason: 'stop',
          usage: _parseUsage(decoded['response'] as Map<String, dynamic>?),
        );

      case 'response.failed':
      case 'error':
        return ErrorEvent(UnknownError(_extractError(decoded)));

      default:
        return null;
    }
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

  String _extractError(Map<String, dynamic> decoded) {
    final Object? response = decoded['response'];
    if (response is Map<String, dynamic>) {
      final Object? error = response['error'];
      if (error is Map<String, dynamic>) {
        final Object? message = error['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    }
    final Object? error = decoded['error'];
    if (error is Map<String, dynamic>) {
      final Object? message = error['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    return 'Stream failed.';
  }

  LlmError _mapDioError(DioException e) {
    final int? status = e.response?.statusCode;
    final String body = e.response?.data?.toString() ?? e.message ?? '';

    // 401 = the access token is genuinely rejected (expired/invalid) → re-auth.
    if (status == 401) {
      return AuthError('Session expired. Please sign in again.');
    }
    // 403 is NOT necessarily an expired session — surface the real reason.
    if (status == 403) {
      return AuthError('Request forbidden by ChatGPT (403). $body');
    }
    if (status == 429) {
      return RateLimitError('Rate limited. Please slow down.');
    }
    if (status == 402) {
      return QuotaError('Subscription quota exhausted.');
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
