import 'package:flutter_test/flutter_test.dart';

import 'package:app/domain/models/model_pricing.dart';

/// Tests for [ModelsCatalog.fromCatalogJson] — the simple iteration + `split("/")`
/// approach to building the three Discover tabs (Models / Providers / Labs)
/// from models.dev's `catalog.json`.
///
/// `catalog.json` bundles two sections, each backing one tab:
///   - `models`: canonical model registry keyed by `<lab>/<model-id>`. This is
///     the source of truth for the **Models** tab (flat list) and the **Labs**
///     tab (grouped by the `lab/` prefix — 18 labs on models.dev).
///   - `providers`: per-provider serving entries. Source of truth for the
///     **Providers** tab.
///
/// No regex or canonical resolution is performed — just plain iteration and
/// `split("/")` on the canonical model id prefix.
void main() {
  final DateTime now = DateTime(2026, 6, 21);

  group('Providers tab (from catalog.providers)', () {
    test('router-served id keeps its lab prefix on the provider entry', () {
      final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
        _catalogWith(openaiGpt55: true),
        fetchedAt: now,
      );
      // OpenRouter serves `openai/gpt-5.5` — lab is `openai`.
      final PricedModel m = _findInProviders(catalog, providerId: 'openrouter');
      expect(m.labId, 'openai');
      expect(m.displayName, 'GPT-5.5');
    });

    test('first-party entry falls back to provider id as lab', () {
      final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
        _catalogWith(openaiGpt55: true),
        fetchedAt: now,
      );
      // OpenAI serves `gpt-5.5` (no `/`) — lab falls back to provider id.
      final PricedModel m = _findInProviders(catalog, providerId: 'openai');
      expect(m.labId, 'openai');
      expect(m.displayName, 'GPT-5.5');
    });

    test('dash-mangled id falls back to provider id as lab', () {
      final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
        _catalogWith(openaiGpt55: true),
        fetchedAt: now,
      );
      // digitalocean serves `openai-gpt-5.5` — no `/`, lab is `digitalocean`.
      final PricedModel m = _findInProviders(
        catalog,
        providerId: 'digitalocean',
      );
      expect(m.labId, 'digitalocean');
      expect(m.displayName, 'GPT-5.5');
    });

    test('provider-renamed display name is preserved as-is', () {
      final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
        _catalogWith(openaiGpt55: true),
        fetchedAt: now,
      );
      // venice serves `openai-gpt-55` named "GPT 5.5" (space, no dash) —
      // the serving name wins for display.
      final PricedModel m = _findInProviders(catalog, providerId: 'venice');
      expect(m.labId, 'venice');
      expect(m.name, 'GPT 5.5');
      expect(m.displayName, 'GPT 5.5');
    });

    test('providers grouping carries npm/api/doc metadata', () {
      final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
        _catalogWith(anthropicClaude: true),
        fetchedAt: now,
      );
      ProviderModels? p;
      for (final ProviderModels x in catalog.providers) {
        if (x.id == 'anthropic') {
          p = x;
          break;
        }
      }
      expect(p, isNotNull);
      expect(p!.npm, '@ai-sdk/anthropic');
      expect(p.apiUrl, 'https://api.anthropic.com');
      expect(p.docUrl, 'https://docs.anthropic.com');
    });
  });

  group('Labs tab (from catalog.models)', () {
    test('labs are derived from canonical model id prefixes only', () {
      final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
        _catalogWith(openaiGpt55: true),
        fetchedAt: now,
      );
      // The canonical registry has one entry: `openai/gpt-5.5`. So there is
      // exactly one lab: `openai`. The five provider entries (openai,
      // openrouter, digitalocean, neon, venice, xpersona) do NOT spawn extra
      // labs — they're serving entries, not canonical models.
      expect(catalog.labs.length, 1);
      final ProviderModels lab = catalog.labs.first;
      expect(lab.id, 'openai');
      expect(lab.models.length, 1);
      expect(lab.models.first.id, 'openai/gpt-5.5');
    });

    test('labs grouping uses title-cased id as name', () {
      final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
        _catalogWith(anthropicClaude: true),
        fetchedAt: now,
      );
      final ProviderModels? anthropicLab = _lab(catalog, 'anthropic');
      expect(anthropicLab, isNotNull);
      expect(anthropicLab!.name, 'Anthropic');
    });

    test('canonical models carry their lab id', () {
      final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
        _catalogWith(anthropicClaude: true),
        fetchedAt: now,
      );
      final PricedModel m = catalog.labs.first.models.first;
      expect(m.labId, 'anthropic');
      expect(m.id, 'anthropic/claude-opus-4-5');
      expect(m.displayName, 'Claude Opus 4.5');
    });
  });
}

