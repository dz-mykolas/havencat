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
  Map<String, int>? _byCanonicalId;
  Map<String, int>? _byModelIdSuffix;
  List<MapEntry<String, int>>? _byFuzzy;

  /// Resolves the context window for [model] served by [providerId].
  ///
  /// [providerId] is the models.dev provider id (e.g. `openai`,
  /// `anthropic`). When null, only canonical/fuzzy matches are attempted.
  int? resolve(String modelId, {String? providerId}) {
    _ensureIndex();

    // 1. Exact provider-model match.
    if (providerId != null) {
      for (final PricedModel pm in _catalog.providers.expand((p) => p.models)) {
        if (pm.providerId == providerId && pm.id == modelId) {
          if (pm.contextLimit != null) return pm.contextLimit;
        }
      }
    }

    // 2. Canonical match by full canonical id (`<lab>/<model>`).
    final int? canonical = _byCanonicalId?[modelId];
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
      final int? withLab = _byCanonicalId?['$lab/$modelId'];
      if (withLab != null) return withLab;
    }

    // 3. Match by model id suffix (the part after the last `/`).
    final String suffix = modelId.split('/').last;
    final int? bySuffix = _byModelIdSuffix?[suffix];
    if (bySuffix != null) return bySuffix;

    // 4. Fuzzy: case-insensitive contains on the canonical id.
    final String lower = modelId.toLowerCase();
    for (final MapEntry<String, int> entry in _byFuzzy!) {
      if (entry.key.contains(lower) || lower.contains(entry.key)) {
        return entry.value;
      }
    }

    return null;
  }

  /// Enriches a list of [LlmModel]s with context windows from the catalog.
  ///
  /// Returns new [LlmModel] instances with [LlmModel.contextWindow] populated
  /// when a match is found. Models that already have a context window or that
  /// don't match the catalog are returned unchanged.
  List<LlmModel> enrich(Iterable<LlmModel> models, {String? providerId}) {
    _ensureIndex();
    return models.map((LlmModel m) {
      if (m.contextWindow != null) return m;
      final int? ctx = resolve(m.id, providerId: providerId);
      if (ctx == null) return m;
      return LlmModel(
        id: m.id,
        displayName: m.displayName,
        hidden: m.hidden,
        contextWindow: ctx,
      );
    }).toList();
  }

  void _ensureIndex() {
    if (_byCanonicalId != null) return;

    final Map<String, int> byCanonical = <String, int>{};
    final Map<String, int> bySuffix = <String, int>{};
    final List<MapEntry<String, int>> fuzzy = <MapEntry<String, int>>[];

    for (final PricedModel pm in _catalog.models) {
      if (pm.contextLimit == null) continue;
      // Canonical id is `<lab>/<model>` — but PricedModel.id is just the
      // model part. Reconstruct the full canonical key.
      final String fullId = '${pm.labId}/${pm.id}';
      byCanonical[fullId] = pm.contextLimit!;
      byCanonical[pm.id] = pm.contextLimit!;
      bySuffix[pm.id] = pm.contextLimit!;
      fuzzy.add(MapEntry<String, int>(pm.id.toLowerCase(), pm.contextLimit!));
    }

    _byCanonicalId = byCanonical;
    _byModelIdSuffix = bySuffix;
    _byFuzzy = fuzzy;
  }
}
