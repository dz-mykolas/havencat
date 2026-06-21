import 'package:flutter_test/flutter_test.dart';

import 'package:havencat/data/services/pricing/models_dev_service.dart';
import 'package:havencat/domain/models/model_pricing.dart';
import 'package:havencat/ui/pricing/pricing_viewmodel.dart';
import 'package:havencat/ui/pricing/quick_add_resolver.dart';

/// Unit tests for [PricingViewModel]'s multi-step Discover state: provider
/// drill-in, "browse all", search, and sort. The catalog is built directly from
/// a hand-rolled `api.json`-shaped payload, so these never touch the network.
void main() {
  test('starts in overview, then Drills into a provider and back', () async {
    final PricingViewModel vm = await _vm();

    expect(vm.view, PricingView.overview);
    expect(
      vm.providers.map((ProviderModels p) => p.name),
      containsAll(<String>['Anthropic', 'OpenAI']),
    );
    expect(vm.selectedProvider, isNull);

    vm.openProvider('anthropic');
    expect(vm.view, PricingView.provider);
    expect(vm.selectedProvider?.name, 'Anthropic');
    // Drilling into a provider shows that provider's models only.
    expect(vm.results.map((PricedModel m) => m.providerId).toSet(), <String>{
      'anthropic',
    });

    vm.backToOverview();
    expect(vm.view, PricingView.overview);
    expect(vm.selectedProvider, isNull);
    // In overview there's no model list to render.
    expect(vm.results, isEmpty);
  });

  test(
    'browse all shows every canonical model (no provider duplication)',
    () async {
      final PricingViewModel vm = await _vm();

      vm.showAll();
      expect(vm.view, PricingView.all);
      // The Models tab mirrors models.dev's canonical registry: one entry per
      // underlying model, regardless of how many providers serve it. The test
      // payload has two canonical models (`anthropic/claude-opus-4-5` and
      // `openai/gpt-5.5`), so that's what shows — not the 3 per-provider cards.
      expect(vm.results.length, 2);
      expect(vm.results.map((PricedModel m) => m.name).toSet(), <String>{
        'Claude Opus 4.5',
        'GPT-5.5',
      });
    },
  );

  test('search filters within the provider view', () async {
    final PricingViewModel vm = await _vm();
    vm.openProvider('openai');

    vm.setQuery('gpt');
    expect(vm.results.map((PricedModel m) => m.id), <String>['gpt-5.5']);
    expect(vm.query, 'gpt');

    vm.clearQuery();
    // OpenAI serves two models in the test payload (gpt-5.5 + a duplicate
    // claude-opus-4-5), so clearing the query shows both again.
    expect(vm.results.length, 2);
  });

  test('opening a provider clears any prior search query', () async {
    final PricingViewModel vm = await _vm();
    vm.showAll();
    vm.setQuery('gpt');
    expect(vm.query, 'gpt');

    vm.openProvider('anthropic');
    expect(vm.query, '');
  });

  test('sort by price low ranks cheaper output first', () async {
    final PricingViewModel vm = await _vm();
    vm.showAll();
    vm.setSort(PricingSort.priceLow);

    final List<double?> outs = vm.results
        .map((PricedModel m) => m.cost?.output)
        .toList();
    for (int i = 1; i < outs.length; i++) {
      expect(
        outs[i] == null || outs[i - 1] == null || outs[i]! >= outs[i - 1]!,
        isTrue,
      );
    }
  });

  test('each scope keeps its own search query across tab switches', () async {
    final PricingViewModel vm = await _vm();

    // Providers tab starts selected; type a provider-filtering query.
    expect(vm.scope, PricingScope.providers);
    vm.setQuery('open');
    expect(vm.query, 'open');

    // Switch to Models — different query, different domain.
    vm.setScope(PricingScope.models);
    expect(vm.query, ''); // Models tab starts with its own empty query.
    vm.setQuery('gpt');
    expect(vm.query, 'gpt');

    // Back to Providers — the "open" query is preserved.
    vm.setScope(PricingScope.providers);
    expect(vm.query, 'open');

    // And Models still has "gpt" when we return.
    vm.setScope(PricingScope.models);
    expect(vm.query, 'gpt');
  });

  test(
    'models scope renders every model flat, filtered by its query',
    () async {
      final PricingViewModel vm = await _vm();
      vm.setScope(PricingScope.models);
      expect(vm.isFlatModelView, isTrue);
      // No query -> all models.
      expect(vm.results.length, vm.totalCount);

      vm.setQuery('gpt');
      expect(vm.results.map((PricedModel m) => m.id), <String>[
        'openai/gpt-5.5',
      ]);
    },
  );

  test(
    'fuzzy search tolerates separator and spacing variants (gpt5.5, …)',
    () async {
      final PricingViewModel vm = await _vm();
      vm.setScope(PricingScope.models);

      // The canonical model is `openai/gpt-5.5` named "GPT-5.5". Plain
      // substring search would miss all of these; fuzzy matching (Bitap +
      // tokenize) should find the same model regardless of how the user
      // separates the version digits.
      for (final String q in <String>['gpt5.5', 'gpt 5.5', 'gpt-5.5']) {
        vm.setQuery(q);
        final List<String> ids = vm.results
            .map((PricedModel m) => m.id)
            .toList();
        expect(ids, contains('openai/gpt-5.5'), reason: 'query "$q"');
      }
    },
  );

  test('fuzzy search does not surface unrelated models on near-miss version '
      'queries (gpt 5.4 ≠ GLM-5.2 / gpt-5.5 Instant)', () async {
    final PricingViewModel vm = await _vm();
    vm.setScope(PricingScope.models);

    // "gpt 5.4" must not match `gpt-5.5 Instant` (only the "gpt" token
    // matches, and matchAllTokens requires both) nor `GLM-5.2` (no "gpt"
    // token at all). With the small test payload there is no `gpt-5.4`, so
    // the result set should be empty.
    vm.setQuery('gpt 5.4');
    expect(vm.results, isEmpty);
  });

  test('overview grid filters groups by the scope query', () async {
    final PricingViewModel vm = await _vm();
    vm.setScope(PricingScope.providers);

    // No query -> all providers (Anthropic + OpenAI in the test payload).
    expect(vm.groups.map((ProviderModels g) => g.id).toSet(), <String>{
      'anthropic',
      'openai',
    });

    vm.setQuery('anthropic');
    // Only the Anthropic group matches the query.
    expect(vm.groups.map((ProviderModels g) => g.id).toSet(), <String>{
      'anthropic',
    });
  });

  /// Tests for [resolveDefinitionFor] — the pure mapping from a models.dev
  /// provider group to the internal `ProviderDefinition` the Quick-Add flow
  /// prefills. Three branches of the resolver are covered here: anthropic-shaped
  /// groups, openrouter-shaped groups (openai-compatible fallback with a
  /// provider-specific base URL), and labs-scope groups (no `npm`, no adapter).
  group('resolveDefinitionFor', () {
    final DateTime now = DateTime(2026, 6, 20);

    test('anthropic npm -> anthropic definition, baseUrl from group', () {
      final ProviderModels group = ModelsCatalog.fromCatalogJson(
        _anthropicPayload,
        fetchedAt: now,
      ).providers.first;
      expect(group.npm, '@ai-sdk/anthropic');
      expect(group.apiUrl, 'https://api.anthropic.com');

      final def = resolveDefinitionFor(group);
      expect(def, isNotNull);
      expect(def!.id, 'anthropic');
      // Base URL overridden from models.dev `api` field, not the template.
      expect(def.configTemplate['baseUrl'], 'https://api.anthropic.com');
      expect(def.apiKeyUrl, 'https://console.anthropic.com/settings/keys');
      expect(def.modelsDevId, 'anthropic');
    });

    test(
      'openrouter npm -> openai_compatible definition with router baseUrl',
      () {
        final ProviderModels group = ModelsCatalog.fromCatalogJson(
          _openRouterPayload,
          fetchedAt: now,
        ).providers.first;
        expect(group.npm, '@openrouter/ai-sdk-provider');
        expect(group.apiUrl, 'https://openrouter.ai/api/v1');

        final def = resolveDefinitionFor(group);
        expect(def, isNotNull);
        expect(def!.id, 'openai_compatible');
        expect(def.configTemplate['baseUrl'], 'https://openrouter.ai/api/v1');
        // apiKeyUrl derived from the doc URL's origin.
        expect(def.apiKeyUrl, 'https://openrouter.ai');
        expect(def.modelsDevId, 'openrouter');
      },
    );

    test('labs-scope group (no npm) -> null (no adapter)', () {
      // Build a labs grouping: the canonical `anthropic/claude-opus-4-5`
      // model ends up under the `anthropic` lab prefix, with no `npm`/`api`/
      // `doc` on the lab group (labs come from catalog.models, not providers).
      final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
        _openRouterPayload,
        fetchedAt: now,
      );
      expect(catalog.labs, isNotEmpty);
      final ProviderModels lab = catalog.labs.first;
      expect(lab.npm, isNull);

      expect(resolveDefinitionFor(lab), isNull);
    });
  });
}

