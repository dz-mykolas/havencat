import 'adapter_kind.dart';

/// A configured, user-named instance of a provider.
///
/// One provider definition (e.g. "OpenAI-compatible") can have many accounts:
/// "OpenAI personal", "Qwen DashScope", "Local Ollama", "ChatGPT Plus
/// subscription", etc. Each account holds its own [config] (base URL, model,
/// API key reference, OAuth token reference) and is what a conversation binds
/// to via [Conversation.providerAccountId].
///
/// Secrets (API keys, OAuth tokens) are NEVER stored in [config]. They live
/// in `flutter_secure_storage` keyed by [id]; [config] only holds non-secret
/// display + endpoint data.
class ProviderAccount {
  ProviderAccount({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.config,
    this.createdAt,
  });

  /// Stable unique id. Also the secure-storage key namespace for secrets.
  final String id;

  /// Which adapter family powers this account.
  final AdapterKind kind;

  /// User-facing label, e.g. "OpenAI personal" or "Local Ollama".
  final String displayName;

  /// Adapter-specific, non-secret configuration (base URL, default model,
  /// headers, etc.). Secret material lives in secure storage, not here.
  final Map<String, Object?> config;

  DateTime? createdAt;

  /// Non-secret JSON for persistence. Secrets (API keys, OAuth tokens) are
  /// deliberately absent — they live in secure storage keyed by [id].
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'displayName': displayName,
    'config': config,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
  };

  factory ProviderAccount.fromJson(Map<String, Object?> json) {
    final Object? created = json['createdAt'];
    return ProviderAccount(
      id: json['id'] as String,
      kind: AdapterKind.values.byName(json['kind'] as String),
      displayName: json['displayName'] as String,
      config: Map<String, Object?>.from(
        (json['config'] as Map?) ?? const <String, Object?>{},
      ),
      createdAt: created is String ? DateTime.tryParse(created) : null,
    );
  }
}
