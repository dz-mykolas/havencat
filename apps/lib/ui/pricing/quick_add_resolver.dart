import '../../domain/models/model_pricing.dart';
import '../../domain/models/provider_definition.dart';

/// The outcome of resolving a models.dev provider to one of our adapters.
///
/// The Discover panel's "Add API key" button uses this to decide whether to
/// show an enabled button ([supported]), a disabled button with a tooltip
/// explaining why ([uncertain]), or no button at all ([unsupported]).
sealed class ResolveResult {
  const ResolveResult();
}

/// The provider maps to a known adapter with a known base URL and key URL.
class Supported extends ResolveResult {
  const Supported(this.definition);
  final ProviderDefinition definition;
}

/// The provider's `npm` package is recognised, but models.dev doesn't give us
/// enough information to safely route it — typically because the provider has
/// no `api` URL in the catalog, so we can't prefill a base URL, and the `npm`
/// field alone doesn't declare a wire protocol. The button is shown disabled
/// with a tooltip pointing the user to the provider's docs.
class Uncertain extends ResolveResult {
  const Uncertain({required this.reason, required this.docsUrl});
  final String reason;
  final String? docsUrl;
}

/// No adapter fits this group at all (e.g. labs scope, or an `npm` we don't
/// recognise). The button is hidden entirely.
class Unsupported extends ResolveResult {
  const Unsupported();
}

/// Maps a models.dev [ProviderModels] group (the Providers-scope grouping the
/// Discover panel already caches) to the internal [ProviderDefinition] the
/// Quick-Add flow should prefill when the user taps "Add API key".
///
/// Routing is **evidence-based**: we only route to an adapter when we have
/// positive evidence the provider speaks that adapter's wire protocol. The
/// models.dev catalog exposes three fields per provider:
///
///   * `npm`  — the AI SDK package that implements the provider (a routing
///              hint, **not** a protocol declaration). e.g. `@ai-sdk/anthropic`
///              means the provider speaks Anthropic's Messages API;
///              `@ai-sdk/openai-compatible` means it speaks OpenAI's
///              `/v1/chat/completions`.
///   * `api`  — the provider's REST base URL. Only present on providers that
///              publish one (mostly the `@ai-sdk/openai-compatible` family and
///              OpenRouter). Absent on native-SDK providers (Google, Bedrock,
///              Azure, …) whose SDKs handle auth/routing internally.
///   * `doc`  — the provider's documentation URL. Used to derive a "get an
///              API key" link (origin of the docs) when no per-provider key
///              URL is known.
///
/// The catalog does **not** have a field that says "this provider speaks
/// OpenAI's `/v1/chat/completions`." The `npm` field is the closest signal,
/// and it's reliable only for the explicitly-named packages below. For
/// everything else we return [Uncertain] (button shown disabled) rather than
/// guess — see the README's "Provider routing" section for the full rationale.
ResolveResult resolveDefinitionFor(ProviderModels provider) {
  final String? npm = provider.npm;

  // Labs grouping — no `npm`, no single adapter. The plan keeps the Add button
  // Providers-scope-only.
  if (npm == null) return const Unsupported();

  switch (npm) {
    case '@ai-sdk/anthropic':
      // The `npm` tag means "speaks the Anthropic Messages API shape" — it
      // does NOT mean "is Anthropic". MiniMax, Kimi, FreeModel and others
      // proxy Claude's API shape but need a key from their own platforms.
      // Keep the hardcoded console URL only for the canonical provider;
      // for proxies derive the key link from the provider's doc origin.
      return Supported(
        _override(
          ProviderCatalog.byId('anthropic')!,
          provider,
          apiKeyUrl: provider.id == 'anthropic'
              ? 'https://console.anthropic.com/settings/keys'
              : (_originOf(provider.docUrl) ??
                    'https://console.anthropic.com/settings/keys'),
        ),
      );
    case '@ai-sdk/google':
      // Same pattern: the tag means "speaks the Gemini API shape". Only the
      // canonical `google` provider uses AI Studio for keys; any future
      // Gemini-compatible proxy would need its own key link derived from
      // its doc origin.
      return Supported(
        _override(
          ProviderCatalog.byId('gemini_native')!,
          provider,
          apiKeyUrl: provider.id == 'google'
              ? 'https://aistudio.google.com/app/apikey'
              : (_originOf(provider.docUrl) ??
                    'https://aistudio.google.com/app/apikey'),
        ),
      );
    // OpenAI-compatible packages — the package name itself declares the wire
    // protocol. These are the only `npm` values we treat as confirmed
    // OpenAI-compatible. We still require an `api` URL to prefill the base
    // URL; without one the button is disabled (Uncertain).
    case '@ai-sdk/openai-compatible':
    case '@openrouter/ai-sdk-provider':
    case '@ai-sdk/openai':
      return _openAiCompatibleOrUncertain(provider);
    // OpenAI-compatible providers with known base URLs. models.dev tags these
    // with their own SDK packages (e.g. `@ai-sdk/groq`) but doesn't publish an
    // `api` URL for them — the base URL is baked into the SDK package instead.
    // We maintain the equivalent fallback here so the button can be enabled.
    // See README "Provider routing" → "Known OpenAI-compatible fallback URLs".
    case '@ai-sdk/cerebras':
    case '@ai-sdk/cohere':
    case '@ai-sdk/deepinfra':
    case '@ai-sdk/groq':
    case '@ai-sdk/mistral':
    case '@ai-sdk/perplexity':
    case '@ai-sdk/togetherai':
    case '@ai-sdk/xai':
      return _openAiCompatibleWithFallback(provider, npm);
    // Recognised packages whose wire protocol or auth flow we can't confirm
    // from the catalog alone, and for which we have no known base URL. These
    // need their own adapters (Bedrock, Azure, Vertex, …) — disable rather
    // than guess.
    case '@ai-sdk/amazon-bedrock':
    case '@ai-sdk/azure':
    case '@ai-sdk/gateway':
    case '@ai-sdk/google-vertex':
    case '@ai-sdk/google-vertex/anthropic':
    case '@ai-sdk/vercel':
    case '@aihubmix/ai-sdk-provider':
    case '@jerome-benoit/sap-ai-provider-v2':
    case 'ai-gateway-provider':
    case 'gitlab-ai-provider':
    case 'merge-gateway-ai-sdk-provider':
    case 'venice-ai-sdk-provider':
      return Uncertain(
        reason:
            "models.dev tags this provider with '$npm', which we don't "
            'have a confirmed adapter for. The provider may be '
            'OpenAI-compatible, but the catalog does not declare a wire '
            'protocol or publish a base URL for it.',
        docsUrl: provider.docUrl,
      );
    default:
      return const Unsupported();
  }
}

