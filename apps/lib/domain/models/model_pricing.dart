/// Domain models for the public model database served by models.dev
/// (`https://models.dev/api.json`).
///
/// The remote payload is a JSON object keyed by provider id; each provider has
/// a `models` map keyed by model id. We flatten that into a list of
/// [PricedModel]s (each carrying its provider) plus a grouped [ModelsCatalog]
/// so the UI can render either a flat searchable list or per-provider sections.
///
/// All money figures are **USD per million tokens**, matching models.dev.
library;

/// Per-token cost breakdown for a model, in USD per million tokens.
///
/// Every field is optional because models.dev omits costs it doesn't have
/// (e.g. a free/open-weights model, or a model that doesn't bill caching
/// separately).
class ModelCost {
  const ModelCost({
    this.input,
    this.output,
    this.cacheRead,
    this.cacheWrite,
    this.reasoning,
  });

  factory ModelCost.fromJson(Map<String, Object?> json) {
    double? parse(String key) => (json[key] as num?)?.toDouble();
    return ModelCost(
      input: parse('input'),
      output: parse('output'),
      cacheRead: parse('cache_read'),
      cacheWrite: parse('cache_write'),
      reasoning: parse('reasoning'),
    );
  }

  /// Cost per million input (prompt) tokens.
  final double? input;

  /// Cost per million output (completion) tokens.
  final double? output;

  /// Cost per million cached-read tokens, if billed separately.
  final double? cacheRead;

  /// Cost per million cache-write tokens, if billed separately.
  final double? cacheWrite;

  /// Cost per million reasoning tokens, if billed separately.
  final double? reasoning;

  /// Whether we have at least an input or output price to show.
  bool get hasHeadlinePricing => input != null || output != null;

  /// True when the model is free on both input and output.
  bool get isFree => (input ?? 0) == 0 && (output ?? 0) == 0;
}

/// A single model entry from models.dev, flattened to carry its provider.
class PricedModel {
  const PricedModel({
    required this.id,
    required this.name,
    required this.providerId,
    required this.providerName,
    this.cost,
    this.contextLimit,
    this.outputLimit,
    this.inputModalities = const <String>[],
    this.outputModalities = const <String>[],
    this.reasoning = false,
    this.toolCall = false,
    this.attachment = false,
    this.openWeights = false,
    this.releaseDate,
    this.lastUpdated,
  });

  factory PricedModel.fromJson(
    Map<String, Object?> json, {
    required String providerId,
    required String providerName,
  }) {
    final Object? costJson = json['cost'];
    final Object? limitJson = json['limit'];
    final Object? modalitiesJson = json['modalities'];

    List<String> modality(String key) {
      if (modalitiesJson is Map<String, Object?>) {
        final Object? list = modalitiesJson[key];
        if (list is List) {
          return list.map((Object? e) => '$e').toList(growable: false);
        }
      }
      return const <String>[];
    }

    int? limit(String key) {
      if (limitJson is Map<String, Object?>) {
        return (limitJson[key] as num?)?.toInt();
      }
      return null;
    }

    return PricedModel(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['id'] ?? ''}',
      providerId: providerId,
      providerName: providerName,
      cost: costJson is Map<String, Object?>
          ? ModelCost.fromJson(costJson)
          : null,
      contextLimit: limit('context'),
      outputLimit: limit('output'),
      inputModalities: modality('input'),
      outputModalities: modality('output'),
      reasoning: json['reasoning'] == true,
      toolCall: json['tool_call'] == true,
      attachment: json['attachment'] == true,
      openWeights: json['open_weights'] == true,
      releaseDate: _parseDate(json['release_date']),
      lastUpdated: _parseDate(json['last_updated']),
    );
  }

  /// Wire id, e.g. `gpt-5.5`, `claude-sonnet-4-5`.
  final String id;

  /// Display name, e.g. "Claude Sonnet 4.5 (latest)".
  final String name;

  /// Owning provider id from models.dev, e.g. `anthropic`.
  final String providerId;

  /// Owning provider display name, e.g. "Anthropic".
  final String providerName;

  final ModelCost? cost;

  /// Maximum context window in tokens, if known.
  final int? contextLimit;

  /// Maximum output tokens, if known.
  final int? outputLimit;

  final List<String> inputModalities;
  final List<String> outputModalities;

  final bool reasoning;
  final bool toolCall;
  final bool attachment;
  final bool openWeights;

  final DateTime? releaseDate;
  final DateTime? lastUpdated;

  /// True when the model accepts image input.
  bool get supportsVision =>
      inputModalities.contains('image') || inputModalities.contains('video');

  /// Lower-cased haystack used for free-text search.
  String get searchIndex =>
      '$name $id $providerName $providerId'.toLowerCase();

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}

/// A provider grouping: the provider's display name plus its models.
class ProviderModels {
  const ProviderModels({
    required this.id,
    required this.name,
    required this.models,
  });

  final String id;
  final String name;
  final List<PricedModel> models;
}

/// The whole models.dev catalog, both flat and grouped by provider, plus the
/// timestamp it was fetched at (so the UI can show "updated X ago" / offline).
class ModelsCatalog {
  ModelsCatalog({required this.models, required this.fetchedAt})
    : providers = _group(models);

  /// Parses the raw `api.json` map (keyed by provider id) into a catalog.
  factory ModelsCatalog.fromApiJson(
    Map<String, Object?> json, {
    required DateTime fetchedAt,
  }) {
    final List<PricedModel> all = <PricedModel>[];
    for (final MapEntry<String, Object?> entry in json.entries) {
      final Object? provider = entry.value;
      if (provider is! Map<String, Object?>) continue;
      final String providerId = '${provider['id'] ?? entry.key}';
      final String providerName = '${provider['name'] ?? providerId}';
      final Object? models = provider['models'];
      if (models is! Map<String, Object?>) continue;
      for (final Object? model in models.values) {
        if (model is Map<String, Object?>) {
          all.add(
            PricedModel.fromJson(
              model,
              providerId: providerId,
              providerName: providerName,
            ),
          );
        }
      }
    }
    return ModelsCatalog(models: all, fetchedAt: fetchedAt);
  }

  /// Every model across every provider.
  final List<PricedModel> models;

  /// Models grouped by provider, sorted by provider name.
  final List<ProviderModels> providers;

  /// When this catalog was fetched from the network.
  final DateTime fetchedAt;

  bool get isEmpty => models.isEmpty;

  static List<ProviderModels> _group(List<PricedModel> models) {
    final Map<String, List<PricedModel>> byProvider =
        <String, List<PricedModel>>{};
    final Map<String, String> names = <String, String>{};
    for (final PricedModel m in models) {
      byProvider.putIfAbsent(m.providerId, () => <PricedModel>[]).add(m);
      names[m.providerId] = m.providerName;
    }
    final List<ProviderModels> result = byProvider.entries
        .map(
          (MapEntry<String, List<PricedModel>> e) => ProviderModels(
            id: e.key,
            name: names[e.key] ?? e.key,
            models: e.value..sort((PricedModel a, PricedModel b) {
              final DateTime? ad = a.releaseDate;
              final DateTime? bd = b.releaseDate;
              if (ad != null && bd != null) return bd.compareTo(ad);
              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            }),
          ),
        )
        .toList(growable: false);
    result.sort(
      (ProviderModels a, ProviderModels b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return result;
  }
}
