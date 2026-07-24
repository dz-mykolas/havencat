import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/services/web_retrieval/web_retrieval.dart';
import 'package:app/data/services/web_retrieval/web_retrieval_endpoint_policy.dart';
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

  test('requires a SearXNG instance address', () {
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
              endpoint: 'https://search.example.com',
              secret: ' access-token ',
            ),
          ])
          .single
          .endpoint,
      'https://search.example.com',
    );
    expect(
      registry
          .normalizeSearch(const <ProviderSlotConfig>[
            ProviderSlotConfig(
              kind: 'searxng',
              endpoint: 'https://search.example.com',
              secret: ' access-token ',
            ),
          ])
          .single
          .secret,
      'access-token',
    );
  });

  test('rejects a bare SearXNG hostname', () {
    expect(
      () => registry.normalizeSearch(const <ProviderSlotConfig>[
        ProviderSlotConfig(kind: 'searxng', endpoint: 'search.dzmykolas.place'),
      ]),
      throwsFormatException,
    );
  });

  test('defaults only strict loopback addresses to HTTP', () {
    expect(
      WebRetrievalEndpointPolicy.defaultSchemeForAddress('localhost:8080'),
      'http',
    );
    expect(
      WebRetrievalEndpointPolicy.defaultSchemeForAddress('127.0.0.1:8080'),
      'http',
    );
    expect(
      WebRetrievalEndpointPolicy.defaultSchemeForAddress('192.168.1.20:8080'),
      'https',
    );
    expect(
      WebRetrievalEndpointPolicy.defaultSchemeForAddress('searxng.local'),
      'https',
    );
    expect(
      WebRetrievalEndpointPolicy.defaultSchemeForAddress(
        'search.dzmykolas.place',
      ),
      'https',
    );
  });

  test('enforces secure SearXNG transport by endpoint scope', () {
    expect(
      () => registry.normalizeSearch(const <ProviderSlotConfig>[
        ProviderSlotConfig(
          kind: 'searxng',
          endpoint: 'http://search.example.com',
        ),
      ]),
      throwsFormatException,
    );
    expect(
      registry
          .normalizeSearch(const <ProviderSlotConfig>[
            ProviderSlotConfig(
              kind: 'searxng',
              endpoint: 'http://192.168.1.20:8080',
            ),
          ])
          .single
          .endpoint,
      'http://192.168.1.20:8080',
    );
    expect(
      () => registry.normalizeSearch(const <ProviderSlotConfig>[
        ProviderSlotConfig(
          kind: 'searxng',
          endpoint: 'http://searxng.local',
          secret: 'access-token',
        ),
      ]),
      throwsFormatException,
    );
    expect(
      registry
          .normalizeSearch(const <ProviderSlotConfig>[
            ProviderSlotConfig(
              kind: 'searxng',
              endpoint: 'http://localhost:8080',
              secret: 'access-token',
            ),
          ])
          .single
          .endpoint,
      'http://localhost:8080',
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
