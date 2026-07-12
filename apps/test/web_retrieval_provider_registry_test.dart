import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/services/web_retrieval/web_retrieval.dart';
import 'package:app/data/services/web_retrieval/web_retrieval_provider_registry.dart';

void main() {
  const WebRetrievalProviderRegistry registry = WebRetrievalProviderRegistry();

  test('uses keyless Exa when no search provider is configured', () {
    final List<ProviderSlotConfig> providers = registry.normalizeSearch(
      const <ProviderSlotConfig>[],
    );

    expect(providers, hasLength(1));
    expect(providers.single.kind, 'exa');
    expect(providers.single.secret, isNull);
  });

  test('accepts optional Exa key and keyed Brave', () {
    final List<ProviderSlotConfig> providers = registry
        .normalizeSearch(const <ProviderSlotConfig>[
          ProviderSlotConfig(kind: 'EXA', secret: ' exa-key '),
          ProviderSlotConfig(kind: 'brave', secret: ' brave-key '),
        ]);

    expect(providers.map((ProviderSlotConfig item) => item.kind), <String>[
      'exa',
      'brave',
    ]);
    expect(providers.last.secret, 'brave-key');
  });

  test('requires a Brave key', () {
    expect(
      () => registry.normalizeSearch(const <ProviderSlotConfig>[
        ProviderSlotConfig(kind: 'brave'),
      ]),
      throwsFormatException,
    );
  });

  test('requires an explicit SearXNG instance URL', () {
    expect(
      () => registry.normalizeSearch(const <ProviderSlotConfig>[
        ProviderSlotConfig(kind: 'searxng'),
      ]),
      throwsFormatException,
    );
    expect(
      registry
          .normalizeSearch(const <ProviderSlotConfig>[
            ProviderSlotConfig(
              kind: 'searxng',
              secret: 'https://search.example.com',
            ),
          ])
          .single
          .secret,
      'https://search.example.com',
    );
  });

  test('rejects unknown and duplicate providers', () {
    expect(
      () => registry.normalizeSearch(const <ProviderSlotConfig>[
        ProviderSlotConfig(kind: 'unknown'),
      ]),
      throwsFormatException,
    );
    expect(
      () => registry.normalizeSearch(const <ProviderSlotConfig>[
        ProviderSlotConfig(kind: 'exa'),
        ProviderSlotConfig(kind: 'exa'),
      ]),
      throwsFormatException,
    );
  });
}