const Map<String, Object?> _anthropicPayload = <String, Object?>{
  'models': <String, Object?>{},
  'providers': <String, Object?>{
    'anthropic': <String, Object?>{
      'id': 'anthropic',
      'name': 'Anthropic',
      'npm': '@ai-sdk/anthropic',
      'api': 'https://api.anthropic.com',
      'doc': 'https://docs.anthropic.com',
      'models': <String, Object?>{
        'claude-opus-4-5': <String, Object?>{
          'id': 'claude-opus-4-5',
          'name': 'Claude Opus 4.5',
          'cost': <String, Object?>{'input': 5, 'output': 25},
        },
      },
    },
  },
};

const Map<String, Object?> _openRouterPayload = <String, Object?>{
  'models': <String, Object?>{
    'anthropic/claude-opus-4-5': <String, Object?>{
      'id': 'anthropic/claude-opus-4-5',
      'name': 'Claude Opus 4.5',
    },
  },
  'providers': <String, Object?>{
    'openrouter': <String, Object?>{
      'id': 'openrouter',
      'name': 'OpenRouter',
      'npm': '@openrouter/ai-sdk-provider',
      'api': 'https://openrouter.ai/api/v1',
      'doc': 'https://openrouter.ai/docs',
      'models': <String, Object?>{
        'anthropic/claude-opus-4-5': <String, Object?>{
          'id': 'anthropic/claude-opus-4-5',
          'name': 'Claude Opus 4.5',
          'cost': <String, Object?>{'input': 5, 'output': 25},
        },
      },
    },
  },
};

