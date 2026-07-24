import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app/data/services/auth/secret_store.dart';
import 'package:app/data/services/web_retrieval/web_retrieval.dart';
import 'package:app/data/services/web_retrieval/web_search_settings.dart';
import 'package:app/domain/errors/app_failure.dart';

class _ConfigurableAdapter
    implements WebRetrievalAdapter, WebRetrievalConfigurator {
  List<ProviderSlotConfig> searchProviders = const <ProviderSlotConfig>[];
  List<ProviderSlotConfig> fetchProviders = const <ProviderSlotConfig>[];

  @override
  String get kind => 'test';

  @override
  Future<void> configureProviders({
    required List<ProviderSlotConfig> searchProviders,
    required List<ProviderSlotConfig> fetchProviders,
  }) async {
    this.searchProviders = searchProviders;
    this.fetchProviders = fetchProviders;
  }

  @override
  Future<WebSearchResponse> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  }) async => const WebSearchResponse(results: <WebSearchResult>[]);

  @override
  Future<FetchedPage> fetch(
    String url, {
    FetchFormat format = FetchFormat.markdown,
  }) async =>
      FetchedPage(url: url, title: '', content: '', contentType: 'text/plain');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('initializes with keyless Exa and default fetch providers', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final _ConfigurableAdapter adapter = _ConfigurableAdapter();
    final WebSearchSettings settings = WebSearchSettings(
      preferences: preferences,
      secrets: SecretStore(),
      adapter: adapter,
    );

    await settings.initialize();

    expect(adapter.searchProviders.single.kind, 'exa');
    expect(adapter.searchProviders.single.secret, isNull);
    expect(
      adapter.fetchProviders.map((ProviderSlotConfig item) => item.kind),
      <String>['direct_http', 'jina_reader'],
    );
  });

  test('persists Brave key securely and reapplies it after reload', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final SecretStore secrets = SecretStore();
    final _ConfigurableAdapter firstAdapter = _ConfigurableAdapter();
    final WebSearchSettings first = WebSearchSettings(
      preferences: preferences,
      secrets: secrets,
      adapter: firstAdapter,
    );
    await first.initialize();

    await first.saveProvider(
      kind: 'brave',
      enabled: true,
      apiKey: 'brave-secret',
    );

    final _ConfigurableAdapter secondAdapter = _ConfigurableAdapter();
    final WebSearchSettings second = WebSearchSettings(
      preferences: preferences,
      secrets: secrets,
      adapter: secondAdapter,
    );
    await second.initialize();

    expect(second.preferenceFor('brave').enabled, isTrue);
    expect(second.preferenceFor('brave').hasApiKey, isTrue);
    expect(
      secondAdapter.searchProviders
          .firstWhere((ProviderSlotConfig item) => item.kind == 'brave')
          .secret,
      'brave-secret',
    );
  });

  test('persists and applies a SearXNG URL and access token', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final SecretStore secrets = SecretStore();
    final WebSearchSettings first = WebSearchSettings(
      preferences: preferences,
      secrets: secrets,
      adapter: _ConfigurableAdapter(),
    );
    await first.initialize();

    await first.saveProvider(
      kind: 'searxng',
      enabled: true,
      apiKey: 'access-token',
      instanceUrl: 'https://search.example.com',
    );

    final _ConfigurableAdapter secondAdapter = _ConfigurableAdapter();
    final WebSearchSettings second = WebSearchSettings(
      preferences: preferences,
      secrets: secrets,
      adapter: secondAdapter,
    );
    await second.initialize();

    final ProviderSlotConfig searxng = secondAdapter.searchProviders.firstWhere(
      (ProviderSlotConfig item) => item.kind == 'searxng',
    );
    expect(second.preferenceFor('searxng').hasApiKey, isTrue);
    expect(searxng.endpoint, 'https://search.example.com');
    expect(searxng.secret, 'access-token');
  });

  test('does not allow disabling every provider', () async {
    final WebSearchSettings settings = WebSearchSettings(
      preferences: await SharedPreferences.getInstance(),
      secrets: SecretStore(),
      adapter: _ConfigurableAdapter(),
    );
    await settings.initialize();

    await expectLater(
      settings.setEnabled('exa', false),
      throwsA(
        isA<AppFailure>().having(
          (AppFailure failure) => failure.kind,
          'kind',
          FailureKind.invalidRequest,
        ),
      ),
    );
    expect(settings.preferenceFor('exa').enabled, isTrue);
  });
}
