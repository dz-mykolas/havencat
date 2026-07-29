import 'dart:convert';

class WebSearchResultPayload {
  const WebSearchResultPayload({
    required this.query,
    required this.results,
    this.warnings = const <String>[],
  });

  static const String type = 'web_search_results';
  static const int version = 1;

  final String query;
  final List<WebSearchResultItem> results;
  final List<String> warnings;

  String encode() => jsonEncode(<String, Object?>{
    'type': type,
    'version': version,
    'query': query,
    'results': results
        .map((WebSearchResultItem result) => result.toJson())
        .toList(),
    if (warnings.isNotEmpty) 'warnings': warnings,
  });

  static WebSearchResultPayload decode(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map ||
        decoded['type'] != type ||
        decoded['version'] != version) {
      throw const FormatException('Invalid web-search result payload.');
    }
    final List<dynamic> rawResults = decoded['results'] as List<dynamic>;
    final Object? rawWarnings = decoded['warnings'];
    if (rawWarnings != null &&
        (rawWarnings is! List ||
            rawWarnings.any((Object? value) => value is! String))) {
      throw const FormatException('Invalid web-search warnings.');
    }
    return WebSearchResultPayload(
      query: decoded['query'] as String,
      results: rawResults
          .map(
            (Object? value) => WebSearchResultItem.fromJson(
              Map<String, Object?>.from(value! as Map),
            ),
          )
          .toList(),
      warnings: rawWarnings == null
          ? const <String>[]
          : List<String>.unmodifiable((rawWarnings as List).cast<String>()),
    );
  }
}

class WebSearchResultItem {
  const WebSearchResultItem({
    required this.title,
    required this.url,
    required this.snippet,
    required this.provider,
    this.publishedAt,
  });

  final String title;
  final String url;
  final String snippet;
  final String provider;
  final DateTime? publishedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'url': url,
    'snippet': snippet,
    'provider': provider,
    if (publishedAt != null) 'published_at': publishedAt!.toIso8601String(),
  };

  factory WebSearchResultItem.fromJson(Map<String, Object?> json) {
    return WebSearchResultItem(
      title: json['title'] as String,
      url: json['url'] as String,
      snippet: json['snippet'] as String,
      provider: json['provider'] as String,
      publishedAt: json['published_at'] == null
          ? null
          : DateTime.parse(json['published_at'] as String),
    );
  }
}
