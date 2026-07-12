import '../../../domain/models/content_modality.dart';
import '../../../domain/models/llm_model.dart';
import '../../../domain/models/model_pricing.dart';

/// Resolves the context window (in tokens) for a model by cross-referencing
/// the models.dev catalog.
///
/// The catalog carries `contextLimit` (parsed from `limit.context` in
/// `catalog.json`) on both canonical models (keyed by `<lab>/<model-id>`)
/// and per-provider serving entries. We try several lookup strategies in
/// order of specificity:
///
/// 1. Exact provider-model match (provider id + model id).
/// 2. Canonical model match by lab + model id.
/// 3. Canonical model match by model id suffix (ignoring the lab prefix).
/// 4. Fuzzy match on the model id (case-insensitive contains).
///
/// Returns null when no match is found — callers fall back to
/// [kFallbackContextWindow].
class ModelContextResolver {
  ModelContextResolver(this._catalog);

  final ModelsCatalog _catalog;

  /// Pre-built index for fast lookups. Built lazily on first use.
  Map<String, PricedModel>? _byCanonicalId;
  Map<String, PricedModel>? _byModelIdSuffix;
  List<MapEntry<String, PricedModel>>? _byFuzzy;

  /// Resolves the context window for [model] served by [providerId].
  ///
  /// [providerId] is the models.dev provider id (e.g. `openai`,
  /// `anthropic`). When null, only canonical/fuzzy matches are attempted.
  int? resolve(String modelId, {String? providerId}) {
    return resolveModel(modelId, providerId: providerId)?.contextLimit;
  }

  /// Resolves the full catalog record so callers can use limits, modalities,
  /// and feature flags from the same match.
  PricedModel? resolveModel(String modelId, {String? providerId}) {
    _ensureIndex();

    // 1. Exact provider-model match.
    if (providerId != null) {
      for (final PricedModel pm in _catalog.providers.expand((p) => p.models)) {
        if (pm.providerId == providerId && pm.id == modelId) {
          return pm;
        }
      }
    }

    // 2. Canonical match by full canonical id (`<lab>/<model>`).
    final PricedModel? canonical = _byCanonicalId?[modelId];
    if (canonical != null) return canonical;

    // Also try with common lab prefixes if the bare id didn't match.
    for (final String lab in const <String>[
      'openai',
      'anthropic',
      'google',
      'meta',
      'mistral',
      'deepseek',
      'qwen',
      'cohere',
      'amazon',
      'microsoft',
    ]) {
      final PricedModel? withLab = _byCanonicalId?['$lab/$modelId'];
      if (withLab != null) return withLab;
    }

    // 3. Match by model id suffix (the part after the last `/`).
    final String suffix = modelId.split('/').last;
    final PricedModel? bySuffix = _byModelIdSuffix?[suffix];
    if (bySuffix != null) return bySuffix;

    // 4. Fuzzy: case-insensitive contains on the canonical id.
    final String lower = modelId.toLowerCase();
    for (final MapEntry<String, PricedModel> entry in _byFuzzy!) {
      if (entry.key.contains(lower) || lower.contains(entry.key)) {
        return entry.value;
      }
    }

    return null;
  }

  /// Enriches models with context limits, modalities, and feature flags.
  ///
  /// Existing provider-supplied values win; unmatched models stay unchanged.
  List<LlmModel> enrich(Iterable<LlmModel> models, {String? providerId}) {
    _ensureIndex();
    return models.map((LlmModel m) {
      final PricedModel? match = resolveModel(m.id, providerId: providerId);
      if (match == null) return m;
      final Set<ContentModality> input = match.inputModalities
          .map(ContentModality.tryParse)
          .whereType<ContentModality>()
          .toSet();
      final Set<ContentModality> output = match.outputModalities
          .map(ContentModality.tryParse)
          .whereType<ContentModality>()
          .toSet();
      return LlmModel(
        id: m.id,
        displayName: m.displayName,
        hidden: m.hidden,
        contextWindow: m.contextWindow ?? match.contextLimit,
        capabilities:
            m.capabilities ??
            ModelCapabilities(
              input: input,
              output: output,
              reasoning: match.reasoning,
              toolCalling: match.toolCall,
              attachments: match.attachment,
            ),
      );
    }).toList();
  }

  void _ensureIndex() {
    if (_byCanonicalId != null) return;

    final Map<String, PricedModel> byCanonical = <String, PricedModel>{};
    final Map<String, PricedModel> bySuffix = <String, PricedModel>{};
    final List<MapEntry<String, PricedModel>> fuzzy =
        <MapEntry<String, PricedModel>>[];

    for (final PricedModel pm in _catalog.models) {
      final String fullId = pm.id.contains('/')
          ? pm.id
          : '${pm.labId}/${pm.id}';
      final String suffix = pm.id.split('/').last;
      byCanonical[fullId] = pm;
      byCanonical[suffix] = pm;
      bySuffix[suffix] = pm;
      fuzzy.add(MapEntry<String, PricedModel>(suffix.toLowerCase(), pm));
    }

    _byCanonicalId = byCanonical;
    _byModelIdSuffix = bySuffix;
    _byFuzzy = fuzzy;
  }
}
