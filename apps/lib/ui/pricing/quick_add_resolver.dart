import '../../domain/models/model_pricing.dart';
import '../../domain/models/provider_definition.dart';

/// Maps a models.dev [ProviderModels] group (the Providers-scope grouping the
/// Discover panel already caches) to the internal [ProviderDefinition] the
/// Quick-Add flow should prefill when the user taps "Add API key".
///
/// Returns a *derived* definition — the catalog definition with its
/// `configTemplate.baseUrl` overridden by the group's own `api` URL (so
/// OpenRouter prefills `https://openrouter.ai/api/v1`, Qiniu prefills its
/// host, …) and `apiKeyUrl` set to a per-provider console link when known,
/// otherwise derived from the group's `doc` URL stripped to its origin.
///
/// Returns `null` when no adapter fits the group:
///   * labs scope ([ProviderModels.npm] is null — the labs grouping has no
///     `npm` field, so there's no single adapter for "all of xAI's models"),
///   * or the group has no API URL and no resolvable `npm` (defensive — every
///     known models.dev provider today has at least one of the two).
///
/// The Add button on the Discover panel calls this; a `null` return hides the
/// button for that group. The resolver is a pure function so it's trivially
/// unit-testable without a Flutter binding.
ProviderDefinition? resolveDefinitionFor(ProviderModels provider) {
  final String? npm = provider.npm;

  // Labs grouping — no `npm`, no single adapter. The plan keeps the Add button
  // Providers-scope-only.
  if (npm == null) return null;

  switch (npm) {
    case '@ai-sdk/anthropic':
      return _override(
        ProviderCatalog.byId('anthropic')!,
        provider,
        apiKeyUrl: 'https://console.anthropic.com/settings/keys',
      );
    case '@ai-sdk/google':
    case '@ai-sdk/google-vertex':
      return _override(
        ProviderCatalog.byId('gemini_native')!,
        provider,
        apiKeyUrl: 'https://aistudio.google.com/app/apikey',
      );
    default:
      // Per-provider doc origin wins over the generic OpenAI key page because
      // routers like OpenRouter host their own key console at the doc origin.
      final String? docOrigin = _originOf(provider.docUrl);
      final String apiKeyUrl =
          docOrigin ?? 'https://platform.openai.com/api-keys';
      if (npm.contains('openai-compatible') ||
          npm.startsWith('@ai-sdk/groq') ||
          npm.startsWith('@ai-sdk/mistral') ||
          npm.startsWith('@ai-sdk/xai') ||
          npm.startsWith('@ai-sdk/perplexity') ||
          npm.startsWith('@ai-sdk/cohere') ||
          npm.startsWith('@ai-sdk/togetherai') ||
          npm.startsWith('@ai-sdk/deepinfra') ||
          npm.startsWith('@ai-sdk/cerebras') ||
          npm.startsWith('@openrouter/ai-sdk-provider') ||
          npm.startsWith('@ai-sdk/openai') // native OpenAI + most routers
          ) {
        return _override(
          ProviderCatalog.byId('openai_compatible')!,
          provider,
          apiKeyUrl: apiKeyUrl,
        );
      }
      // Unrecognised SDK — fall back to OpenAI-compatible (every models.dev
      // provider that publishes an `npm` is OpenAI-compatible REST today),
      // but only when we have an API URL to prefill. Otherwise hide.
      if (provider.apiUrl == null) return null;
      return _override(
        ProviderCatalog.byId('openai_compatible')!,
        provider,
        apiKeyUrl: apiKeyUrl,
      );
  }
}

ProviderDefinition _override(
  ProviderDefinition base,
  ProviderModels provider, {
  required String apiKeyUrl,
}) {
  final Map<String, Object?> template =
      Map<String, Object?>.from(base.configTemplate);
  if (provider.apiUrl != null && provider.apiUrl!.isNotEmpty) {
    template['baseUrl'] = provider.apiUrl;
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
