import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:app/data/services/web_retrieval/http_web_retrieval_adapter.dart';
import 'package:app/data/services/web_retrieval/web_retrieval.dart';
import 'package:app/domain/errors/app_failure.dart';

void main() {
  group('HttpWebRetrievalAdapter', () {
    test('configureProviders sends runtime provider configuration', () async {
      late Map<String, dynamic> body;
      final client = MockClient((http.Request request) async {
        expect(request.method, 'POST');
        expect(request.url.path, endsWith('/api/retrieval/configure'));
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      });
      final HttpWebRetrievalAdapter adapter = HttpWebRetrievalAdapter(
        client: client,
      );

      await adapter.configureProviders(
        searchProviders: const <ProviderSlotConfig>[
          ProviderSlotConfig(
            kind: 'searxng',
            secret: 'secret',
            endpoint: 'https://search.example.com',
          ),
        ],
        fetchProviders: const <ProviderSlotConfig>[
          ProviderSlotConfig(kind: 'direct_http'),
        ],
      );

      expect(
        ((body['search_providers'] as List).single as Map)['kind'],
        'searxng',
      );
      expect(
        ((body['search_providers'] as List).single as Map)['secret'],
        'secret',
      );
      expect(
        ((body['search_providers'] as List).single as Map)['endpoint'],
        'https://search.example.com',
      );
    });

    test('search maps /api/search JSON to List<WebSearchResult>', () async {
      final client = MockClient((request) async {
        expect(request.url.path, endsWith('/api/search'));
        expect(request.url.queryParameters['q'], 'rust sqlite');
        expect(request.url.queryParameters['num'], '5');
        return http.Response(
          jsonEncode(<Map<String, dynamic>>[
            <String, dynamic>{
              'title': 'Rust + SQLite',
              'url': 'https://example.com/rust',
              'snippet': 'A guide',
              'provider': 'searxng',
              'published_at': 1700000000,
            },
            <String, dynamic>{
              'title': 'Another',
              'url': 'https://example.com/2',
              'snippet': 'Snip',
              'provider': 'exa',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final adapter = HttpWebRetrievalAdapter(
        baseUrl: 'http://localhost:8080',
        client: client,
      );

      final response = await adapter.search('rust sqlite');
      final results = response.results;

      expect(results.length, 2);
      expect(results[0].title, 'Rust + SQLite');
      expect(results[0].url, 'https://example.com/rust');
      expect(results[0].snippet, 'A guide');
      expect(results[0].provider, 'searxng');
      expect(results[0].publishedAt, isNotNull);
      expect(results[0].publishedAt!.millisecondsSinceEpoch, 1700000000);
      expect(results[1].title, 'Another');
      expect(results[1].provider, 'exa');
      expect(results[1].publishedAt, isNull);
    });

    test('search respects numResults option', () async {
      String? capturedNum;
      final client = MockClient((request) async {
        capturedNum = request.url.queryParameters['num'];
        return http.Response(jsonEncode(<dynamic>[]), 200);
      });

      final adapter = HttpWebRetrievalAdapter(client: client);
      await adapter.search(
        'test',
        options: const WebSearchOptions(numResults: 10),
      );

      expect(capturedNum, '10');
    });

    test('search throws AppFailure on non-200', () async {
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 'network',
              'message': 'SearXNG could not search the web.',
              'provider': 'searxng',
              'detail': 'connection refused',
            },
          }),
          503,
        );
      });

      final adapter = HttpWebRetrievalAdapter(client: client);
      final Future<WebSearchResponse> search = adapter.search('test');

      await expectLater(
        search,
        throwsA(
          isA<AppFailure>()
              .having(
                (AppFailure failure) => failure.message,
                'message',
                'SearXNG could not search the web.',
              )
              .having(
                (AppFailure failure) => failure.safeDetail,
                'safeDetail',
                'connection refused',
              )
              .having(
                (AppFailure failure) => failure.source.providerId,
                'provider',
                'searxng',
              ),
        ),
      );
    });

    test('search handles empty result list', () async {
      final client = MockClient((_) async {
        return http.Response(jsonEncode(<dynamic>[]), 200);
      });

      final adapter = HttpWebRetrievalAdapter(client: client);
      final response = await adapter.search('nothing');

      expect(response.results, isEmpty);
    });

    test('search maps provider issues and successful providers', () async {
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Object?>[],
            'issues': <Object?>[
              <String, Object?>{
                'provider': 'brave',
                'kind': 'rate_limited',
                'detail': 'rate limited by provider brave',
                'retry_after_seconds': 30,
              },
            ],
            'successful_providers': <String>['exa'],
          }),
          200,
        );
      });

      final WebSearchResponse response = await HttpWebRetrievalAdapter(
        client: client,
      ).search('nothing');

      expect(response.successfulProviders, <String>['exa']);
      expect(response.issues.single.provider, 'brave');
      expect(response.issues.single.detail, 'rate limited by provider brave');
      expect(response.issues.single.retryAfter, const Duration(seconds: 30));
    });

    test('fetch maps /api/fetch JSON to FetchedPage', () async {
      final client = MockClient((request) async {
        expect(request.url.path, endsWith('/api/fetch'));
        expect(request.url.queryParameters['url'], 'https://example.com/page');
        expect(request.url.queryParameters['format'], 'markdown');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'url': 'https://example.com/page',
            'title': 'Page Title',
            'content': '# Heading\n\nBody text.',
            'content_type': 'text/markdown',
          }),
          200,
        );
      });

      final adapter = HttpWebRetrievalAdapter(
        baseUrl: 'http://localhost:8080',
        client: client,
      );

      final page = await adapter.fetch('https://example.com/page');

      expect(page.url, 'https://example.com/page');
      expect(page.title, 'Page Title');
      expect(page.content, '# Heading\n\nBody text.');
      expect(page.contentType, 'text/markdown');
    });

    test('fetch passes format query parameter', () async {
      String? capturedFormat;
      final client = MockClient((request) async {
        capturedFormat = request.url.queryParameters['format'];
        return http.Response(
          jsonEncode(<String, dynamic>{
            'url': '',
            'title': '',
            'content': '',
            'content_type': '',
          }),
          200,
        );
      });

      final adapter = HttpWebRetrievalAdapter(client: client);
      await adapter.fetch('https://x.com', format: FetchFormat.text);

      expect(capturedFormat, 'text');
    });

    test('fetch throws AppFailure on non-200', () async {
      final client = MockClient((_) async {
        return http.Response('Not found', 404);
      });

      final adapter = HttpWebRetrievalAdapter(client: client);

      expect(
        () => adapter.fetch('https://example.com/missing'),
        throwsA(isA<AppFailure>()),
      );
    });

    test(
      'cacheSearchPages maps /api/cache/search to List<FetchedPage>',
      () async {
        final client = MockClient((request) async {
          expect(request.url.path, endsWith('/api/cache/search'));
          expect(request.url.queryParameters['q'], 'sqlite');
          expect(request.url.queryParameters['limit'], '10');
          return http.Response(
            jsonEncode(<Map<String, dynamic>>[
              <String, dynamic>{
                'url': 'https://example.com/cached',
                'title': 'Cached Page',
                'content': 'Cached content',
                'content_type': 'text/markdown',
              },
            ]),
            200,
          );
        });

        final adapter = HttpWebRetrievalAdapter(
          baseUrl: 'http://localhost:8080',
          client: client,
        );

        final pages = await adapter.cacheSearchPages('sqlite');

        expect(pages.length, 1);
        expect(pages[0].title, 'Cached Page');
        expect(pages[0].content, 'Cached content');
      },
    );

    test('cacheSearchPages throws on non-200', () async {
      final client = MockClient((_) async {
        return http.Response('error', 500);
      });

      final adapter = HttpWebRetrievalAdapter(client: client);

      expect(
        () => adapter.cacheSearchPages('test'),
        throwsA(isA<AppFailure>()),
      );
    });

    test('cleanupCache sends POST to /api/cache/cleanup', () async {
      String? capturedMethod;
      final client = MockClient((request) async {
        capturedMethod = request.method;
        return http.Response('', 204);
      });

      final adapter = HttpWebRetrievalAdapter(client: client);
      await adapter.cleanupCache();

      expect(capturedMethod, 'POST');
    });

    test('cleanupCache throws on non-204', () async {
      final client = MockClient((_) async {
        return http.Response('error', 500);
      });

      final adapter = HttpWebRetrievalAdapter(client: client);

      expect(() => adapter.cleanupCache(), throwsA(isA<AppFailure>()));
    });

    test('strips trailing slashes from baseUrl', () {
      final adapter = HttpWebRetrievalAdapter(
        baseUrl: 'http://localhost:8080///',
      );
      expect(adapter.baseUrl, 'http://localhost:8080');
    });

    test('kind is "http"', () {
      final adapter = HttpWebRetrievalAdapter(
        client: MockClient((_) async => http.Response('', 200)),
      );
      expect(adapter.kind, 'http');
    });
  });
}
