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

  /// Wire id, e.g. `gpt-5.5`, `claude-sonnet-4-5`, or namespaced like
  /// `openai/gpt-5.2` when served through a router.
  final String id;

  /// Display name, e.g. "Claude Sonnet 4.5 (latest)".
  final String name;

  /// Owning provider id from models.dev, e.g. `anthropic`.
  final String providerId;

  /// Owning provider display name, e.g. "Anthropic".
  final String providerName;

  /// The lab that actually owns the model — derived from the `lab/...`
  /// prefix on the model id when served through a router (OpenRouter,
  /// Requesty, etc.), falling back to [providerId] for first-party entries.
  /// Examples: `anthropic`, `openai`, `google`, `xai`, `meta`, `mistral`.
  String get lab {
    final String prefix = id.split('/').first;
    return prefix == id ? providerId : prefix;
  }

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
      '$name $id $providerName $providerId $lab'.toLowerCase();

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}

/// A grouping record: an id + display name + the models belonging to it.
///
/// Used for both [ModelsCatalog.providers] (grouped by hosting provider) and
/// [ModelsCatalog.labs] (grouped by the lab that actually owns each model).
class ProviderModels {
  const ProviderModels({
    required this.id,
    required this.name,
    required this.models,
    this.npm,
    this.apiUrl,
    this.docUrl,
  });

  final String id;
  final String name;
  final List<PricedModel> models;

  /// The `npm` adapter package this provider maps to in models.dev's data
  /// (e.g. `@ai-sdk/anthropic`, `@ai-sdk/openai-compatible`, `@ai-sdk/google`,
  /// `@ai-sdk/groq`, `@openrouter/ai-sdk-provider`). Only present on the
  /// providers grouping (sourced from the top-level `npm` field); always null
  /// on the labs grouping. The Quick-Add resolver uses this to pick the right
  /// internal `ProviderDefinition`.
  final String? npm;

  /// The provider's published API base URL (models.dev `api` field), e.g.
  /// `https://router.requesty.ai/v1`. Only present on the providers grouping.
  final String? apiUrl;

  /// The provider's documentation URL (models.dev `doc` field). The Quick-Add
  /// dialog uses this (stripped to its origin) as a fallback "Get an API key"
  /// link when no per-definition [ProviderDefinition.apiKeyUrl] is set.
  final String? docUrl;

  /// True when this group is a plan/subscription provider that should be
  /// hidden from the Discover grid.
  ///
  /// models.dev lists three families of plan-billed providers:
  ///
  ///   1. **Plans explicitly named** — `umans-ai-coding-plan`,
  ///      `alibaba-token-plan`, `xiaomi-token-plan-*`, `*-coding-plan`,
  ///      `tencent-tokenhub`, … These self-identify via their display [name]
  ///      containing "token plan", "coding plan", or "tokenhub" (case-
  ///      insensitive, with optional separators). Captured by branch 1
  ///      ([_planNameRe]). The id-suffix approach is too brittle because
  ///      regional variants (`alibaba-coding-plan-cn`,
  ///      `xiaomi-token-plan-cn`) end in `-cn` / `-sgp` / `-ams`, not
  ///      `-coding-plan`.
  ///
  ///   2. **Unbranded plan providers** — `gitlab` ("Duo Chat"),
  ///      `github-models`, `poolside`, `nova`, `zeldoc`, `iflowcn`. These
  ///      don't say "plan" anywhere, but they bill via subscription: every
  ///      served model publishes `cost: {input: 0, output: 0}` AND at least
  ///      one of those models is **closed-weights** (e.g. GitLab serves
  ///      `duo-chat-opus-4-5` at $0 — Claude Opus obviously isn't free, so
  ///      somebody's absorbing the cost via a plan). Captured by branch 2.
  ///
  /// Genuinely free providers (LMStudio, ModelScope, Meta's `llama` hub,
  /// Privatemode AI, Atomic Chat) all serve open-weights models at $0 — that
  /// is an accurate price, so branch 2 keeps them visible. Nebius ("Token
  /// Factory") is brand-named with "Token" but publishes real per-token
  /// prices, so branch 2 keeps it too.
  ///
  /// Either branch is sufficient to hide a group.
  bool get isPlanOnly {
    // Branch 1 — plans that self-identify by name. Regional suffix variants
    // like `xiaomi-token-plan-cn` end in `-cn`, not `-coding-plan`, so the id
    // suffix approach leaks them. Matching the display [name] catches every
    // known variant: "Token Plan", "Coding Plan", "TokenHub".
    if (_planNameRe.hasMatch(name)) return true;

    // Branch 2 — unbranded plan providers (GitLab Duo, GitHub Models,
    // Poolside, Nova, Zeldoc, iFlow) whose tell-tale is publishing $0 for
    // at least one closed-weights commercial model. An all-open-weights
    // provider at $0 is genuinely free (LMStudio, ModelScope, Meta's `llama`
    // hub, …) and stays visible.
    bool sawClosed = false;
    for (final PricedModel m in models) {
      final ModelCost? cost = m.cost;
      // A model with no cost data at all → we can't classify, keep the group.
      if (cost == null) return false;
      // Any real non-zero price → not a plan-only group.
      if ((cost.input ?? 0) > 0 || (cost.output ?? 0) > 0) return false;
      if (!m.openWeights) sawClosed = true;
    }
    return sawClosed;
  }

