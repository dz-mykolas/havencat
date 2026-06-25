import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:app/data/services/web_retrieval/http_web_retrieval_adapter.dart';
import 'package:app/data/services/web_retrieval/web_retrieval.dart';

void main() {
  group('HttpWebRetrievalAdapter', () {
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

      final results = await adapter.search('rust sqlite');

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

    test('search throws WebRetrievalException on non-200', () async {
      final client = MockClient((_) async {
        return http.Response('Internal error', 500);
      });

      final adapter = HttpWebRetrievalAdapter(client: client);

      expect(
        () => adapter.search('test'),
        throwsA(isA<WebRetrievalException>()),
      );
    });

    test('search handles empty result list', () async {
      final client = MockClient((_) async {
        return http.Response(jsonEncode(<dynamic>[]), 200);
      });

      final adapter = HttpWebRetrievalAdapter(client: client);
      final results = await adapter.search('nothing');

      expect(results, isEmpty);
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

    test('fetch throws WebRetrievalException on non-200', () async {
      final client = MockClient((_) async {
        return http.Response('Not found', 404);
      });

      final adapter = HttpWebRetrievalAdapter(client: client);

      expect(
        () => adapter.fetch('https://example.com/missing'),
        throwsA(isA<WebRetrievalException>()),
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
        throwsA(isA<WebRetrievalException>()),
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

      expect(
        () => adapter.cleanupCache(),
        throwsA(isA<WebRetrievalException>()),
      );
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
