import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../../domain/models/adapter_kind.dart';
import '../../../../domain/models/llm_model.dart';
import '../../../../domain/models/provider_account.dart';
import '../../auth/chatgpt_oauth_flow.dart';
import '../llm_adapter.dart';
import '../llm_endpoint.dart';
import '../llm_event.dart';
import '../openai_compatible/sse_client.dart';
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
      yield const ErrorEvent(AuthError('Not signed in. Re-add the account.'));
      return;
    }

    final String model = _resolveModel(account);
    final String baseUrl = ChatGptOAuthConfig.chatgptApiBaseUrl;
    final CancelToken cancelToken = CancelToken();

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
        if (parsed == null) continue;
        yield parsed;
        if (parsed is DoneEvent) return;
      }
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
  /// Events are typed via the `type` field. We surface assistant text deltas,
  /// reasoning-summary deltas, function-call arguments (tool calls),
  /// completion, and errors; everything else (item lifecycle, etc.) is
  /// ignored.
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
      // Responses API: function call arguments stream as deltas. The first
      // event for a call carries the call_id + name; subsequent ones carry
      // argument fragments. We surface each as a ToolCallEvent so the
      // repository can accumulate by id.
      case 'response.function_call_arguments.delta':
        final String? callId = decoded['call_id'] as String?;
        final String? name = decoded['name'] as String?;
        final String? argsDelta = decoded['delta'] as String?;
        if (argsDelta == null || argsDelta.isEmpty) return null;
        return ToolCallEvent(
          id: callId ?? '',
          name: name ?? '',
          args: argsDelta,
        );
      case 'response.function_call_arguments.done':
        // The full arguments are now available; the repository has already
        // accumulated the deltas. Nothing to emit here.
        return null;
      case 'response.completed':
        return const DoneEvent(finishReason: 'stop');
      case 'response.failed':
      case 'error':
        return ErrorEvent(UnknownError(_extractError(decoded)));
      default:
        return null;
    }
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
