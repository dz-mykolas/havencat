/// A single web search result.
class WebSearchResult {
  final String title;
  final String url;
  final String snippet;
  final DateTime? publishedAt;
  final String provider;

  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    this.publishedAt,
    required this.provider,
  });

  @override
  String toString() =>
      'WebSearchResult(title: $title, url: $url, provider: $provider)';
}

/// Options for a web search call.
class WebSearchOptions {
  final int numResults;

  const WebSearchOptions({this.numResults = 5});
}

/// A fetched page.
class FetchedPage {
  final String url;
  final String title;
  final String content;
  final String contentType;

  const FetchedPage({
    required this.url,
    required this.title,
    required this.content,
    required this.contentType,
  });
}

/// Output format for URL fetch.
enum FetchFormat { markdown, text, html }

/// A pluggable web search provider.
abstract class WebSearchProvider {
  String get kind;
  Future<List<WebSearchResult>> search(
    String query, {
    WebSearchOptions options = const WebSearchOptions(),
  });
}

/// A pluggable URL fetch provider.
abstract class UrlFetchProvider {
  String get kind;
  Future<FetchedPage> fetch(
    String url, {
    FetchFormat format = FetchFormat.markdown,
  });
}

/// Combined interface for adapters that implement both search and fetch.
/// Used by the Riverpod provider so consumers get a single typed handle.
abstract class WebRetrievalAdapter
    implements WebSearchProvider, UrlFetchProvider {}
