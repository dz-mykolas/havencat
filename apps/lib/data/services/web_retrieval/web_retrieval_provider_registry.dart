import 'web_retrieval.dart';

enum WebProviderConfiguration { none, apiKey, instanceUrl }

class WebSearchProviderDefinition {
  const WebSearchProviderDefinition({
    required this.kind,
    required this.displayName,
    required this.configuration,
    this.zeroConfiguration = false,
  });

  final String kind;
  final String displayName;
  final WebProviderConfiguration configuration;
  final bool zeroConfiguration;
}

class WebRetrievalProviderRegistry {
  const WebRetrievalProviderRegistry();

  static const List<WebSearchProviderDefinition> searchProviders =
      <WebSearchProviderDefinition>[
        WebSearchProviderDefinition(
          kind: 'exa',
          displayName: 'Exa',
          configuration: WebProviderConfiguration.apiKey,
          zeroConfiguration: true,
        ),
        WebSearchProviderDefinition(
          kind: 'brave',
          displayName: 'Brave Search',
          configuration: WebProviderConfiguration.apiKey,
        ),
        WebSearchProviderDefinition(
          kind: 'searxng',
          displayName: 'SearXNG',
          configuration: WebProviderConfiguration.instanceUrl,
        ),
      ];

  static const Set<String> fetchProviderKinds = <String>{
    'direct_http',
    'jina_reader',
    'exa',
  };

  List<ProviderSlotConfig> normalizeSearch(
    Iterable<ProviderSlotConfig> configured,
  ) {
    final List<ProviderSlotConfig> input = configured.toList();
    if (input.isEmpty) {
      return const <ProviderSlotConfig>[ProviderSlotConfig(kind: 'exa')];
    }
    final Set<String> seen = <String>{};
    return input.map((ProviderSlotConfig slot) {
      final String kind = slot.kind.trim().toLowerCase();
      final WebSearchProviderDefinition? definition = searchProviders
          .where((WebSearchProviderDefinition item) => item.kind == kind)
          .firstOrNull;
      if (definition == null) {
        throw FormatException('Unknown web search provider "$kind".');
      }
      if (!seen.add(kind)) {
        throw FormatException('Web search provider "$kind" is duplicated.');
      }
      final String? value = slot.secret?.trim();
      if (definition.configuration == WebProviderConfiguration.instanceUrl) {
        final Uri? uri = Uri.tryParse(value ?? '');
        if (uri == null ||
            !uri.hasAuthority ||
            !(uri.isScheme('https') || uri.isScheme('http'))) {
          throw FormatException(
            '$kind requires an HTTP or HTTPS instance URL.',
          );
        }
      }
      if (definition.configuration == WebProviderConfiguration.apiKey &&
          !definition.zeroConfiguration &&
          (value == null || value.isEmpty)) {
        throw FormatException('$kind requires an API key.');
      }
      return ProviderSlotConfig(
        kind: kind,
        secret: value?.isEmpty == true ? null : value,
      );
    }).toList();
  }

  List<ProviderSlotConfig> normalizeFetch(
    Iterable<ProviderSlotConfig> configured,
  ) {
    final List<ProviderSlotConfig> input = configured.toList();
    final Iterable<ProviderSlotConfig> effective = input.isEmpty
        ? const <ProviderSlotConfig>[
            ProviderSlotConfig(kind: 'direct_http'),
            ProviderSlotConfig(kind: 'jina_reader'),
          ]
        : input;
    final Set<String> seen = <String>{};
    return effective.map((ProviderSlotConfig slot) {
      final String kind = slot.kind.trim().toLowerCase();
      if (!fetchProviderKinds.contains(kind)) {
        throw FormatException('Unknown URL fetch provider "$kind".');
      }
      if (!seen.add(kind)) {
        throw FormatException('URL fetch provider "$kind" is duplicated.');
      }
      return ProviderSlotConfig(kind: kind, secret: slot.secret?.trim());
    }).toList();
  }
}