  /// Matches plan/subscription display names. Case-insensitive; allows any
  /// separator (space, dash, none) between the words so "Token Plan",
  /// "Token-Plan", "TokenPlan", and "Tokenhub" all match.
  static final RegExp _planNameRe = RegExp(
    r'(token[\s\-]?plan|coding[\s\-]?plan|tokenhub)',
    caseSensitive: false,
  );

  /// True when at least one model publishes a real (non-zero) per-token price
  /// — at least one of [ModelCost.input] or [ModelCost.output] is greater than
  /// zero. Kept as the inverse-positive form for callers that want "has any
  /// real price" rather than "is a plan-only group".
  bool get hasPricedModel {
    for (final PricedModel m in models) {
      final ModelCost? cost = m.cost;
      if (cost == null) continue;
      if ((cost.input ?? 0) > 0 || (cost.output ?? 0) > 0) return true;
    }
    return false;
  }
}

/// The whole models.dev catalog, both flat and grouped by provider, plus the
/// timestamp it was fetched at (so the UI can show "updated X ago" / offline).
class ModelsCatalog {
  ModelsCatalog({
    required this.models,
    required this.fetchedAt,
    Map<String, ProviderMeta>? providerMeta,
  })  : providers = _group(models, providerMeta: providerMeta),
        labs = _groupByLab(models),
        _providerMeta = providerMeta ?? const <String, ProviderMeta>{};