/// Known base URLs for OpenAI-compatible providers that don't publish an `api`
/// URL in models.dev. These are the public endpoints each provider documents;
/// they're stable (they're the providers' public API roots, not internal
/// details) and mirror what the corresponding `@ai-sdk/*` packages hardcode.
///
/// If a provider *does* publish an `api` URL in the catalog, that takes
/// precedence over this fallback (see [_openAiCompatibleWithFallback]).
const Map<String, String> _knownOpenAiCompatibleUrls = <String, String>{
  '@ai-sdk/cerebras': 'https://api.cerebras.ai/v1',
  '@ai-sdk/cohere': 'https://api.cohere.ai/compatibility/v1',
  '@ai-sdk/deepinfra': 'https://api.deepinfra.com/v1/openai',
  '@ai-sdk/groq': 'https://api.groq.com/openai/v1',
  '@ai-sdk/mistral': 'https://api.mistral.ai/v1',
  '@ai-sdk/perplexity': 'https://api.perplexity.ai/v1',
  '@ai-sdk/togetherai': 'https://api.together.xyz/v1',
  '@ai-sdk/xai': 'https://api.x.ai/v1',
};

ResolveResult _openAiCompatibleWithFallback(
  ProviderModels provider,
  String npm,
) {
  final String baseUrl =
      (provider.apiUrl != null && provider.apiUrl!.isNotEmpty)
      ? provider.apiUrl!
      : (_knownOpenAiCompatibleUrls[npm] ?? '');
  if (baseUrl.isEmpty) {
    return Uncertain(
      reason:
          "This provider is tagged '$npm' (likely OpenAI-compatible) but "
          "models.dev doesn't publish a base URL for it and we don't have "
          'a known fallback. See the provider docs to configure manually.',
      docsUrl: provider.docUrl,
    );
  }
  final String? docOrigin = _originOf(provider.docUrl);
  final String apiKeyUrl = docOrigin ?? 'https://platform.openai.com/api-keys';
  return Supported(
    _override(
      ProviderCatalog.byId('openai_compatible')!,
      provider,
      apiKeyUrl: apiKeyUrl,
      baseUrlOverride: baseUrl,
    ),
  );
}

ResolveResult _openAiCompatibleOrUncertain(ProviderModels provider) {
  final String? api = provider.apiUrl;
  if (api == null || api.isEmpty) {
    return Uncertain(
      reason:
          'This provider is tagged OpenAI-compatible but models.dev '
          "doesn't publish a base URL for it, so we can't prefill the "
          'endpoint.',
      docsUrl: provider.docUrl,
    );
  }
  final String? docOrigin = _originOf(provider.docUrl);
  final String apiKeyUrl = docOrigin ?? 'https://platform.openai.com/api-keys';
  return Supported(
    _override(
      ProviderCatalog.byId('openai_compatible')!,
      provider,
      apiKeyUrl: apiKeyUrl,
    ),
  );
}

ProviderDefinition _override(
  ProviderDefinition base,
  ProviderModels provider, {
  required String apiKeyUrl,
  String? baseUrlOverride,
}) {
  final Map<String, Object?> template = Map<String, Object?>.from(
    base.configTemplate,
  );
  final String? url = baseUrlOverride ?? provider.apiUrl;
  if (url != null && url.isNotEmpty) {
    template['baseUrl'] = url;
  }
  return ProviderDefinition(
    id: base.id,
    kind: base.kind,
    displayName: base.displayName,
    description: base.description,
    configTemplate: template,
    requiresApiKey: base.requiresApiKey,
    requiresOAuth: base.requiresOAuth,
    apiKeyUrl: apiKeyUrl,
    modelsDevId: provider.id,
  );
}

/// Returns "scheme://host" of [url] (no path/query), or null if [url] is null
/// or unparseable. Used to derive an API-console link from a doc URL — most
/// providers host their key-management page on the same origin as their docs.
String? _originOf(String? url) {
  if (url == null || url.isEmpty) return null;
  final Uri? parsed = Uri.tryParse(url);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
    return null;
  }
  return '${parsed.scheme}://${parsed.host}';
}
