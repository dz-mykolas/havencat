import 'package:flutter_test/flutter_test.dart';

import 'package:havencat/data/services/pricing/models_dev_service.dart';
import 'package:havencat/domain/models/model_pricing.dart';
import 'package:havencat/ui/pricing/pricing_viewmodel.dart';

/// Unit tests for [PricingViewModel]'s multi-step Discover state: provider
/// drill-in, "browse all", search, and sort. The catalog is built directly from
/// a hand-rolled `api.json`-shaped payload, so these never touch the network.
void main() {
  test('starts in overview, then Drills into a provider and back', () async {
    final PricingViewModel vm = await _vm();

    expect(vm.view, PricingView.overview);
    expect(vm.providers.map((ProviderModels p) => p.name),
        containsAll(<String>['Anthropic', 'OpenAI']));
    expect(vm.selectedProvider, isNull);

    vm.openProvider('anthropic');
    expect(vm.view, PricingView.provider);
    expect(vm.selectedProvider?.name, 'Anthropic');
    // Drilling into a provider shows that provider's models only.
    expect(
      vm.results.map((PricedModel m) => m.providerId).toSet(),
      <String>{'anthropic'},
    );

    vm.backToOverview();
    expect(vm.view, PricingView.overview);
    expect(vm.selectedProvider, isNull);
    // In overview there's no model list to render.
    expect(vm.results, isEmpty);
  });

  test('browse all shows every (provider, model) serving entry', () async {
    final PricingViewModel vm = await _vm();

    vm.showAll();
    expect(vm.view, PricingView.all);
    // Same model served by 2 providers => 2 cards (per-provider, no merging).
    expect(vm.results.length, 3);
    expect(
      vm.results.map((PricedModel m) => m.name).toSet(),
      <String>{'Claude Opus 4.5', 'GPT-5.5'},
    );
  });

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

    final List<double?> outs =
        vm.results.map((PricedModel m) => m.cost?.output).toList();
    for (int i = 1; i < outs.length; i++) {
      expect(outs[i] == null || outs[i - 1] == null || outs[i]! >= outs[i - 1]!,
          isTrue);
    }
  });
}

/// Builds a [PricingViewModel] primed with a tiny `api.json`-shaped catalog:
/// Anthropic serves `claude-opus-4-5`, OpenAI serves `gpt-5.5` AND a duplicate
/// `claude-opus-4-5` (same model, different provider) — exercising the
/// per-(provider, model) duplication the UI relies on. Awaits the constructor's
/// initial [PricingViewModel.load] so tests can read state synchronously.
Future<PricingViewModel> _vm() async {
  final DateTime now = DateTime(2026, 6, 20);
  final ModelsCatalog catalog =
      ModelsCatalog.fromApiJson(_payload, fetchedAt: now);
  final _StubModelsDevService service = _StubModelsDevService(catalog);
  final PricingViewModel vm = PricingViewModel(service);
  // Let the constructor's async `load()` complete before tests read state.
  await Future<void>.delayed(Duration.zero);
  return vm;
}

const Map<String, Object?> _payload = <String, Object?>{
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
