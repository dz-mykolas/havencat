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
  ///
  /// Two config keys drive model selection:
  ///   * `'model'` — the currently selected model id.
  ///   * `'enabledModels'` — a `List<String>` of model ids the user has opted
  ///     into using for this provider. Defaults to empty (the Quick-Add flow
  ///     writes the user's checkbox selection here). When empty the chat header
  ///     shows the provider greyed out and non-selectable.
  final Map<String, Object?> config;

  DateTime? createdAt;

  /// The set of model ids the user has enabled for this provider.
  List<String> get enabledModels {
    final Object? value = config['enabledModels'];
    if (value == null) return const <String>[];
    if (value is! List) {
      throw const FormatException('enabledModels must be a list.');
    }
    final List<String> models = <String>[];
    for (final Object? model in value) {
      if (model is! String || model.isEmpty) {
        throw const FormatException(
          'enabledModels must contain non-empty strings.',
        );
      }
      models.add(model);
    }
    return List<String>.unmodifiable(models);
  }

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
    DateTime? createdAt;
    if (created != null) {
      if (created is! String) {
        throw const FormatException('Provider account createdAt is invalid.');
      }
      createdAt = DateTime.tryParse(created);
      if (createdAt == null) {
        throw const FormatException('Provider account createdAt is invalid.');
      }
    }
    return ProviderAccount(
      id: json['id'] as String,
      kind: AdapterKind.values.byName(json['kind'] as String),
      displayName: json['displayName'] as String,
      config: Map<String, Object?>.from(json['config'] as Map),
      createdAt: createdAt,
    );
  }
}
