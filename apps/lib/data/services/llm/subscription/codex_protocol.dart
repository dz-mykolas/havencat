import 'dart:convert';

import '../../../../domain/models/message.dart';

/// Wire details for using a "Sign in with ChatGPT" (Codex) OAuth token as a
/// plain chat backend.
///
/// The token's only usable surface is the Codex Responses API
/// (`chatgpt.com/backend-api/codex/responses`), but — contrary to a widely
/// copied early write-up — it does NOT require the Codex coding-agent prompt,
/// the `shell`/`update_plan` tools, or a fixed model. Mirroring what the
/// general-purpose OAuth proxies do, we send:
///   * any model the account exposes (from `/codex/models`),
///   * empty (or the user's own) `instructions` — no forced persona,
///   * no tools,
///   * `store: false`, `stream: true`,
/// plus three auth headers. That gives a normal "pick a model and chat"
/// experience on the subscription quota.
class CodexProtocol {
  const CodexProtocol._();

  /// Fallback Codex CLI version when the live one can't be resolved.
  ///
  /// `client_version` matters more than it looks: `/codex/models` is
  /// **version-gated** — an old value makes the backend serve an old, smaller
  /// model set (e.g. no `gpt-5.5`). [CodexVersionResolver] resolves the current
  /// version at runtime; this is only the offline fallback. Override the
  /// fallback with `--dart-define=CODEX_CLIENT_VERSION=<x.y.z>`.
  static const String defaultClientVersion = String.fromEnvironment(
    'CODEX_CLIENT_VERSION',
    defaultValue: '0.141.0',
  );

  static const String responsesPath = '/codex/responses';

  /// Path of the version-gated models catalog for the given [clientVersion].
  static String modelsPath(String clientVersion) =>
      '/codex/models?client_version=$clientVersion';

  /// Builds the Responses API request body for [messages] using [model].
  ///
  /// [instructions] is the system prompt; empty by default so the model behaves
  /// as a general assistant with no imposed persona. `temperature`/token caps
  /// are intentionally omitted — the Codex endpoint rejects them.
  static Map<String, Object?> buildBody({
    required String model,
    required List<ChatMessage> messages,
    String instructions = '',
  }) {
    return <String, Object?>{
      'model': model,
      'instructions': instructions,
      'input': <Map<String, Object?>>[
        for (final ChatMessage m in messages)
          if (m.text.trim().isNotEmpty)
            <String, Object?>{
              'type': 'message',
              'role': m.isUser ? 'user' : 'assistant',
              'content': <Map<String, Object?>>[
                <String, Object?>{
                  // Responses API: user turns are input_text, assistant turns
                  // are output_text.
                  'type': m.isUser ? 'input_text' : 'output_text',
                  'text': m.text,
                },
              ],
            },
      ],
      'store': false,
      'stream': true,
    };
  }

  /// The `chatgpt_account_id` claim from the access-token JWT, needed for the
  /// `chatgpt-account-id` header. Returns null if it can't be decoded.
  static String? accountIdFromJwt(String jwt) {
    try {
      final List<String> parts = jwt.split('.');
      if (parts.length != 3) return null;
      String payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      switch (payload.length % 4) {
        case 2:
          payload += '==';
        case 3:
          payload += '=';
      }
      final Object? decoded = jsonDecode(utf8.decode(base64Url.decode(payload)));
      if (decoded is! Map<String, dynamic>) return null;
      final Object? auth = decoded['https://api.openai.com/auth'];
      if (auth is Map<String, dynamic>) {
        return auth['chatgpt_account_id'] as String?;
      }
      return null;
    } on Object {
      return null;
    }
  }
}
