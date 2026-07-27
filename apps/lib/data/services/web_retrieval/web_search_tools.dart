import 'dart:convert';

import 'package:logging/logging.dart';

import '../../../domain/models/web_search_result_payload.dart';
import '../llm/llm_event.dart';
import 'web_retrieval.dart';
import 'web_retrieval_failure_mapper.dart';

class WebToolResult {
  const WebToolResult({
    required this.content,
    this.warnings = const <AppFailure>[],
  });

  final String content;
  final List<AppFailure> warnings;
}

/// Tool definitions for the web retrieval capabilities exposed to the LLM.
///
/// The model can call `web_search` to run a fresh query and `fetch_page` to
/// pull the full content of a URL. Results are returned as tool messages so
/// the model can cite them in its reply.
class WebSearchTools {
  const WebSearchTools();

  static final Logger _log = Logger('web_search_tools');
  static const WebRetrievalFailureMapper _failureMapper =
      WebRetrievalFailureMapper();

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
  Future<WebToolResult> execute({
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
          throw const AppFailure(
            kind: FailureKind.invalidRequest,
            source: FailureSource(
              subsystem: AppSubsystem.webSearch,
              operation: 'search',
            ),
            message: 'The model attempted a web search without a query.',
          );
        }
        _log.fine('web_search: query="$query"');
        final WebSearchResponse response = await adapter.search(query);
        final List<AppFailure> issues = response.issues
            .map(
              (WebProviderIssue issue) => _failureMapper.fromIssue(
                issue,
                operation: 'search',
                degraded: response.results.isNotEmpty,
              ),
            )
            .toList();
        if (response.results.isEmpty &&
            issues.isNotEmpty &&
            response.successfulProviders.isEmpty) {
          throw issues.first;
        }
        _log.info(
          'web_search: query="$query" → ${response.results.length} result(s) '
          'provider=${response.results.isEmpty ? 'n/a' : response.results.first.provider}',
        );
        final WebSearchResultPayload payload = WebSearchResultPayload(
          query: query,
          results: response.results
              .map(
                (WebSearchResult result) => WebSearchResultItem(
                  title: result.title,
                  url: result.url,
                  snippet: result.snippet,
                  provider: result.provider,
                  publishedAt: result.publishedAt,
                ),
              )
              .toList(),
          warnings: issues.map((AppFailure issue) => issue.message).toList(),
        );
        return WebToolResult(content: payload.encode(), warnings: issues);
      case 'fetch_page':
        final String url = parsed['url'] as String? ?? '';
        if (url.isEmpty) {
          _log.warning('fetch_page: missing "url" argument');
          throw const AppFailure(
            kind: FailureKind.invalidRequest,
            source: FailureSource(
              subsystem: AppSubsystem.webFetch,
              operation: 'fetch',
            ),
            message: 'The model attempted to fetch a page without a URL.',
          );
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
        return WebToolResult(
          content: 'Title: ${page.title}\nURL: ${page.url}\n\n$body',
        );
      default:
        _log.warning('unknown tool: name=$name');
        throw AppFailure(
          kind: FailureKind.unsupported,
          source: const FailureSource(
            subsystem: AppSubsystem.webSearch,
            operation: 'execute_tool',
          ),
          message: 'The model requested an unsupported tool "$name".',
        );
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