/// Builds a `catalog.json`-shaped payload. Each flag toggles a model family
/// on so tests stay readable.
Map<String, Object?> _catalogWith({
  bool openaiGpt55 = false,
  bool anthropicClaude = false,
}) {
  final Map<String, Object?> models = <String, Object?>{};
  final Map<String, Object?> providers = <String, Object?>{};

  if (openaiGpt55) {
    models['openai/gpt-5.5'] = _canonicalModel('openai/gpt-5.5', 'GPT-5.5');
    providers['openai'] = _provider(
      'openai',
      'OpenAI',
      models: <String, Object?>{'gpt-5.5': _servingModel('gpt-5.5', 'GPT-5.5')},
    );
    providers['openrouter'] = _provider(
      'openrouter',
      'OpenRouter',
      models: <String, Object?>{
        'openai/gpt-5.5': _servingModel('openai/gpt-5.5', 'GPT-5.5'),
      },
    );
    providers['digitalocean'] = _provider(
      'digitalocean',
      'DigitalOcean',
      models: <String, Object?>{
        'openai-gpt-5.5': _servingModel('openai-gpt-5.5', 'GPT-5.5'),
      },
    );
    providers['neon'] = _provider(
      'neon',
      'Neon',
      models: <String, Object?>{'gpt-5-5': _servingModel('gpt-5-5', 'GPT-5.5')},
    );
    providers['venice'] = _provider(
      'venice',
      'Venice',
      models: <String, Object?>{
        'openai-gpt-55': _servingModel('openai-gpt-55', 'GPT 5.5'),
      },
    );
    providers['xpersona'] = _provider(
      'xpersona',
      'XPersona',
      models: <String, Object?>{
        'xpersona-gpt-5.5': _servingModel('xpersona-gpt-5.5', 'GPT-5.5'),
      },
    );
  }

  if (anthropicClaude) {
    models['anthropic/claude-opus-4-5'] = _canonicalModel(
      'anthropic/claude-opus-4-5',
      'Claude Opus 4.5',
    );
    providers['anthropic'] = _provider(
      'anthropic',
      'Anthropic',
      npm: '@ai-sdk/anthropic',
      api: 'https://api.anthropic.com',
      doc: 'https://docs.anthropic.com',
      models: <String, Object?>{
        'claude-opus-4-5': _servingModel('claude-opus-4-5', 'Claude Opus 4.5'),
      },
    );
    providers['openrouter'] = _provider(
      'openrouter',
      'OpenRouter',
      models: <String, Object?>{
        'anthropic/claude-opus-4-5': _servingModel(
          'anthropic/claude-opus-4-5',
          'Claude Opus 4.5',
        ),
      },
    );
  }

  return <String, Object?>{'models': models, 'providers': providers};
}

Map<String, Object?> _canonicalModel(String id, String name) =>
    <String, Object?>{'id': id, 'name': name};

Map<String, Object?> _provider(
  String id,
  String name, {
  Map<String, Object?>? models,
  String? npm,
  String? api,
  String? doc,
}) => <String, Object?>{
  'id': id,
  'name': name,
  'npm': ?npm,
  'api': ?api,
  'doc': ?doc,
  'models': ?models,
};

Map<String, Object?> _servingModel(String id, String name) => <String, Object?>{
  'id': id,
  'name': name,
  'cost': <String, Object?>{'input': 3, 'output': 18},
};

PricedModel _findInProviders(
  ModelsCatalog catalog, {
  required String providerId,
}) {
  // `catalog.models` is the canonical registry (no per-provider entries), so
  // look inside the providers grouping instead.
  for (final ProviderModels p in catalog.providers) {
    if (p.id == providerId) return p.models.first;
  }
  throw StateError('No model for provider $providerId in catalog');
}

ProviderModels? _lab(ModelsCatalog catalog, String labId) {
  for (final ProviderModels lab in catalog.labs) {
    if (lab.id == labId) return lab;
  }
  return null;
}