  /// Parses the raw `api.json` map (keyed by provider id) into a catalog.
  factory ModelsCatalog.fromApiJson(
    Map<String, Object?> json, {
    required DateTime fetchedAt,
  }) {
    final List<PricedModel> all = <PricedModel>[];
    final Map<String, ProviderMeta> meta = <String, ProviderMeta>{};
    for (final MapEntry<String, Object?> entry in json.entries) {
      final Object? provider = entry.value;
      if (provider is! Map<String, Object?>) continue;
      final String providerId = '${provider['id'] ?? entry.key}';
      final String providerName = '${provider['name'] ?? providerId}';
      meta[providerId] = ProviderMeta(
        npm: provider['npm'] as String?,
        apiUrl: provider['api'] as String?,
        docUrl: provider['doc'] as String?,
      );
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
    return ModelsCatalog(
      models: all,
      fetchedAt: fetchedAt,
      providerMeta: meta,
    );
  }

  /// Every model across every provider.
  final List<PricedModel> models;

  /// Models grouped by hosting provider (the API you actually call), sorted
  /// by provider name — e.g. OpenRouter, OpenAI, Anthropic, Qiniu.
  final List<ProviderModels> providers;

  /// Models grouped by the lab that actually owns them. For routed models the
  /// lab is the `lab/model` id prefix (e.g. `anthropic` for
  /// `anthropic/claude-sonnet-4-5` served via OpenRouter); for first-party
  /// entries it's just the provider. Same underlying model served through 3
  /// different routers collapses into one lab's tile.
  final List<ProviderModels> labs;

  /// When this catalog was fetched from the network.
  final DateTime fetchedAt;

  /// Per-provider metadata (npm/api/doc fields from models.dev), keyed by
  /// provider id. Used to populate the [providers] grouping's `npm`/`apiUrl`/
  /// `docUrl`; the labs grouping has no equivalent (the lab prefix is on the
  /// model id, not the provider).
  final Map<String, ProviderMeta> _providerMeta;

  /// Looks up the [ProviderMeta] for [providerId], if any.
  ProviderMeta? metaFor(String providerId) => _providerMeta[providerId];

  bool get isEmpty => models.isEmpty;

  static List<ProviderModels> _group(
    List<PricedModel> models, {
    Map<String, ProviderMeta>? providerMeta,
  }) {
    final Map<String, List<PricedModel>> byKey =
        <String, List<PricedModel>>{};
    final Map<String, String> names = <String, String>{};
    for (final PricedModel m in models) {
      byKey.putIfAbsent(m.providerId, () => <PricedModel>[]).add(m);
      names[m.providerId] = m.providerName;
    }
    final List<ProviderModels> result = byKey.entries
        .map(
          (MapEntry<String, List<PricedModel>> e) {
            final ProviderMeta? pm = providerMeta?[e.key];
            return ProviderModels(
              id: e.key,
              name: names[e.key] ?? _titleCaseId(e.key),
              models: e.value..sort(_modelSortByDateThenName),
              npm: pm?.npm,
              apiUrl: pm?.apiUrl,
              docUrl: pm?.docUrl,
            );
          },
        )
        .toList(growable: false);
    result.sort(_groupSortByName);
    return result;
  }

  static List<ProviderModels> _groupByLab(List<PricedModel> models) {
    final Map<String, List<PricedModel>> byLab =
        <String, List<PricedModel>>{};
    for (final PricedModel m in models) {
      byLab.putIfAbsent(m.lab, () => <PricedModel>[]).add(m);
    }
    final Map<String, String> names = <String, String>{};
    final List<ProviderModels> result = byLab.entries
        .map(
          (MapEntry<String, List<PricedModel>> e) => ProviderModels(
            id: e.key,
            name: names[e.key] ?? _titleCaseId(e.key),
            models: e.value..sort(_modelSortByDateThenName),
          ),
        )
        .toList(growable: false);
    result.sort(_groupSortByName);
    return result;
  }

  static int _modelSortByDateThenName(PricedModel a, PricedModel b) {
    final DateTime? ad = a.releaseDate;
    final DateTime? bd = b.releaseDate;
    if (ad != null && bd != null) return bd.compareTo(ad);
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  static int _groupSortByName(ProviderModels a, ProviderModels b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  /// Turns a hyphen/underscore id like `openai` or `x-ai` into "OpenAI" / "X-AI"
  /// for users when no friendly name was provided (the labs branch).
  static String _titleCaseId(String id) {
    final List<String> parts = id.replaceAll('_', '-').split('-');
    return parts
        .map(
          (String p) => p.isEmpty
              ? p
              : '${p[0].toUpperCase()}${p.substring(1).toLowerCase()}',
        )
        .join('-');
  }
}

/// Raw adapter/endpoint fields models.dev publishes per provider, kept around
/// after catalog construction so the Quick-Add resolver can pick the right
/// internal [ProviderDefinition] (via [npm]) and prefill base URL + doc link.
class ProviderMeta {
  const ProviderMeta({this.npm, this.apiUrl, this.docUrl});

  final String? npm;
  final String? apiUrl;
  final String? docUrl;
}
