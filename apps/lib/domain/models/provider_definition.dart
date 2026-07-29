import 'adapter_kind.dart';

enum ProviderAuthMethod { apiKey, chatGptDeviceCode, poeOAuth }

/// A catalog entry describing a provider the user can add an account for.
///
/// Think of this as the "menu" the settings UI shows: "Add OpenAI-compatible",
/// "Add ChatGPT subscription", "Add Anthropic", etc. Each definition knows
/// its [kind], a sensible default [configTemplate] (e.g. OpenAI's base URL),
/// and whether it needs an API key or an OAuth flow.
class ProviderDefinition {
  const ProviderDefinition({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.description,
    this.configTemplate = const <String, Object?>{},
    this.authMethod = ProviderAuthMethod.apiKey,
    this.apiKeyUrl,
    this.modelsDevId,
  });

  /// Stable id, e.g. 'openai_compatible', 'chatgpt_subscription', 'poe'.
  final String id;

  final AdapterKind kind;

  /// Short label shown in the "Add provider" list.
  final String displayName;

  /// One-line description shown under the label.
  final String description;

  /// Default non-secret config values to prefill when adding an account.
  final Map<String, Object?> configTemplate;

  final ProviderAuthMethod authMethod;

  bool get requiresApiKey => authMethod == ProviderAuthMethod.apiKey;

  bool get requiresOAuth => switch (authMethod) {
    ProviderAuthMethod.chatGptDeviceCode || ProviderAuthMethod.poeOAuth => true,
    ProviderAuthMethod.apiKey => false,
  };

  /// Link to the provider's "get an API key" page, surfaced as a "Get an API
  /// key" action in the Quick-Add dialog. Optional — some definitions (e.g.
  /// `openai_compatible` as the generic fallback) leave this null and the
  /// Quick-Add UI derives a URL from the models.dev `doc` link instead.
  final String? apiKeyUrl;

  /// The models.dev provider id this definition maps to (e.g. `anthropic`,
  /// `openai`, `groq`, `openrouter`). Used by the Discover panel's Quick-Add
  /// flow to look up the cached [ProviderModels] group for this definition.
  /// Null on `openai_compatible` (the generic OpenAI-compatible fallback) —
  /// resolution there goes through `quick_add_resolver.dart` instead.
  final String? modelsDevId;
}

/// Built-in catalog of providers the app knows how to configure.
///
/// Subscription entries are grouped first (the "Subscription logins" section
/// in the UI), then API-key entries (the "API keys" section).
class ProviderCatalog {
  const ProviderCatalog._();

  static const List<ProviderDefinition> subscription = <ProviderDefinition>[
    ProviderDefinition(
      id: 'chatgpt_subscription',
      kind: AdapterKind.chatGptCodex,
      displayName: 'ChatGPT',
      description: 'Sign in with your ChatGPT Free/Plus/Pro account.',
      authMethod: ProviderAuthMethod.chatGptDeviceCode,
    ),
    ProviderDefinition(
      id: 'poe_subscription',
      kind: AdapterKind.openaiCompatible,
      displayName: 'Poe',
      description: 'Sign in with your Poe account (uses subscription points).',
      configTemplate: <String, Object?>{'baseUrl': 'https://api.poe.com/v1'},
      authMethod: ProviderAuthMethod.poeOAuth,
    ),
  ];

  static const List<ProviderDefinition> apiKey = <ProviderDefinition>[
    ProviderDefinition(
      id: 'openai_compatible',
      kind: AdapterKind.openaiCompatible,
      displayName: 'OpenAI-compatible',
      description: 'OpenAI, Qwen, OpenRouter, Groq, Ollama, LM Studio, vLLM…',
      configTemplate: <String, Object?>{
        'baseUrl': 'https://api.openai.com/v1',
        'model': 'gpt-4o-mini',
        'enabledModels': <String>['gpt-4o-mini'],
      },
      // Generic fallback — `modelsDevId` is intentionally null; the resolver
      // in `quick_add_resolver.dart` picks this definition for any OpenAI-
      // compatible provider and overrides `baseUrl` from the group's `api` URL.
      apiKeyUrl: 'https://platform.openai.com/api-keys',
    ),
    ProviderDefinition(
      id: 'anthropic',
      kind: AdapterKind.anthropic,
      displayName: 'Anthropic',
      description: 'Claude API (api.anthropic.com).',
      configTemplate: <String, Object?>{
        'baseUrl': 'https://api.anthropic.com',
        'model': 'claude-3-5-sonnet-latest',
        'enabledModels': <String>['claude-3-5-sonnet-latest'],
      },
      apiKeyUrl: 'https://console.anthropic.com/settings/keys',
      modelsDevId: 'anthropic',
    ),
    ProviderDefinition(
      id: 'gemini_native',
      kind: AdapterKind.geminiNative,
      displayName: 'Gemini',
      description: 'Google Gemini API (generativelanguage.googleapis.com).',
      configTemplate: <String, Object?>{
        'model': 'gemini-1.5-flash',
        'enabledModels': <String>['gemini-1.5-flash'],
      },
      apiKeyUrl: 'https://aistudio.google.com/app/apikey',
      modelsDevId: 'google',
    ),
  ];

  /// All known providers, subscription section first.
  static const List<ProviderDefinition> all = <ProviderDefinition>[
    ...subscription,
    ...apiKey,
  ];

  static ProviderDefinition? byId(String id) {
    for (final ProviderDefinition d in all) {
      if (d.id == id) return d;
    }
    return null;
  }
}