/// Builds a [PricingViewModel] primed with a tiny `api.json`-shaped catalog:
/// Anthropic serves `claude-opus-4-5`, OpenAI serves `gpt-5.5` AND a duplicate
/// `claude-opus-4-5` (same model, different provider) — exercising the
/// per-(provider, model) duplication the UI relies on. Awaits the constructor's
/// initial [PricingViewModel.load] so tests can read state synchronously.
Future<PricingViewModel> _vm() async {
  final DateTime now = DateTime(2026, 6, 20);
  final ModelsCatalog catalog = ModelsCatalog.fromCatalogJson(
    _payload,
    fetchedAt: now,
  );
  final _StubModelsDevService service = _StubModelsDevService(catalog);
  final PricingViewModel vm = PricingViewModel(service);
  // Let the constructor's async `load()` complete before tests read state.
  await Future<void>.delayed(Duration.zero);
  return vm;
}

const Map<String, Object?> _payload = <String, Object?>{
  'models': <String, Object?>{
    'anthropic/claude-opus-4-5': <String, Object?>{
      'id': 'anthropic/claude-opus-4-5',
      'name': 'Claude Opus 4.5',
      'family': 'claude-opus',
      'reasoning': true,
      'tool_call': true,
      'release_date': '2025-11-24',
      'modalities': <String, Object?>{
        'input': <String>['text', 'image'],
        'output': <String>['text'],
      },
      'limit': <String, Object?>{'context': 200000, 'output': 64000},
      'cost': <String, Object?>{'input': 5, 'output': 25},
    },
    'openai/gpt-5.5': <String, Object?>{
      'id': 'openai/gpt-5.5',
      'name': 'GPT-5.5',
      'release_date': '2026-04-23',
      'limit': <String, Object?>{'context': 1050000, 'output': 128000},
      'cost': <String, Object?>{'input': 3, 'output': 18},
      'tool_call': true,
    },
  },
  'providers': <String, Object?>{
    'anthropic': <String, Object?>{
      'id': 'anthropic',
      'name': 'Anthropic',
      'models': <String, Object?>{
        'claude-opus-4-5': <String, Object?>{
          'id': 'claude-opus-4-5',
          'name': 'Claude Opus 4.5',
          'family': 'claude-opus',
          'reasoning': true,
          'tool_call': true,
          'release_date': '2025-11-24',
          'modalities': <String, Object?>{
            'input': <String>['text', 'image'],
            'output': <String>['text'],
          },
          'limit': <String, Object?>{'context': 200000, 'output': 64000},
          'cost': <String, Object?>{'input': 5, 'output': 25},
        },
      },
    },
    'openai': <String, Object?>{
      'id': 'openai',
      'name': 'OpenAI',
      'models': <String, Object?>{
        'gpt-5.5': <String, Object?>{
          'id': 'gpt-5.5',
          'name': 'GPT-5.5',
          'release_date': '2026-04-23',
          'limit': <String, Object?>{'context': 1050000, 'output': 128000},
          'cost': <String, Object?>{'input': 3, 'output': 18},
          'tool_call': true,
        },
        // Same underlying model served by OpenAI too => should appear as a
        // separate per-provider card, not be merged away.
        'claude-opus-4-5': <String, Object?>{
          'id': 'claude-opus-4-5',
          'name': 'Claude Opus 4.5',
          'release_date': '2025-11-24',
          'cost': <String, Object?>{'input': 6, 'output': 30},
        },
      },
    },
  },
};

/// A [ModelsDevService] stand-in that returns a fixed catalog, so the view
/// model is testable without Dio/network. Only `load()` is exercised here.
class _StubModelsDevService extends ModelsDevService {
  _StubModelsDevService(this._catalog) : super();

  final ModelsCatalog _catalog;

  @override
  Future<ModelsCatalog> load({bool forceRefresh = false}) async => _catalog;

  @override
  Future<ModelsCatalog> refresh() async => _catalog;
}
