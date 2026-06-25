import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/services/web_retrieval/web_retrieval.dart';
import 'package:app/data/services/web_retrieval/web_search_tools.dart';

/// A minimal fake [WebRetrievalAdapter] that records calls and returns
/// canned data. Lets us test [WebSearchTools.execute] without any network.
class _FakeAdapter implements WebRetrievalAdapter {
  _FakeAdapter({this.searchResults = const [], this.fetchedPage});

  List<WebSearchResult> searchResults;
  FetchedPage? fetchedPage;

  String? lastSearchQuery;
  String? lastFetchUrl;

  @override
  String get kind => 'fake';

  @override
  Future<List<WebSearchResult>> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  }) async {
    lastSearchQuery = query;
    return searchResults;
  }

  @override
  Future<FetchedPage> fetch(
    String url, {
    FetchFormat format = FetchFormat.markdown,
  }) async {
    lastFetchUrl = url;
    return fetchedPage ??
        FetchedPage(
          url: url,
          title: 'Test Page',
          content: 'Hello world',
          contentType: 'text/markdown',
        );
  }
}

void main() {
  const WebSearchTools tools = WebSearchTools();

  group('WebSearchTools.definitions', () {
    test('exposes web_search and fetch_page tools', () {
      final names = tools.definitions.map((t) => t.name).toList();
      expect(names, containsAll(<String>['web_search', 'fetch_page']));
    });

    test('web_search requires a query argument', () {
      final search = tools.definitions.firstWhere(
        (t) => t.name == 'web_search',
      );
      final required = search.parameters['required'] as List;
      expect(required, contains('query'));
    });

    test('fetch_page requires a url argument', () {
      final fetch = tools.definitions.firstWhere((t) => t.name == 'fetch_page');
      final required = fetch.parameters['required'] as List;
      expect(required, contains('url'));
    });
  });

  group('WebSearchTools.execute — web_search', () {
    test('dispatches to adapter.search with the query', () async {
      final adapter = _FakeAdapter(
        searchResults: <WebSearchResult>[
          WebSearchResult(
            title: 'Rust SQLite',
            url: 'https://example.com/rust-sqlite',
            snippet: 'A guide to SQLite in Rust',
            provider: 'searxng',
          ),
        ],
      );

      final result = await tools.execute(
        name: 'web_search',
        args: jsonEncode(<String, dynamic>{'query': 'rust sqlite'}),
        adapter: adapter,
      );

      expect(adapter.lastSearchQuery, 'rust sqlite');
      expect(result, contains('Rust SQLite'));
      expect(result, contains('https://example.com/rust-sqlite'));
      expect(result, contains('A guide to SQLite in Rust'));
      expect(result, startsWith('1. '));
    });

    test('includes publication date when present', () async {
      final adapter = _FakeAdapter(
        searchResults: <WebSearchResult>[
          WebSearchResult(
            title: 'News',
            url: 'https://example.com/news',
            snippet: 'Breaking',
            publishedAt: DateTime.utc(2024, 6, 15),
            provider: 'exa',
          ),
        ],
      );

      final result = await tools.execute(
        name: 'web_search',
        args: jsonEncode(<String, dynamic>{'query': 'news'}),
        adapter: adapter,
      );

      expect(result, contains('published 2024-06-15'));
    });

    test('returns "No results" when adapter returns empty list', () async {
      final adapter = _FakeAdapter(searchResults: const <WebSearchResult>[]);

      final result = await tools.execute(
        name: 'web_search',
        args: jsonEncode(<String, dynamic>{'query': 'nothing'}),
        adapter: adapter,
      );

      expect(result, contains('No results found'));
    });

    test('returns error string when query is missing', () async {
      final adapter = _FakeAdapter();

      final result = await tools.execute(
        name: 'web_search',
        args: '{}',
        adapter: adapter,
      );

      expect(result, contains('missing "query"'));
      expect(adapter.lastSearchQuery, isNull);
    });

    test('handles malformed JSON args gracefully', () async {
      final adapter = _FakeAdapter();

      final result = await tools.execute(
        name: 'web_search',
        args: 'not valid json',
        adapter: adapter,
      );

      expect(result, contains('missing "query"'));
    });

    test('handles empty args string', () async {
      final adapter = _FakeAdapter();

      final result = await tools.execute(
        name: 'web_search',
        args: '',
        adapter: adapter,
      );

      expect(result, contains('missing "query"'));
    });
  });

  group('WebSearchTools.execute — fetch_page', () {
    test('dispatches to adapter.fetch with the url', () async {
      final adapter = _FakeAdapter(
        fetchedPage: FetchedPage(
          url: 'https://example.com/article',
          title: 'Article',
          content: 'Body text here',
          contentType: 'text/markdown',
        ),
      );

      final result = await tools.execute(
        name: 'fetch_page',
        args: jsonEncode(<String, dynamic>{
          'url': 'https://example.com/article',
        }),
        adapter: adapter,
      );

      expect(adapter.lastFetchUrl, 'https://example.com/article');
      expect(result, contains('Title: Article'));
      expect(result, contains('URL: https://example.com/article'));
      expect(result, contains('Body text here'));
    });

    test('truncates content over 8000 chars', () async {
      final longContent = 'A' * 10000;
      final adapter = _FakeAdapter(
        fetchedPage: FetchedPage(
          url: 'https://example.com/long',
          title: 'Long',
          content: longContent,
          contentType: 'text/markdown',
        ),
      );

      final result = await tools.execute(
        name: 'fetch_page',
        args: jsonEncode(<String, dynamic>{'url': 'https://example.com/long'}),
        adapter: adapter,
      );

      expect(result, contains('truncated'));
      expect(result, contains('2000 more chars'));
    });

    test('returns error string when url is missing', () async {
      final adapter = _FakeAdapter();

      final result = await tools.execute(
        name: 'fetch_page',
        args: '{}',
        adapter: adapter,
      );

      expect(result, contains('missing "url"'));
      expect(adapter.lastFetchUrl, isNull);
    });
  });

  group('WebSearchTools.execute — unknown tool', () {
    test('returns error string for unknown tool name', () async {
      final adapter = _FakeAdapter();

      final result = await tools.execute(
        name: 'not_a_tool',
        args: '{}',
        adapter: adapter,
      );

      expect(result, contains('unknown tool'));
      expect(result, contains('not_a_tool'));
    });
  });
}
