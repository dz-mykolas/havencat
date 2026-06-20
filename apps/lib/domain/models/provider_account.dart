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
}
