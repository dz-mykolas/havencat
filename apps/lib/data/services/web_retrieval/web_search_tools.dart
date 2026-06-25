import 'dart:convert';

import 'package:logging/logging.dart';

import '../llm/llm_event.dart';
import 'web_retrieval.dart';

/// Tool definitions for the web retrieval capabilities exposed to the LLM.
///
/// The model can call `web_search` to run a fresh query and `fetch_page` to
/// pull the full content of a URL. Results are returned as tool messages so
/// the model can cite them in its reply.
class WebSearchTools {
  const WebSearchTools();

  static final Logger _log = Logger('web_search_tools');

  /// OpenAI-shaped tool definitions for the web search + fetch capabilities.
  /// Pass these in [LlmRequest.tools] when web search is enabled.
  List<ToolDefinition> get definitions => const <ToolDefinition>[
    ToolDefinition(
      name: 'web_search',
      description:
          'Search the web for fresh information. Use for current events, '
          'recent data, or anything not in your training data. Returns '
          'titles, URLs, and short snippets.',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, Object?>{
            'type': 'string',
            'description': 'The search query.',
          },
        },
        'required': <String>['query'],
      },
    ),
    ToolDefinition(
      name: 'fetch_page',
      description:
          'Fetch the full content of a web page as markdown. Use after '
          'web_search to read a specific result in depth.',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'url': <String, Object?>{
            'type': 'string',
            'description': 'The absolute URL to fetch.',
          },
        },
        'required': <String>['url'],
      },
    ),
  ];

  /// Execute a tool call by name. Returns the result text to append as a
  /// tool message. Throws if the tool name is unknown or the args are bad.
  Future<String> execute({
    required String name,
    required String args,
    required WebRetrievalAdapter adapter,
  }) async {
    final Map<String, dynamic> parsed = _parseArgs(args);
    switch (name) {
      case 'web_search':
        final String query = parsed['query'] as String? ?? '';
        if (query.isEmpty) {
          _log.warning('web_search: missing "query" argument');
          return 'Error: missing "query" argument.';
        }
        _log.fine('web_search: query="$query"');
        final List<WebSearchResult> results = await adapter.search(query);
        _log.info(
          'web_search: query="$query" → ${results.length} result(s) '
          'provider=${results.isEmpty ? 'n/a' : results.first.provider}',
        );
        if (results.isEmpty) return 'No results found for "$query".';
        return results
            .asMap()
            .entries
            .map((e) {
              final WebSearchResult r = e.value;
              final String date = r.publishedAt != null
                  ? ' (published ${r.publishedAt!.toIso8601String().substring(0, 10)})'
                  : '';
              return '${e.key + 1}. ${r.title}$date\n   ${r.url}\n   ${r.snippet}';
            })
            .join('\n\n');
      case 'fetch_page':
        final String url = parsed['url'] as String? ?? '';
        if (url.isEmpty) {
          _log.warning('fetch_page: missing "url" argument');
          return 'Error: missing "url" argument.';
        }
        _log.fine('fetch_page: url=$url');
        final FetchedPage page = await adapter.fetch(url);
        _log.info(
          'fetch_page: url=$url → ${page.content.length} chars '
          'contentType=${page.contentType} title="${page.title}"',
        );
        final String body = page.content.length > 8000
            ? '${page.content.substring(0, 8000)}\n\n[...truncated, ${page.content.length - 8000} more chars]'
            : page.content;
        return 'Title: ${page.title}\nURL: ${page.url}\n\n$body';
      default:
        _log.warning('unknown tool: name=$name');
        return 'Error: unknown tool "$name".';
    }
  }

  static Map<String, dynamic> _parseArgs(String args) {
    if (args.trim().isEmpty) return <String, dynamic>{};
    try {
      final Object? decoded = jsonDecode(args);
      if (decoded is Map<String, dynamic>) return decoded;
      _log.warning(
        'tool args not a JSON object: ${args.substring(0, args.length.clamp(0, 100))}',
      );
    } catch (e) {
      _log.warning(
        'tool args JSON parse failed: $e args="${args.substring(0, args.length.clamp(0, 100))}"',
      );
    }
    return <String, dynamic>{};
  }
}
