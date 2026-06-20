import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../../domain/models/adapter_kind.dart';
import '../../../../domain/models/provider_account.dart';
import '../../auth/chatgpt_oauth_flow.dart';
import '../llm_adapter.dart';
import '../llm_event.dart';
import '../openai_compatible/sse_client.dart';

/// Calls the ChatGPT backend API (`chatgpt.com/backend-api`) using a stored
/// OAuth access token from [ChatGptOAuthFlow].
///
/// This consumes the user's ChatGPT subscription quota (Free/Plus/Pro), not
/// their API billing. The request/response shape is OpenAI-compatible
/// (`/conversations` streaming), so we reuse [SseClient] for the wire format
/// — only the base URL, auth header, and a couple of ChatGPT-specific headers
/// differ from [OpenAiCompatibleAdapter].
///
/// The access token (and refresh token, expiry, plan type) live in
/// [ProviderAccount.config] as non-secret metadata; the token itself is the
/// "secret" passed in via [secret] from [SecretStore].
class ChatGptSubscriptionAdapter implements LlmAdapter {
  ChatGptSubscriptionAdapter({Dio? dio, SseClient? sseClient})
    : _sse = sseClient ?? SseClient(dio ?? Dio());

  final SseClient _sse;

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
      final Stream<SseEvent> events = _sse.stream(
        url: '$baseUrl/conversations',
        method: 'POST',
        headers: <String, String>{
          'Authorization': 'Bearer $secret',
          'Content-Type': 'application/json',
          // ChatGPT backend requires these; without them the request 400s.
          'OAI-Client-Version': '1.0.0',
          'OAI-Device-Id': _deviceId(account),
          'OAI-Language': 'en-US',
        },
        body: jsonEncode(_buildBody(request, account)),
        cancelToken: cancelToken,
      );

      await for (final SseEvent event in events) {
        if (event.data == '[DONE]') {
          yield const DoneEvent(finishReason: 'stop');
          return;
        }
        final LlmEvent? parsed = _parseEvent(event.data);
        if (parsed != null) yield parsed;
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

  /// Stable per-account device id. ChatGPT's backend ties sessions to a
  /// device id; we derive one from the account id so it's stable across
  /// launches but unique per configured account.
  String _deviceId(ProviderAccount account) {
    // Simple deterministic hash → hex. Not cryptographic; just needs to be
    // stable and look like a UUID-ish string to the backend.
    int hash = 0;
    for (final int c in account.id.codeUnits) {
      hash = (hash * 31 + c) & 0xFFFFFFFF;
    }
    final String hex = hash.toRadixString(16).padLeft(8, '0');
    return '$hex-$hex-$hex-$hex';
  }

  Map<String, Object?> _buildBody(LlmRequest request, ProviderAccount account) {
    final String model =
        (account.config['model'] as String?)?.isNotEmpty == true
        ? (account.config['model'] as String)
        : 'gpt-4o';

    return <String, Object?>{
      'action': 'next',
      'model': model,
      'stream': true,
      'messages': request.messages
          .where((m) => m.text.trim().isNotEmpty)
          .map(
            (m) => <String, Object?>{
              'author': <String, String>{
                'role': m.isUser ? 'user' : 'assistant',
              },
              'content': <String, Object?>{
                'content_type': 'text',
                'parts': <String>[m.text],
              },
            },
          )
          .toList(),
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxTokens != null) 'max_tokens': request.maxTokens,
    };
  }

  /// Parse one SSE data payload from the ChatGPT backend.
  ///
  /// The backend streams `data: {"v": {"message": {"content": {"parts": [...]}}}}`
  /// deltas and a terminal `data: [DONE]`. We extract the latest text delta
  /// from `parts[0]`.
  LlmEvent? _parseEvent(String data) {
    if (data.trim().isEmpty) return null;
    final Object? decoded = jsonDecode(data);
    if (decoded is! Map<String, dynamic>) return null;

    final Map<String, dynamic>? v = decoded['v'] as Map<String, dynamic>?;
    if (v == null) return null;

    final Map<String, dynamic>? message = v['message'] as Map<String, dynamic>?;
    if (message == null) return null;

    final Map<String, dynamic>? content =
        message['content'] as Map<String, dynamic>?;
    if (content == null) return null;

    final List<dynamic>? parts = content['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) return null;

    final String text = parts.last.toString();
    if (text.isEmpty) return null;

    final String? finishReason = message['end_turn'] == true ? 'stop' : null;
    if (finishReason != null) {
      return DoneEvent(finishReason: finishReason);
    }

    return TokenEvent(text);
  }

  LlmError _mapDioError(DioException e) {
    final int? status = e.response?.statusCode;
    final String body = e.response?.data?.toString() ?? e.message ?? '';

    if (status == 401 || status == 403) {
      return AuthError('Session expired. Please sign in again.');
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
