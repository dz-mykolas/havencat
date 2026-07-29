import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/services/web_retrieval/web_retrieval.dart';
import 'package:app/data/services/web_retrieval/web_search_tools.dart';
import 'package:app/domain/errors/app_failure.dart';
import 'package:app/domain/models/web_search_result_payload.dart';

/// A minimal fake [WebRetrievalAdapter] that records calls and returns
/// canned data. Lets us test [WebSearchTools.execute] without any network.
class _FakeAdapter implements WebRetrievalAdapter {
  _FakeAdapter({
    this.searchResults = const <WebSearchResult>[],
    this.searchIssues = const <WebProviderIssue>[],
    this.successfulProviders = const <String>[],
    this.fetchedPage,
  });

  List<WebSearchResult> searchResults;
  List<WebProviderIssue> searchIssues;
  List<String> successfulProviders;
  FetchedPage? fetchedPage;

  String? lastSearchQuery;
  String? lastFetchUrl;

  @override
  String get kind => 'fake';

  @override
  Future<WebSearchResponse> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  }) async {
    lastSearchQuery = query;
    return WebSearchResponse(
      results: searchResults,
      issues: searchIssues,
      successfulProviders: successfulProviders,
    );
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
      final WebSearchResultPayload payload = WebSearchResultPayload.decode(
        result.content,
      );
      expect(payload.query, 'rust sqlite');
      expect(payload.results.single.title, 'Rust SQLite');
      expect(payload.results.single.url, 'https://example.com/rust-sqlite');
      expect(payload.results.single.snippet, 'A guide to SQLite in Rust');
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

      final WebSearchResultPayload payload = WebSearchResultPayload.decode(
        result.content,
      );
      expect(payload.results.single.publishedAt, DateTime.utc(2024, 6, 15));
    });

    test('returns "No results" when adapter returns empty list', () async {
      final adapter = _FakeAdapter(searchResults: const <WebSearchResult>[]);

      final result = await tools.execute(
        name: 'web_search',
        args: jsonEncode(<String, dynamic>{'query': 'nothing'}),
        adapter: adapter,
      );

      final WebSearchResultPayload payload = WebSearchResultPayload.decode(
        result.content,
      );
      expect(payload.query, 'nothing');
      expect(payload.results, isEmpty);
    });

    test('throws a structured failure when query is missing', () async {
      final adapter = _FakeAdapter();

      await expectLater(
        tools.execute(name: 'web_search', args: '{}', adapter: adapter),
        throwsA(
          isA<AppFailure>().having(
            (AppFailure failure) => failure.kind,
            'kind',
            FailureKind.invalidRequest,
          ),
        ),
      );
      expect(adapter.lastSearchQuery, isNull);
    });

    test('handles malformed JSON args gracefully', () async {
      final adapter = _FakeAdapter();

      await expectLater(
        tools.execute(
          name: 'web_search',
          args: 'not valid json',
          adapter: adapter,
        ),
        throwsA(isA<AppFailure>()),
      );
    });

    test('handles empty args string', () async {
      final adapter = _FakeAdapter();

      await expectLater(
        tools.execute(name: 'web_search', args: '', adapter: adapter),
        throwsA(isA<AppFailure>()),
      );
    });

    test('returns results with degraded provider warnings', () async {
      final adapter = _FakeAdapter(
        searchResults: const <WebSearchResult>[
          WebSearchResult(
            title: 'Available result',
            url: 'https://example.com',
            snippet: 'From another provider',
            provider: 'exa',
          ),
        ],
        searchIssues: const <WebProviderIssue>[
          WebProviderIssue(provider: 'brave', kind: 'rate_limited'),
        ],
      );

      final WebToolResult result = await tools.execute(
        name: 'web_search',
        args: '{"query":"latest news"}',
        adapter: adapter,
      );

      expect(result.content, contains('Available result'));
      expect(result.warnings.single.impact, FailureImpact.degraded);
    });

    test('throws when every configured provider failed', () async {
      final adapter = _FakeAdapter(
        searchIssues: const <WebProviderIssue>[
          WebProviderIssue(provider: 'exa', kind: 'rate_limited'),
        ],
      );

      await expectLater(
        tools.execute(
          name: 'web_search',
          args: '{"query":"latest news"}',
          adapter: adapter,
        ),
        throwsA(
          isA<AppFailure>().having(
            (AppFailure failure) => failure.kind,
            'kind',
            FailureKind.rateLimited,
          ),
        ),
      );
    });

    test('does not fail when one provider succeeded with no matches', () async {
      final adapter = _FakeAdapter(
        successfulProviders: <String>['exa'],
        searchIssues: const <WebProviderIssue>[
          WebProviderIssue(provider: 'brave', kind: 'rate_limited'),
        ],
      );

      final WebToolResult result = await tools.execute(
        name: 'web_search',
        args: '{"query":"an impossible query"}',
        adapter: adapter,
      );

      final WebSearchResultPayload payload = WebSearchResultPayload.decode(
        result.content,
      );
      expect(payload.results, isEmpty);
      expect(payload.warnings, isNotEmpty);
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
      expect(result.content, contains('Title: Article'));
      expect(result.content, contains('URL: https://example.com/article'));
      expect(result.content, contains('Body text here'));
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

      expect(result.content, contains('truncated'));
      expect(result.content, contains('2000 more chars'));
    });

    test('throws a structured failure when url is missing', () async {
      final adapter = _FakeAdapter();

      await expectLater(
        tools.execute(name: 'fetch_page', args: '{}', adapter: adapter),
        throwsA(isA<AppFailure>()),
      );
      expect(adapter.lastFetchUrl, isNull);
    });
  });

  group('WebSearchTools.execute — unknown tool', () {
    test('throws a structured failure for unknown tool name', () async {
      final adapter = _FakeAdapter();

      await expectLater(
        tools.execute(name: 'not_a_tool', args: '{}', adapter: adapter),
        throwsA(
          isA<AppFailure>().having(
            (AppFailure failure) => failure.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
    });
  });
}
